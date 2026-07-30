# HyFi Exchange

The onchain component of HyFi — a hybrid exchange where professional MMs quote into an offchain CEX-style orderbook, and that book is aggregated, compressed, and pushed onchain every block for traders to swap against through Uniswap v4.

The entire onchain surface is a single contract: [src/HyFi.sol](src/HyFi.sol), a Uniswap v4 hook.

## Architecture

```
MMs ──(API)──▶ offchain CEX book ──(updater, every block)──▶ HyFi hook storage
Traders ──(Uniswap v4 swap)──▶ PoolManager ──beforeSwap──▶ HyFi walks the book
```

- **Traders** swap through normal v4 routing (Universal Router, aggregators). No deposits, no approvals to HyFi itself.
- **MMs** never touch the chain for order management. Their liquidity is deposited into the hook once; all order placement/cancellation happens offchain for free.
- **The updater** pushes the compressed aggregate book onchain each block. Trades emit events referencing the book snapshot id, which the offchain CEX uses to attribute fills to individual MMs.

## Design rationale

### Why a v4 hook with a custom curve (and not a standalone contract)

Trades must come from Uniswap routing to capture retail/aggregator flow. The hook uses `beforeSwap` + `beforeSwapReturnDelta` to act as a *custom curve*: it prices the swap against the compressed book, settles both legs itself, and returns a `BeforeSwapDelta` equal to `-amountSpecified`, which zeroes out the core AMM swap entirely. The v4 concentrated-liquidity maths never executes.

### Why all funds are PoolManager ERC-6909 claims

The hook holds no ERC20 or native balances at any point. Deposits settle tokens into the PoolManager and mint 6909 claims to the hook; trades mint claims for the input leg and burn claims for the output leg; withdrawals burn claims and `take` to the recipient. Benefits:

- Swap settlement is pure 6909 accounting — no token transfers inside the hot path (the PM handles the trader's transfers at the edge of the unlock).
- One custody surface (the PoolManager) instead of two.
- Native ETH works identically to ERC20s, since v4 claims support the native currency.

There is deliberately **no per-MM balance onchain**. Only the aggregate pot exists. MM balances live on the offchain CEX (which also processes trades/fees), so withdrawals are executed by a permissioned `withdrawer` after the CEX has removed the MM's liquidity from the book. Deposits are permissionless and carry a `beneficiary` for offchain attribution.

### The compressed book: 68 ticks in 3 storage slots per side

Each side (bid/ask) of a pair's book is exactly 3 slots:

```
slot0: tipPrice u40 | timestamp u32 | bookId u40 | curTick u8 | endTick u8 | amountLeft u96 | ticks 0-3 (4 × u8)
wordA: ticks 4-35  (32 × u8)
wordB: ticks 36-67 (32 × u8)
```

Why this exact shape:

- **Ticks are `uint8` liquidity multiples** (0–255 units of `baseLiqUnit`), per the compression scheme in the docs: only professional MMs quote, so liquidity can be constrained to coarse step sizes, collapsing a whole book side into a few words.
- **4 ticks are packed into slot0's spare bits** rather than starting the tick array on its own slot. This is also why the layout is hand-packed instead of a native Solidity struct: Solidity would start a `uint8[68]` array at a fresh slot (4 slots/side instead of 3, ≈ +10k gas per pair per update, every block) and would emit one SLOAD per field access instead of one per slot.
- **`bookId` and `timestamp` are duplicated into each side's slot0** instead of a shared pair-level slot. Both slot0s are rewritten every update anyway, so the duplication is free — and it saves one SSTORE (~5k gas) per pair per update plus one SLOAD per trade.
- **68 ticks** is simply everything that fits after the other fields; the docs target "~top 100 ticks", and in practice liquidity beyond the top few dozen ticks is rarely reached before the next block's update replaces the book.

### Why each field is sized the way it is

| Field | Type | Reasoning |
|---|---|---|
| `tipPrice` | `uint40` | Price expressed in multiples of `tickWidth`, i.e. "number of ticks from zero". Real venues run tick widths of ~1e-4–1e-7 of price (BTC $100k / $0.01 ticks = 1e7). `uint32` (4.3e9) would already cover sane configs but leaves thin headroom (BTC at $1M with $0.0001 ticks = 1e10 overflows it); `uint40` (1.1e12) gives 100× margin for 8 more bits. |
| `timestamp` | `uint32` | Unix seconds, good until 2106. It's the *inputted* snapshot time (not `block.timestamp`) so the staleness fee is measured from when the book was actually priced. |
| `bookId` | `uint40` | 1.1e12 ids ≈ 7,000 years of one snapshot per 200ms block. Inputted (not an onchain counter) so trades can be correlated to the exact offchain snapshot, including multiple replacement updates within one block. Strictly increasing per pair — enforced onchain. |
| `curTick`/`endTick` | `uint8` | Tick indices 0–67 (`curTick` can rest at 68 = drained). |
| `amountLeft` | `uint96` | Base wei remaining in the partially-consumed tick. Must hold up to `255 × baseLiqUnit` = 7.9e28 max. That supports e.g. SHIB-tier tokens ($1e-5, 18 dec) with ~$3k liquidity units / ~$790k per tick. Widening it would cost tick slots; $1e-10 hyper-memes are out of scope. |
| `tickWidth` | `uint128` × 1e24 | See [SCALE](#why-scale--1e24). |
| `baseLiqUnit` | `uint88` | Base wei per unit of tick liquidity. `uint88`'s type bound (3.09e26) alone guarantees `255 × baseLiqUnit` fits `amountLeft`'s `uint96` — no runtime check needed. |
| `feePerSecond` | `uint24` | Pips/second. Max 16.7M pips/s is far beyond any sane config; `uint16` (6.5%/s cap) was rejected as too tight, and the saved bits had nowhere useful to go — the config already fits one slot. |

The pair config (`tickWidth` + `baseLiqUnit` + `feePerSecond` + `baseIsCurrency0` = 248 bits) packs into **one slot**, so a trade reads its entire config with a single SLOAD. This constraint drove several of the sizes above.

### Why `SCALE = 1e24`

`tickWidth` is denominated in **quote-wei per base-wei** — the token decimal difference is baked in by the owner at config time, so trade execution never touches token decimals. That raw ratio can be extreme in both directions:

- Low end: SHIB(18 dec)/USDC(6 dec) at $0.00001 with $1e-9 ticks → raw ratio 1e-21. At 1e18 scaling this would store as 0.001 — **not representable**. This is why 1e18 was rejected.
- High end: a 6-decimal base token quoted in an 18-decimal stable with $100 ticks → raw ratio 1e14 → stores as 1e38, which still fits `uint128` (3.4e38).

1e24 is the scale that covers both extremes **while keeping `tickWidth` in `uint128`**, which is what lets the config fit one slot. The alternative (1e27/`uint160`) buys unneeded range at the cost of a second config slot (+2.1k gas per trade).

### Why one nominal price per pair (not per-side / inverted prices)

Both book sides are priced in quote-per-base as multiples of a single `tickWidth`: bid tick *i* = `(tip − i) × tickWidth`, ask tick *i* = `(tip + i) × tickWidth`. The tempting alternative — storing one side pre-inverted so both trade directions become pure multiplications — is mathematically broken: uniform ticks in price space are **not uniform in inverted space** (`1/(p+Δ) − 1/p ≠ const`), so a "multiple of an inverted tickWidth" drifts from the true price as the book is walked. One direction therefore performs a division (`mulDiv(quote, SCALE, price)`); that's unavoidable under any correct scheme.

This also settles token ordering: pairs are keyed by the pool but configured with an explicit `baseIsCurrency0`, so the book is always the *nominal* (CEX-familiar) orientation and neither the updater nor MMs ever deal with inverted books.

### Why `baseLiqUnit` is a base-token amount (not a multiple of `tickWidth`)

They have different dimensions — `tickWidth` is a price (quote/base), liquidity is a base amount. Both book sides are denominated in base (the bid side is "willingness to *buy* N base"), so one unit serves both sides and no coupling to the price grid is possible or useful.

### The staleness fee

`feePerSecond` (pips, 1e-6) accrues per second since the book's *inputted* timestamp, capped at 100%. It exists to make arbitrage against a stale book progressively unprofitable if updates are delayed — the MMs' insurance policy, and it goes entirely to them (attributed offchain).

**It's taken from the output, not the input.** Three reasons:

1. It protects MMs in the exact scenario the fee exists for: if the market moved and an arber is buying the appreciating token, an output-side fee retains part of *that* token for the MMs. An input-side fee would compensate them in the token being dumped. (Note CEXes also deduct taker fees from the received asset; Uniswap's input-side fee is an artifact of its invariant maths, not an economic principle.)
2. One rule covers all four direction/exactness quadrants: *walk the book for the gross output, deliver the net*. Exact-in shaves the output; exact-out grosses up the walk target. The book consumption always equals what MM orders actually filled, so offchain attribution is a simple pro-rata in the same token each MM sold.
3. For exact-in (the dominant case) the full user input maps 1:1 onto book liquidity with no pre-scaling rounding step.

At the 100% cap, exact-output trades revert (`BookTooStale`) since no finite gross output satisfies them; exact-input trades technically execute with 0 output and are left to router min-out checks.

### Gas: nothing is ever zeroed

Every book write is designed to hit the 5k non-zero→non-zero SSTORE rate instead of 20k zero→non-zero:

- **Trades write exactly one slot.** Walking the book only advances `curTick`/`amountLeft` in slot0 — consumed ticks are *not* zeroed; the pointer makes them unreachable. Two trades in one block on the same side chain correctly: the second resumes at the first's pointer.
- **Updates write only what the new book reaches.** `endTick` is the index of the last live tick; `wordA` is written only if `endTick ≥ 4`, `wordB` only if `endTick ≥ 36`. Stale ticks beyond `endTick` are left dirty and are unreachable (the walk reverts past `endTick`).
- **Config changes clear the book by masking**, preserving the timestamp/bookId bits so the slots stay non-zero (and preserving bookId monotonicity across reconfigs).
- Tick words arrive **pre-packed offchain** as whole `uint256` words — the contract does zero packing work, just validates and stores.
- Updates are **batch-only** (one tx, many pairs) to amortize the 21k base cost; one timestamp per batch (one snapshot time), one bookId per pair (pairs can update at different cadences).

Update validation: timestamp must be ≤ `block.timestamp` (protects the fee maths from underflow) and ≥ the stored timestamp — *equal* is allowed so a pending update can be replaced within the same block (which is also why bookIds, not timestamps, are the strict-monotonic sequence). Bid tips must satisfy `tip > endTick` so no bid tick can price at or below zero.

### Rounding

Every rounding site favors the contract: user-received amounts round down (`mulDiv`), user-paid amounts and fees round up (`mulDivRoundingUp`), via the standard v4-core `FullMath`. In the quote-walk kernel the partially-filled tick's `amountLeft` is reduced by exactly the (contract-favoring) base amount charged, so book accounting stays consistent with token movement. One documented edge: a tick whose entire liquidity rounds to 0 quote wei is consumed "for free" against an exact-output seller — direction favors the contract and the walk still terminates at `endTick`.

`unchecked` is used **only** for the `++i` tick-index increments (provably ≤ 68); all value arithmetic is checked. The hot-loop overflow checks cost ~100–150 gas per tick — cheap insurance for fund-bearing maths.

### Roles

- **Owner** (`Ownable2Step`): ultimate control — sets pair configs and rotates the other roles. Config is keyed by poolId, so `beforeInitialize` requiring an existing config pins the *exact* PoolKey (currencies, fee, tickSpacing) that can ever be attached to this hook.
- **Updater**: pushes book updates. Hot key, rotatable.
- **Withdrawer**: executes withdrawals per offchain accounting. Separate from both so a compromised updater can't drain funds and the owner key stays cold.

Roles are plain `address` vars rather than OZ `AccessControl`: each role has exactly one holder, the check runs in the every-block hot path (`hasRole` adds keccaks + bytecode for multi-holder semantics nobody needs), and a plain compare has no grant/revoke edge cases.

## Building

```bash
forge build
```
