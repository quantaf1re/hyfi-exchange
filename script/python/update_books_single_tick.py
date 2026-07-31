#!/usr/bin/env python
"""
HyFi book updater - pushes single-tick books (best bid / best ask only) on-chain.

Interim stand-in for the offchain orderbook aggregator: fetches the latest top-of-book
from a price source (Alpaca for tokenised stocks, Binance for crypto) and calls
HyFi.updateBooks with one tick of configured liquidity on each side, in a loop.

Usage (from the repo root, venv created via:
    python3 -m venv venv && venv/bin/pip install -r script/requirements.txt):

    source venv/bin/activate && python script/update_books.py -c robin -p NVDA-USDG,ETH-USDG

Requires in .env:
    PRIVATE_KEY_HYFI_UPDATER   the hook's updater key
    <rpc_env_var>              RPC URL per chain (see config.py, e.g. RPC_URL_ROBIN)
    ALPACA_API_KEY(_SECRET..)  when using the alpaca price source

Behaviour:
    - tickWidth / baseLiqUnit / base_is_c0 are read from the hook at startup
    - liquidity per side comes from config: ask side in base tokens, bid side in quote
      tokens (converted to base liquidity units at the current bid tip each loop)
    - unchanged books are not re-pushed until they age past max_book_age_s
    - after N consecutive price-source failures a pair's book is emptied on-chain
    - stuck txs are fee-bumped after tx.timeout_s, capped at tx.max_fee_gwei_d
    - logs to stdout and script/logs/update_books_<chain>.log

Amount-variable naming: *_d = nominal decimal amounts, *_w = wei amounts.
"""

import argparse
import decimal as dec
import json
import logging
import os
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

from dotenv import load_dotenv
from eth_abi import encode as abi_encode
from eth_account import Account
from web3 import Web3
from web3.exceptions import TimeExhausted

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from ABIs.hyfi_abi import HYFI_ABI  # noqa: E402
from config import CHAINS  # noqa: E402
from price_sources import PRICE_SOURCES  # noqa: E402

dec.getcontext().prec = 60
D = dec.Decimal

log = logging.getLogger('update_books')

# --- HyFi book constants (must match HyFi.sol) --------------------------------
SCALE = 10 ** 24  # fixed-point scale of tickWidth
TS_SHIFT, ID_SHIFT, CUR_SHIFT, END_SHIFT, LEFT_SHIFT, HEAD_SHIFT = 40, 72, 112, 120, 128, 224
MASK_8, MASK_32, MASK_40, MASK_96 = 0xFF, 0xFFFFFFFF, 0xFFFFFFFFFF, (1 << 96) - 1
MAX_TICK_VALUE = 255
UINT40_MAX = (1 << 40) - 1

# Gas cost tracking
ETH_PRICE_USD = 2000  # Assumed ETH price for $ calculations
start_time = None  # Set in main()
total_gas_cost_usd = D('0')  # Cumulative gas cost in USD


# ------------------------------------------------------------------
# Runtime pair state
# ------------------------------------------------------------------

@dataclass
class Pair:
    name: str
    cfg: dict
    pool_id: bytes
    base_is_currency0: bool
    tick_width: int          # quote-wei per base-wei, x1e24
    base_liq_unit_w: int     # base wei per liquidity unit
    base_dec: int
    quote_dec: int
    ask_units: int           # fixed at startup (ask side is a fixed base amount)
    book_id_counter: int = 0  # bumped per update attempt; seeded from chain at startup
    consecutive_failures: int = 0
    emptied: bool = False    # an empty book is currently on-chain for this pair
    last_bid_tip: int = 1    # last pushed tips (skip check + fallback for empty-book updates)
    last_ask_tip: int = 1
    last_push_ts: int = 0    # wall clock of the last successful push (for max_book_age_s)


# ------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------

def setup_logging(chain_name):
    logs_dir = SCRIPT_DIR / 'logs'
    logs_dir.mkdir(exist_ok=True)
    fmt = logging.Formatter('%(asctime)s %(levelname)-7s %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
    for handler in (
        logging.FileHandler(logs_dir / f'update_books_{chain_name}.log'),
        logging.StreamHandler(sys.stdout),
    ):
        handler.setFormatter(fmt)
        log.addHandler(handler)
    log.setLevel(logging.INFO)


def require(condition, message, *args):
    """Log an error and exit(1) if condition is falsy. Used for startup validation in main()."""
    if not condition:
        log.error(message, *args)
        sys.exit(1)


# ------------------------------------------------------------------
# Book maths
# ------------------------------------------------------------------

def compute_pool_id(currency0, currency1, fee, tick_spacing, hook):
    """keccak256(abi.encode(PoolKey)) exactly as v4's PoolId.toId()."""
    return Web3.keccak(abi_encode(
        ['address', 'address', 'uint24', 'int24', 'address'],
        [currency0, currency1, fee, tick_spacing, hook],
    ))


def price_to_tip(price_d, base_dec, quote_dec, tick_width, round_up):
    """Convert a nominal price (quote per base) to a tip in multiples of tickWidth.
    Bids round down and asks round up so the pushed book is never tighter than the source.
    """
    price_x24 = price_d * D(10 ** quote_dec) * D(SCALE) / D(10 ** base_dec)
    rounding = dec.ROUND_CEILING if round_up else dec.ROUND_FLOOR
    return int((price_x24 / D(tick_width)).to_integral_value(rounding=rounding))


def apply_maker_fee(bid_price_d, ask_price_d, maker_fee_pct_d):
    fee_frac = maker_fee_pct_d / D('100')
    return (bid_price_d * (D('1') - fee_frac), ask_price_d * (D('1') + fee_frac))


def base_amount_to_units(base_w, base_liq_unit_w):
    return base_w // base_liq_unit_w


def quote_amount_to_units(quote_w, tip, tick_width, base_liq_unit_w):
    """Liquidity units representable by `quote_w` quote wei at the tip's price."""
    base_w = quote_w * SCALE // (tip * tick_width)
    return base_amount_to_units(base_w, base_liq_unit_w)


def side_update(tip, units):
    """A single-tick SideUpdate tuple: all liquidity on tick 0 (the tip)."""
    return (tip, 0, units, 0, 0)  # (tipPrice, endTick, headTicks, wordA, wordB)


def decode_slot0(slot0):
    return {
        'tip': slot0 & MASK_40,
        'ts': (slot0 >> TS_SHIFT) & MASK_32,
        'book_id': (slot0 >> ID_SHIFT) & MASK_40,
        'cur': (slot0 >> CUR_SHIFT) & MASK_8,
        'end': (slot0 >> END_SHIFT) & MASK_8,
        'left': (slot0 >> LEFT_SHIFT) & MASK_96,
        'tick0': (slot0 >> HEAD_SHIFT) & MASK_8,
    }


# ------------------------------------------------------------------
# Startup
# ------------------------------------------------------------------

def resolve_token(chain_cfg, name):
    token = chain_cfg['tokens'][name]
    return Web3.to_checksum_address(token['addr']), token['decs']

def setup_pair(hyfi, chain_cfg, name):
    """Resolve addresses, derive the poolId, and load + validate on-chain pair config."""
    cfg = chain_cfg['pairs'][name]
    source_name = cfg.get('price_source')
    if source_name not in PRICE_SOURCES:
        raise RuntimeError(f'{name}: unknown price_source {source_name!r}')
    PRICE_SOURCES[source_name].check_env(cfg)

    base_addr, base_dec = resolve_token(chain_cfg, cfg['base'])
    quote_addr, quote_dec = resolve_token(chain_cfg, cfg['quote'])
    base_is_currency0 = int(base_addr, 16) < int(quote_addr, 16)
    c0, c1 = (base_addr, quote_addr) if base_is_currency0 else (quote_addr, base_addr)
    pool_id = compute_pool_id(c0, c1, cfg.get('fee', 0), cfg.get('tick_spacing', 1), hyfi.address)

    tick_width, base_liq_unit_w, fee_per_second, base_is_c0_onchain = hyfi.functions.pairConfig(pool_id).call()
    if tick_width == 0:
        raise RuntimeError(f'{name}: pair not configured on-chain (poolId 0x{pool_id.hex()})')
    if base_is_c0_onchain != base_is_currency0:
        raise RuntimeError(
            f'{name}: on-chain base_is_c0={base_is_c0_onchain} does not match token '
            f'addresses (config base={cfg["base"]}) - check the config'
        )

    ask_base_w = int(cfg['ask_liquidity_base_d'] * D(10 ** base_dec))
    ask_units = base_amount_to_units(ask_base_w, base_liq_unit_w)
    if not 1 <= ask_units <= MAX_TICK_VALUE:
        raise RuntimeError(
            f'{name}: ask_liquidity_base_d={cfg["ask_liquidity_base_d"]} maps to {ask_units} '
            f'liquidity units (baseLiqUnit={base_liq_unit_w}); must be 1-{MAX_TICK_VALUE}'
        )

    # Seed the per-pair bookId counter from chain so the first push is strictly greater than the
    # stored bookId (the contract requires per-pair bookIds to be monotonically increasing).
    bid_slot0, _, _ = hyfi.functions.getBookSideRaw(pool_id, True).call()
    book_id_counter = decode_slot0(bid_slot0)['book_id']

    pair = Pair(
        name=name, cfg=cfg, pool_id=pool_id, base_is_currency0=base_is_currency0,
        tick_width=tick_width, base_liq_unit_w=base_liq_unit_w,
        base_dec=base_dec, quote_dec=quote_dec, ask_units=ask_units,
        book_id_counter=book_id_counter,
    )
    log.info(
        f'{name} ready: poolId=0x{pool_id.hex()} tickWidth={tick_width} baseLiqUnit={base_liq_unit_w} feePerSecond={fee_per_second} '
        f'base_is_c0={base_is_currency0} decimals={base_dec}/{quote_dec} askUnits={ask_units} bookId={book_id_counter} source={source_name}'
    )
    return pair


# ------------------------------------------------------------------
# Per-loop pair update construction
# ------------------------------------------------------------------

def build_pair_update(pair, now_ts):
    """Fetch prices and build this pair's PairUpdate tuple.
    Returns the update tuple, or None when nothing needs pushing (price unchanged and the
    book isn't yet due a staleness refresh, price source down but not yet at the empty-book
    threshold, or the book is already emptied).
    """
    cfg = pair.cfg
    try:
        bid_price_d, ask_price_d, _ = PRICE_SOURCES[cfg['price_source']].get_top_of_book(cfg)
        log.info(f'{pair.name}: source book bid={bid_price_d} ask={ask_price_d}')
    except Exception as e:  # noqa: BLE001 - any source failure follows the same path
        pair.consecutive_failures += 1
        log.warning(f'{pair.name}: price source failed ({pair.consecutive_failures} consecutive): {e}')
        if pair.consecutive_failures >= cfg['empty_book_after_failures'] and not pair.emptied:
            log.error(f'{pair.name}: {pair.consecutive_failures} consecutive failures - pushing empty book to disable trading')
            return _empty_update(pair)
        return None

    pair.consecutive_failures = 0
    if bid_price_d >= ask_price_d:
        log.warning(f'{pair.name}: crossed/locked source book (bid={bid_price_d} ask={ask_price_d}), skipping')
        return None

    bid_price_d, ask_price_d = apply_maker_fee(bid_price_d, ask_price_d, cfg['maker_fee_pct_d'])
    bid_tip = price_to_tip(bid_price_d, pair.base_dec, pair.quote_dec, pair.tick_width, round_up=False)
    ask_tip = price_to_tip(ask_price_d, pair.base_dec, pair.quote_dec, pair.tick_width, round_up=True)
    if not 1 <= bid_tip <= UINT40_MAX or not 1 <= ask_tip <= UINT40_MAX:
        log.error(f'{pair.name}: tip out of range (bid={bid_tip} ask={ask_tip}) - check tickWidth vs price magnitude')
        return None

    bid_quote_w = int(cfg['bid_liquidity_quote_d'] * D(10 ** pair.quote_dec))
    bid_units = quote_amount_to_units(bid_quote_w, bid_tip, pair.tick_width, pair.base_liq_unit_w)
    if bid_units < 1:
        log.error(f'{pair.name}: bid_liquidity_quote_d={cfg["bid_liquidity_quote_d"]} maps to 0 liquidity units at tip {bid_tip}, skipping')
        return None
    if bid_units > MAX_TICK_VALUE:
        log.warning(f'{pair.name}: bid liquidity clamped to {MAX_TICK_VALUE} units (wanted {bid_units})')
        bid_units = MAX_TICK_VALUE

    # We only ever push the single top tick per side, so the on-chain book is fully described by
    # its tips. Skip re-pushing when the price is unchanged and the book isn't yet due a staleness
    # refresh (both tracked in memory from the last successful push - no on-chain read needed).
    if (not pair.emptied
            and bid_tip == pair.last_bid_tip and ask_tip == pair.last_ask_tip
            and now_ts - pair.last_push_ts < cfg['max_book_age_s']):
        log.info(f'{pair.name}: price unchanged and fresh (age {now_ts - pair.last_push_ts}s), skipping')
        return None

    pair.book_id_counter += 1
    update = (
        pair.pool_id, pair.book_id_counter,
        side_update(bid_tip, bid_units),
        side_update(ask_tip, pair.ask_units),
    )
    log.info(f'{pair.name}: bookId={pair.book_id_counter} bidTip={bid_tip} ({bid_units} units) askTip={ask_tip} ({pair.ask_units} units)')
    return update


def _empty_update(pair):
    """A PairUpdate with zero liquidity on both sides - trades revert until the next real book."""
    pair.book_id_counter += 1
    return (pair.pool_id, pair.book_id_counter, side_update(pair.last_bid_tip, 0), side_update(pair.last_ask_tip, 0))


def calculate_gas_cost_and_hourly_rate(receipt, max_fee_w):
    """Calculate gas cost in USD and burn rates (hourly and daily), update global cumulative cost.
    
    Returns (gas_cost_usd, cost_per_hour_usd, cost_per_day_usd).
    """
    global total_gas_cost_usd
    
    gas_used = receipt['gasUsed']
    effective_gas_price_w = receipt.get('effectiveGasPrice', max_fee_w)
    gas_cost_w = gas_used * effective_gas_price_w
    gas_cost_eth = D(gas_cost_w) / D(10 ** 18)
    gas_cost_usd = gas_cost_eth * D(ETH_PRICE_USD)
    
    total_gas_cost_usd += gas_cost_usd
    
    elapsed_s = time.time() - start_time
    hours_elapsed = elapsed_s / 3600
    cost_per_hour = total_gas_cost_usd / D(hours_elapsed) if hours_elapsed > 0 else D('0')
    cost_per_day = cost_per_hour * D('24')
    
    return gas_cost_usd, cost_per_hour, cost_per_day


# ------------------------------------------------------------------
# Tx submission with stuck-tx fee bumping
# ------------------------------------------------------------------

def send_update_books(w3, hyfi, account, tx_cfg, updates, batch_ts):
    """Send updateBooks and wait for the receipt, fee-bumping stuck txs.

    After tx_cfg['timeout_s'] without a receipt, both fees are multiplied by
    fee_bump_multiplier_d and the same-nonce tx is re-broadcast. maxFeePerGas is hard-capped
    at max_fee_gwei_d; if the cap makes a replacement impossible, gives up with an error.
    
    Tracks cumulative gas costs and logs $ spent and $ per hour on tx confirmation.
    """
    fn = hyfi.functions.updateBooks(updates, batch_ts)
    gas = int(fn.estimate_gas({'from': account.address}) * 1.2)
    nonce = w3.eth.get_transaction_count(account.address, 'pending')

    base_fee_w = w3.eth.get_block('latest')['baseFeePerGas']
    priority_floor_w = int(tx_cfg['priority_fee_gwei_d'] * D(10 ** 9))
    try:
        priority_fee_w = max(w3.eth.max_priority_fee, priority_floor_w)
    except Exception:  # noqa: BLE001 - not all RPCs expose eth_maxPriorityFeePerGas
        priority_fee_w = priority_floor_w
    max_fee_cap_w = int(tx_cfg['max_fee_gwei_d'] * D(10 ** 9))
    max_fee_w = min(2 * base_fee_w + priority_fee_w, max_fee_cap_w)
    bump_d = tx_cfg['fee_bump_multiplier_d']

    for attempt in range(1, tx_cfg['max_attempts'] + 1):
        tx = fn.build_transaction({
            'from': account.address,
            'nonce': nonce,
            'gas': gas,
            'maxFeePerGas': max_fee_w,
            'maxPriorityFeePerGas': min(priority_fee_w, max_fee_w),
            'chainId': w3.eth.chain_id,
        })
        tx_hash = w3.eth.send_raw_transaction(account.sign_transaction(tx).raw_transaction)
        log.info(f'updateBooks sent (attempt {attempt}/{tx_cfg["max_attempts"]}): {tx_hash.hex()} maxFee={max_fee_w / 1e9:.3f} gwei')
        try:
            receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=tx_cfg['timeout_s'])
        except TimeExhausted:
            new_max_fee_w = min(int(max_fee_w * bump_d), max_fee_cap_w)
            if new_max_fee_w < int(max_fee_w * 1.1):
                raise RuntimeError(
                    f'tx {tx_hash.hex()} stuck and fee cap {tx_cfg["max_fee_gwei_d"]} gwei '
                    f'prevents a valid replacement - raise the cap or wait'
                )
            log.warning(f'tx {tx_hash.hex()} stuck after {tx_cfg["timeout_s"]}s, bumping fee {max_fee_w / 1e9:.3f} -> {new_max_fee_w / 1e9:.3f} gwei')
            max_fee_w = new_max_fee_w
            priority_fee_w = int(priority_fee_w * bump_d)
            continue
        if receipt['status'] != 1:
            raise RuntimeError(f'updateBooks reverted on-chain: {tx_hash.hex()}')
        
        gas_cost_usd, cost_per_hour, cost_per_day = calculate_gas_cost_and_hourly_rate(receipt, max_fee_w)
        log.info(f'updateBooks confirmed in block {receipt["blockNumber"]} (gas used {receipt["gasUsed"]}): 0x{tx_hash.hex()} | ${cost_per_hour:.2f}/hour (${cost_per_day:.2f}/day)')
        return receipt
    raise RuntimeError(f'updateBooks not confirmed after {tx_cfg["max_attempts"]} attempts')


# ------------------------------------------------------------------
# Main loop
# ------------------------------------------------------------------

def run_loop(w3, hyfi, account, chain_cfg, pairs):
    while True:
        loop_start = time.time()
        try:
            now_ts = int(time.time())
            included = []
            for pair in pairs:
                update = build_pair_update(pair, now_ts)
                if update is not None:
                    included.append((pair, update))

            if included:
                # The batch timestamp is the current wall clock: always > the timestamp already
                # stored on-chain (time only moves forward) and <= block.timestamp.
                send_update_books(w3, hyfi, account, chain_cfg['tx'], [u for _, u in included], now_ts)
                for pair, update in included:
                    pair.last_bid_tip, pair.last_ask_tip = update[2][0], update[3][0]
                    pair.last_push_ts = now_ts
                    pair.emptied = update[2][2] == 0 and update[3][2] == 0  # both headTicks empty
        except Exception as e:  # noqa: BLE001 - the loop must survive any single failure
            log.error(f'update loop error: {e}', exc_info=True)

        elapsed = time.time() - loop_start
        time.sleep(max(0, chain_cfg['sleep_s'] - elapsed))


def main():
    global start_time
    
    parser = argparse.ArgumentParser(description='Push single-tick HyFi book updates in a loop')
    parser.add_argument('-c', '--chain', required=True, choices=sorted(CHAINS.keys()))
    parser.add_argument('-p', '--pairs', required=True, help='comma-separated pair names, e.g. NVDA-USDG,ETH-USDG')
    args = parser.parse_args()

    setup_logging(args.chain)
    load_dotenv(SCRIPT_DIR.parent.parent / '.env')
    start_time = time.time()

    chain_cfg = CHAINS[args.chain]
    pair_names = [p.strip() for p in args.pairs.split(',') if p.strip()]
    unknown = [p for p in pair_names if p not in chain_cfg['pairs']]
    require(not unknown, 'Unknown pairs for chain %s: %s (configured: %s)', args.chain, ', '.join(unknown), ', '.join(chain_cfg['pairs']))

    private_key = os.getenv('PRIVATE_KEY_HYFI_UPDATER')
    require(private_key, 'PRIVATE_KEY_HYFI_UPDATER not set in .env')
    rpc_url = os.getenv(chain_cfg['rpc_env_var'])
    require(rpc_url, '%s not set in .env', chain_cfg['rpc_env_var'])
    hyfi_address = chain_cfg['contracts'].get('hyfi')
    require(hyfi_address, "contracts['hyfi'] not set in config for chain %s", args.chain)

    w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs={'timeout': 30}))
    chain_id = w3.eth.chain_id
    require(chain_id == chain_cfg['chain_id'], 'RPC chain id %d != configured %d', chain_id, chain_cfg['chain_id'])

    account = Account.from_key(private_key)
    hyfi = w3.eth.contract(address=Web3.to_checksum_address(hyfi_address), abi=json.loads(HYFI_ABI))

    onchain_updater = hyfi.functions.updater().call()
    require(onchain_updater.lower() == account.address.lower(), 'Key address %s is not the hook updater (%s)', account.address, onchain_updater)

    balance_w = w3.eth.get_balance(account.address)
    log.info(f'Starting updater on {args.chain} (chainId {chain_id}): hook={hyfi.address} updater={account.address} balance={balance_w / 1e18:.6f} ETH pairs={", ".join(pair_names)}')
    pairs = [setup_pair(hyfi, chain_cfg, name) for name in pair_names]

    try:
        run_loop(w3, hyfi, account, chain_cfg, pairs)
    except KeyboardInterrupt:
        log.info('Interrupted, shutting down')


if __name__ == '__main__':
    main()
