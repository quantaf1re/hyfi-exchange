"""
Configuration for update_books.py.

Structure:
    CHAINS[chain_name] = {
        'chain_id':    expected EVM chain id (sanity-checked against the RPC),
        'rpc_env_var': name of the env var holding the RPC URL (same vars foundry.toml uses),
        'sleep_s':     seconds to sleep at the end of every update loop,
        'tx': {
            'timeout_s':           seconds to wait for a tx receipt before fee-bumping,
            'fee_bump_multiplier_d': factor applied to both maxFee and maxPriorityFee per bump
                                     (must be >= 1.1 for nodes to accept the replacement),
            'max_fee_gwei_d':      absolute cap on maxFeePerGas - a gas spike can never
                                   spend past this,
            'priority_fee_gwei_d': floor for maxPriorityFeePerGas,
            'max_attempts':        total send attempts (1 initial + bumps) before giving up,
        },
        'contracts': { name -> address },   # must include 'hyfi'
        'tokens':    { name -> {'addr': address, 'decs': decimals} },  # native token = zero address
        'pairs': {
            'BASE-QUOTE': {                 # key convention: BASE-QUOTE (CEX-style symbol)
                'base'/'quote':          token names resolved through 'tokens',
                'fee'/'tick_spacing':    PoolKey fields (defaults 0 / 1),
                'price_source':          key into price_sources.PRICE_SOURCES; the pair dict
                                         itself is passed to the source, so include the
                                         source-specific keys ('stock_symbol', 'spot_pair',
                                         'base_leg'/'quote_leg') here too,
                'ask_liquidity_base_d':  base tokens (nominal) on the single ask tip tick,
                'bid_liquidity_quote_d': quote tokens (nominal) on the single bid tip tick,
                'maker_fee_pct_d':       maker spread applied to the source price, in percent
                                         (e.g. D('0.1') = 0.1%); worsens the price on both
                                         sides (ask up, bid down) applied right after the
                                         source price is fetched, before tip conversion,
                'max_book_age_s':        push a refresh even if the book is unchanged once
                                         the on-chain timestamp is older than this,
                'empty_book_after_failures': after this many consecutive price-source
                                         failures, push an empty book (all ticks zero) so
                                         trades revert instead of filling at a stale price,
            },
        },
    }

tickWidth / baseLiqUnit / baseIsCurrency0 / feePerSecond are NOT configured here - they are
read from the hook's on-chain pairConfig at startup (single source of truth).

Amount-variable naming: *_d = nominal decimal amounts, *_w = wei amounts.
"""

import decimal as dec

D = dec.Decimal

NATIVE = '0x0000000000000000000000000000000000000000'

CHAINS = {
    'robin': {
        'chain_id': 4663,
        'rpc_env_var': 'RPC_URL_ROBIN',
        'sleep_s': 10,
        'tx': {
            'timeout_s': 30,
            'fee_bump_multiplier_d': D('1.5'),
            'max_fee_gwei_d': D('50'),
            'priority_fee_gwei_d': D('0.001'),
            'max_attempts': 5,
        },
        'contracts': {
            'hyfi': '0xE06495094a44987833219A48B175C5c30D426088',
        },
        'tokens': {
            'ETH': {'addr': NATIVE, 'decs': 18},
            'USDG': {'addr': '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168', 'decs': 6},
            'NVDA': {'addr': '0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC', 'decs': 18},
        },
        'pairs': {
            'NVDA-USDG': {
                'base': 'NVDA',
                'quote': 'USDG',
                'fee': 0,
                'tick_spacing': 1,
                'price_source': 'alpaca',
                'stock_symbol': 'NVDA',
                'ask_liquidity_base_d': D('5'),      # 5 NVDA on the ask tip
                'bid_liquidity_quote_d': D('1000'),  # 1000 USDG on the bid tip
                'maker_fee_pct_d': D('0.1'),          # 0.1% maker spread
                'max_book_age_s': 20,
                'empty_book_after_failures': 10,
            },
            'ETH-USDG': {
                'base': 'ETH',
                'quote': 'USDG',
                'fee': 0,
                'tick_spacing': 1,
                'price_source': 'binance',
                'spot_pair': 'ETHUSDC',              # USDG ~ USD ~ USDC
                'ask_liquidity_base_d': D('0.5'),    # 0.5 ETH on the ask tip
                'bid_liquidity_quote_d': D('1500'),  # 1500 USDG on the bid tip
                'maker_fee_pct_d': D('0.1'),          # 0.1% maker spread
                'max_book_age_s': 20,
                'empty_book_after_failures': 10,
            },
        },
    },
}
