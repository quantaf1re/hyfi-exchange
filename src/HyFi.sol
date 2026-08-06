// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseAggregatorHook} from "@uniswap/v4-hooks-public/aggregator-hooks/BaseAggregatorHook.sol";
import {IHookStats} from "./interfaces/IHookStats.sol";
import {IALFHook} from "./interfaces/IALFHook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title HyFi
/// @notice The onchain component of the HyFi hybrid exchange. Holds all deposited liquidity as
/// plain token balances (no ERC-6909 claims) and prices swaps against a compressed,
/// offchain-aggregated orderbook that a permissioned updater pushes onchain every block.
///
/// Two swap paths, both settled with exactly two token transfers and priced by the same code:
///  - `swapDirect`: called directly on this contract; pulls the input from the caller and pays
///    the output to the recipient. Never touches the PoolManager and carries no protocol fee.
///  - via Uniswap v4: this contract is a BaseAggregatorHook; the PoolManager's beforeSwap routes
///    into `_conductSwap`, which takes the swapper's input from the PoolManager to this contract
///    and lets the base settle the output from this contract's balance. The Uniswap pool-level
///    protocol fee (if set by governance) is applied by the base on top.
///
/// Each side of a pair's book fits in 3 storage slots:
///  - slot0: tipPrice (uint40, multiples of tickWidth) | timestamp (uint32, inputted) |
///           bookId (uint40, inputted) | curTick (uint8) | endTick (uint8) |
///           amountLeft (uint96, base wei remaining in curTick) | ticks 0-3 (4 x uint8)
///  - wordA: ticks 4-35  (32 x uint8, LSB-first)
///  - wordB: ticks 36-67 (32 x uint8, LSB-first)
/// => 68 ticks per side. Each tick holds `tickValue * baseLiqUnit` base-token wei of liquidity.
/// Tick i is priced at (tipPrice - i) * tickWidth on the bid side and (tipPrice + i) * tickWidth
/// on the ask side, where tickWidth is quote-wei per base-wei scaled by 1e24.
///
/// A trade walks the book from the tip and only rewrites curTick/amountLeft in slot0 (consumed
/// ticks are never zeroed - the pointer makes them unreachable). An update rewrites slot0 and
/// only the tick words the new book actually reaches into; ticks past endTick are left dirty
/// and are unreachable. Nothing is ever zeroed so book SSTOREs stay at the non-zero rate.
///
/// Deployment: the hook address must have exactly the beforeInitialize, beforeAddLiquidity,
/// beforeSwap and beforeSwapReturnDelta flag bits set (mined via CREATE2, per
/// BaseAggregatorHook.getHookPermissions).
contract HyFi is BaseAggregatorHook, IHookStats, IALFHook, Ownable2Step, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using SafeCast for uint;

    // =======================================================================
    // Constants
    // =======================================================================

    /// @notice Fixed-point scale of `tickWidth` (quote-wei per base-wei, scaled by 1e24)
    uint public constant SCALE = 1e24;
    /// @notice Pips denominator (1e-6). The staleness fee is capped at 100%
    uint public constant PIPS = 1e6;
    /// @notice Number of ticks per side of a book
    uint public constant NUM_TICKS = 68;

    uint internal constant HEAD_TICKS = 4; // ticks stored in slot0
    uint internal constant WORD_TICKS = 32; // ticks per full word
    uint internal constant MAX_TICK_INDEX = 67;
    uint internal constant Q96 = 0x1000000000000000000000000; // 2**96, Uniswap sqrt-price scale

    // slot0 bit layout
    uint internal constant TS_SHIFT = 40;
    uint internal constant ID_SHIFT = 72;
    uint internal constant CUR_SHIFT = 112;
    uint internal constant END_SHIFT = 120;
    uint internal constant LEFT_SHIFT = 128;
    uint internal constant HEAD_SHIFT = 224;

    uint internal constant MASK_8 = 0xFF;
    uint internal constant MASK_32 = 0xFFFFFFFF;
    uint internal constant MASK_40 = 0xFFFFFFFFFF;
    uint internal constant MASK_96 = 0xFFFFFFFFFFFFFFFFFFFFFFFF;
    uint internal constant TS_ID_MASK = (MASK_32 << TS_SHIFT) | (MASK_40 << ID_SHIFT);
    uint internal constant CUR_LEFT_CLEAR = ~((MASK_8 << CUR_SHIFT) | (MASK_96 << LEFT_SHIFT));

    // =======================================================================
    // Types
    // =======================================================================

    struct PairConfig {
        /// @dev Quote-wei per base-wei, scaled by 1e24. Also the price distance between ticks.
        /// Token decimal differences are baked in by the owner when configuring.
        uint128 tickWidth;
        /// @dev Base-token wei represented by 1 unit of tick liquidity.
        /// uint88 guarantees 255 * baseLiqUnit always fits amountLeft's uint96.
        uint88 baseLiqUnit;
        /// @dev Staleness fee in pips (1e-6) charged per second elapsed since the book timestamp.
        uint24 feePerSecond;
        /// @dev Whether the pair's nominal base token is the pool's currency0.
        bool baseIsCurrency0;
    }

    struct Side {
        uint slot0;
        uint wordA;
        uint wordB;
    }

    struct Book {
        Side bid;
        Side ask;
    }

    struct SideUpdate {
        /// @dev Price of the best order, in multiples of tickWidth.
        uint40 tipPrice;
        /// @dev Index of the last tick of the book. Ticks past this are unreachable.
        uint8 endTick;
        /// @dev Ticks 0-3, tick i at bits [8i, 8i+8).
        uint32 headTicks;
        /// @dev Ticks 4-35 pre-packed (tick i at bits [8(i-4), ...)). Ignored unless endTick >= 4.
        uint wordA;
        /// @dev Ticks 36-67 pre-packed. Ignored unless endTick >= 36.
        uint wordB;
    }

    struct PairUpdate {
        PoolId poolId;
        uint40 bookId;
        SideUpdate bid;
        SideUpdate ask;
    }

    /// @dev In-memory walk state. cur/amountLeft are updated by the walk kernels. When `simulate`
    /// is set (swapToPrice), the kernels also stop at `priceLimit` and on book exhaustion instead
    /// of reverting, reporting the unfilled portion of the target in `remaining`.
    struct WalkParams {
        uint slot0;
        uint tip;
        uint tickWidth;
        uint liqUnit;
        uint cur;
        uint amountLeft;
        uint end;
        bool isBid;
        bool simulate;
        uint priceLimit;
        uint remaining;
    }

    /// @dev Scratch space for trades (avoids stack-too-deep)
    struct TradeState {
        PoolId poolId;
        bool isExactInput;
        bool isSellingBase;
        uint amountIn;
        uint amountOut;
        uint fee;
    }

    // =======================================================================
    // State
    // =======================================================================

    /// @notice Address permitted to push compressed book updates
    address public updater;
    /// @notice Address permitted to execute withdrawals (per offchain CEX accounting)
    address public withdrawer;

    mapping(PoolId => PairConfig) public pairConfig;
    mapping(PoolId => Book) internal books;

    // =======================================================================
    // Events / Errors
    // =======================================================================

    event Deposit(address indexed depositor, address indexed beneficiary, Currency indexed currency, uint amount);
    event Withdrawal(address indexed recipient, Currency indexed currency, uint amount);
    event UpdaterSet(address updater);
    event WithdrawerSet(address withdrawer);
    event PairConfigSet(
        PoolId indexed poolId, uint128 tickWidth, uint88 baseLiqUnit, uint24 feePerSecond, bool baseIsCurrency0
    );
    /// @param sender The direct caller for swapDirect; the PoolManager for swaps via Uniswap
    /// (the base's HookSwap event carries the v4 router sender).
    /// @param amountIn Amount the trader paid (input token)
    /// @param amountOut Net amount the trader received (output token)
    /// @param stalenessFee Fee retained by the contract in the output token, attributed to MMs
    /// offchain. The book was walked for amountOut + stalenessFee of gross output.
    event Trade(
        PoolId indexed poolId,
        address indexed sender,
        uint40 bookId,
        bool isSellingBase,
        bool isExactInput,
        uint amountIn,
        uint amountOut,
        uint stalenessFee
    );

    error NotUpdater();
    error NotWithdrawer();
    error PairNotConfigured();
    error InvalidConfig();
    error InvalidPoolKey();
    error InvalidMsgValue();
    error FutureTimestamp();
    error StaleUpdate();
    error StaleBookId();
    error InvalidEndTick();
    error InvalidTipPrice();
    error InsufficientLiquidity();
    error BookTooStale();

    // =======================================================================
    // Setup
    // =======================================================================

    constructor(IPoolManager poolManager_, address owner_, address updater_, address withdrawer_)
        BaseAggregatorHook(poolManager_, "1.0.0")
        Ownable(owner_)
    {
        updater = updater_;
        withdrawer = withdrawer_;
        emit UpdaterSet(updater_);
        emit WithdrawerSet(withdrawer_);
    }

    // =======================================================================
    // Owner
    // =======================================================================

    function setUpdater(address updater_) external onlyOwner {
        updater = updater_;
        emit UpdaterSet(updater_);
    }

    function setWithdrawer(address withdrawer_) external onlyOwner {
        withdrawer = withdrawer_;
        emit WithdrawerSet(withdrawer_);
    }

    /// @notice Sets the config for a pair. Clears the pair's book (trades revert until the next book
    /// update) since the stored book is denominated in the old tickWidth/baseLiqUnit.
    /// @dev The config is keyed by poolId, so only the exact configured PoolKey (currencies, fee,
    /// tickSpacing, this hook) can be initialized on the PoolManager.
    function setPairConfig(
        PoolKey calldata key,
        uint128 tickWidth,
        uint88 baseLiqUnit,
        uint24 feePerSecond,
        bool baseIsCurrency0
    ) external onlyOwner {
        // HyFi pools are keyed with fee 0 and tickSpacing 1 so swapDirect can reconstruct the
        // PoolId from the token pair alone.
        require(address(key.hooks) == address(this) && key.fee == 0 && key.tickSpacing == 1, InvalidPoolKey());
        require(tickWidth != 0 && baseLiqUnit != 0, InvalidConfig());
        PoolId poolId = key.toId();
        pairConfig[poolId] = PairConfig(tickWidth, baseLiqUnit, feePerSecond, baseIsCurrency0);

        // Clear tip/pointers/head ticks but keep timestamp+bookId so the slots stay non-zero.
        Book storage book = books[poolId];
        book.bid.slot0 &= TS_ID_MASK;
        book.ask.slot0 &= TS_ID_MASK;
        emit PairConfigSet(poolId, tickWidth, baseLiqUnit, feePerSecond, baseIsCurrency0);
    }

    // =======================================================================
    // Deposits / Withdrawals
    // =======================================================================

    /// @notice Deposits `amount` of `currency` into the contract. Tokens are pulled from the
    /// caller; `beneficiary` is who the deposit is attributed to offchain via the emitted event.
    function deposit(Currency currency, uint amount, address beneficiary) external payable {
        if (currency.isAddressZero()) {
            require(msg.value == amount, InvalidMsgValue());
        } else {
            require(msg.value == 0, InvalidMsgValue());
            IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, address(this), amount);
        }
        emit Deposit(msg.sender, beneficiary, currency, amount);
    }

    /// @notice Withdraws `amount` of `currency` to `recipient`. Only callable by the withdrawer,
    /// after the offchain CEX has removed the MM's liquidity and the book has been updated.
    function withdraw(Currency currency, uint amount, address recipient) external {
        require(msg.sender == withdrawer, NotWithdrawer());
        currency.transfer(recipient, amount);
        emit Withdrawal(recipient, currency, amount);
    }

    // =======================================================================
    // Book Updates
    // =======================================================================

    /// @notice Replaces the books of the given pairs. Always updates both sides of each pair.
    /// @param updates Per-pair new tips, tick words and bookIds. Tick words are pre-packed
    /// offchain; only the words the new book reaches into (per endTick) are written.
    /// @param timestamp The offchain snapshot timestamp (seconds) shared by the whole batch.
    /// Used for staleness fee accrual. Not the execution timestamp.
    function updateBooks(PairUpdate[] calldata updates, uint32 timestamp) external {
        require(msg.sender == updater, NotUpdater());
        require(timestamp <= block.timestamp, FutureTimestamp());
        uint ts = timestamp;
        uint n = updates.length;
        for (uint i; i < n; ++i) {
            PairUpdate calldata u = updates[i];
            Book storage book = books[u.poolId];
            uint slot0 = book.bid.slot0;
            // Reject out-of-order updates (same timestamp allowed for same-block replacement)
            require(((slot0 >> TS_SHIFT) & MASK_32) <= ts, StaleUpdate());
            // bookIds must be strictly increasing per pair
            require(((slot0 >> ID_SHIFT) & MASK_40) < u.bookId, StaleBookId());
            _writeSide(book.bid, u.bid, u.bookId, ts, true);
            _writeSide(book.ask, u.ask, u.bookId, ts, false);
        }
    }

    function _writeSide(Side storage side, SideUpdate calldata u, uint bookId, uint ts, bool isBid) internal {
        uint end = u.endTick;
        require(end <= MAX_TICK_INDEX, InvalidEndTick());
        uint tip = u.tipPrice;
        // Bid prices descend from the tip: the last tick's price (tip - end) must stay positive
        require(isBid ? tip > end : tip != 0, InvalidTipPrice());

        // curTick and amountLeft reset to 0
        side.slot0 = tip | (ts << TS_SHIFT) | (bookId << ID_SHIFT) | (end << END_SHIFT) | (uint(u.headTicks) << HEAD_SHIFT);
        if (end >= HEAD_TICKS) {
            side.wordA = u.wordA;
            if (end >= HEAD_TICKS + WORD_TICKS) side.wordB = u.wordB;
        }
    }

    // =======================================================================
    // Swaps: Direct Path
    // =======================================================================

    /// @notice Exact-input direct swap against the book, without touching the PoolManager (and
    /// therefore without any Uniswap protocol fee). Pulls exactly `amountIn` of `tokenIn` from the
    /// caller and sends the resulting `tokenOut` to `recipient`. `tokenIn`/`tokenOut` are raw token
    /// addresses (address(0) = native).
    /// @return The actual (amountIn, amountOut); amountIn == the `amountIn` argument.
    function swapExactInDirect(address tokenIn, address tokenOut, uint amountIn, address recipient)
        external
        payable
        nonReentrant
        returns (uint, uint)
    {
        return _swapDirect(tokenIn, tokenOut, -amountIn.toInt256(), recipient);
    }

    /// @notice Exact-output direct swap against the book, without touching the PoolManager (and
    /// therefore without any Uniswap protocol fee). Sends exactly `amountOut` of `tokenOut` to
    /// `recipient`, pulling the required `tokenIn` from the caller. `tokenIn`/`tokenOut` are
    /// raw token addresses (address(0) = native).
    /// @return The actual (amountIn, amountOut); amountOut == the `amountOut` argument.
    function swapExactOutDirect(address tokenIn, address tokenOut, uint amountOut, address recipient)
        external
        payable
        nonReentrant
        returns (uint, uint)
    {
        return _swapDirect(tokenIn, tokenOut, amountOut.toInt256(), recipient);
    }

    /// @dev Shared direct-swap body. Reconstructs the PoolId from the token pair (HyFi pools are
    /// always keyed with fee 0, tickSpacing 1, and this hook), prices, and persists the trade, then
    /// settles both legs with real token transfers. Reverts PairNotConfigured if the pair is unset.
    /// @param amountSpecified Negative = exact input, positive = exact output (v4 convention)
    function _swapDirect(address tokenIn, address tokenOut, int amountSpecified, address recipient)
        internal
        returns (uint amountIn, uint amountOut)
    {
        // v4 sorts currencies ascending; tokenIn is currency0 iff it is the lower address.
        bool zeroForOne = tokenIn < tokenOut;
        (address c0, address c1) = zeroForOne ? (tokenIn, tokenOut) : (tokenOut, tokenIn);

        TradeState memory t = _trade(
            PoolKey(Currency.wrap(c0), Currency.wrap(c1), 0, 1, IHooks(address(this))).toId(),
            zeroForOne,
            amountSpecified
        );
        (amountIn, amountOut) = (t.amountIn, t.amountOut);

        // Pull the input
        if (tokenIn == address(0)) {
            require(msg.value >= amountIn, InvalidMsgValue());
            // Exact-output native swaps overpay up front; refund the excess
            uint refund = msg.value - amountIn;
            if (refund != 0) Currency.wrap(tokenIn).transfer(msg.sender, refund);
        } else {
            require(msg.value == 0, InvalidMsgValue());
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        }

        // Pay the output
        Currency.wrap(tokenOut).transfer(recipient, amountOut);
    }

    // =======================================================================
    // Swaps: Uniswap v4 Path (BaseAggregatorHook)
    // =======================================================================

    /// @inheritdoc BaseAggregatorHook
    /// @dev Prices the swap and persists the walk pointer, then takes the swapper's input from
    /// the PoolManager to this contract. Returns hasSettled = false so the base settles the
    /// output from this contract's balance (sync/transfer/settle, or settle-with-value for
    /// native) - two token transfers in total. The pool-level protocol fee, if any, is taken by
    /// the base afterwards.
    function _conductSwap(Currency, Currency takeCurrency, SwapParams calldata params, PoolId poolId)
        internal
        override
        returns (uint amountSettle, uint amountTake, bool hasSettled)
    {
        TradeState memory t = _trade(poolId, params.zeroForOne, params.amountSpecified);
        poolManager.take(takeCurrency, address(this), t.amountIn);
        return (t.amountOut, t.amountIn, false);
    }

    /// @inheritdoc BaseAggregatorHook
    /// @dev Same pricing code path as execution. The base applies the protocol fee on top.
    function _rawQuote(bool zeroToOne, int amountSpecified, PoolId poolId)
        internal
        view
        override
        returns (uint amountUnspecified)
    {
        (TradeState memory t,,,) = _priceTrade(poolId, zeroToOne, amountSpecified, false, 0);
        return amountSpecified < 0 ? t.amountOut : t.amountIn;
    }

    /// @dev Pools can only be initialized for pairs the owner has configured. Since the config is
    /// keyed by poolId, this pins the exact PoolKey (fee, tickSpacing, currencies). The base then
    /// registers the pool and polls the token jar.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        override
        returns (bytes4)
    {
        require(pairConfig[key.toId()].tickWidth != 0, PairNotConfigured());
        return super._beforeInitialize(sender, key, sqrtPriceX96);
    }

    /// @inheritdoc BaseAggregatorHook
    /// @dev Per-pair liquidity currently available for trading from the book. Can't get the balance of
    /// this address since it would be the amount for the 2 tokens across all pairs.
    function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint amount0, uint amount1) {
        return _bookLiquidity(poolId);
    }

    /// @dev Raw liquidity units (0-255) stored for tick `i`, read from a side's three words.
    function _tickUnits(uint slot0, uint wordA, uint wordB, uint i) internal pure returns (uint) {
        if (i < HEAD_TICKS) return (slot0 >> (HEAD_SHIFT + (i << 3))) & MASK_8;
        if (i < HEAD_TICKS + WORD_TICKS) return (wordA >> ((i - HEAD_TICKS) << 3)) & MASK_8;
        return (wordB >> ((i - HEAD_TICKS - WORD_TICKS) << 3)) & MASK_8;
    }

    /// @dev Remaining base-wei liquidity of a side, over the ticks a trade could still consume
    /// (curTick through endTick, honoring the partially-consumed amountLeft at curTick).
    function _sideBase(Side storage side, uint liqUnit) internal view returns (uint baseWei) {
        uint slot0 = side.slot0;
        uint cur = (slot0 >> CUR_SHIFT) & MASK_8;
        uint end = (slot0 >> END_SHIFT) & MASK_8;
        uint amountLeft = (slot0 >> LEFT_SHIFT) & MASK_96;
        uint wordA = side.wordA;
        uint wordB = side.wordB;
        for (uint i = cur; i <= end; ++i) {
            baseWei += (i == cur && amountLeft != 0) ? amountLeft : _tickUnits(slot0, wordA, wordB, i) * liqUnit;
        }
    }

    /// @dev Remaining bid-side liquidity valued in quote wei (each tick's base capacity x its
    /// price). Only valid for a bid side, where tick i is priced at (tip - i) * tickWidth.
    function _sideQuote(Side storage side, uint tickWidth, uint liqUnit) internal view returns (uint quoteWei) {
        uint slot0 = side.slot0;
        uint tip = slot0 & MASK_40;
        uint cur = (slot0 >> CUR_SHIFT) & MASK_8;
        uint end = (slot0 >> END_SHIFT) & MASK_8;
        uint amountLeft = (slot0 >> LEFT_SHIFT) & MASK_96;
        uint wordA = side.wordA;
        uint wordB = side.wordB;
        for (uint i = cur; i <= end; ++i) {
            uint avail = (i == cur && amountLeft != 0) ? amountLeft : _tickUnits(slot0, wordA, wordB, i) * liqUnit;
            if (avail != 0) quoteWei += FullMath.mulDiv(avail, (tip - i) * tickWidth, SCALE);
        }
    }

    // =======================================================================
    // Pricing
    // =======================================================================

    /// @dev Prices the trade, persists the walk pointer (the only book write a trade makes) and
    /// emits the Trade event. Token settlement is left to the caller.
    function _trade(PoolId poolId, bool zeroForOne, int amountSpecified) internal returns (TradeState memory t) {
        WalkParams memory w;
        Side storage side;
        uint slot0;
        (t, w, side, slot0) = _priceTrade(poolId, zeroForOne, amountSpecified, false, 0);

        // Persist the walk pointer
        side.slot0 = (slot0 & CUR_LEFT_CLEAR) | (w.cur << CUR_SHIFT) | (w.amountLeft << LEFT_SHIFT);

        emit Trade(
            poolId,
            msg.sender,
            uint40((slot0 >> ID_SHIFT) & MASK_40),
            t.isSellingBase,
            t.isExactInput,
            t.amountIn,
            t.amountOut,
            t.fee
        );
    }

    /// @dev Prices a trade against the current book with no state changes. Shared by _trade
    /// (which then persists the walk pointer), the direct quotes, and `swapToPrice`, so that
    /// quotes and price-bounded simulations can never diverge from execution. When `simulate` is
    /// set the walk stops at `priceLimit` (in book-price units) or on book exhaustion instead of
    /// reverting, and amounts are taken from the portion actually filled.
    function _priceTrade(PoolId poolId, bool zeroForOne, int amountSpecified, bool simulate, uint priceLimit)
        internal
        view
        returns (TradeState memory t, WalkParams memory w, Side storage side, uint slot0)
    {
        t.poolId = poolId;
        PairConfig memory cfg = pairConfig[poolId];
        require(cfg.tickWidth != 0, PairNotConfigured());

        t.isExactInput = amountSpecified < 0;
        uint amtSpecified = t.isExactInput ? uint(-amountSpecified) : uint(amountSpecified);

        // Selling base hits the bid side; selling quote hits the ask side
        t.isSellingBase = zeroForOne == cfg.baseIsCurrency0;
        side = t.isSellingBase ? books[poolId].bid : books[poolId].ask;
        slot0 = side.slot0;

        // Staleness fee in pips, accrued per second since the inputted book timestamp, capped at
        // 100% (book timestamps are validated <= block.timestamp at update time)
        uint feePips = (block.timestamp - ((slot0 >> TS_SHIFT) & MASK_32)) * cfg.feePerSecond;
        if (feePips > PIPS) feePips = PIPS;

        w = WalkParams({
            slot0: slot0,
            tip: slot0 & MASK_40,
            tickWidth: cfg.tickWidth,
            liqUnit: cfg.baseLiqUnit,
            cur: (slot0 >> CUR_SHIFT) & MASK_8,
            amountLeft: (slot0 >> LEFT_SHIFT) & MASK_96,
            end: (slot0 >> END_SHIFT) & MASK_8,
            isBid: t.isSellingBase,
            simulate: simulate,
            priceLimit: priceLimit,
            remaining: 0
        });

        // The fee is always taken in the output token: the book is walked for the gross output
        // and the trader receives the net; the difference stays in the contract for the MMs. Under
        // a price limit the walk can stop early, so amounts come from the gross output actually
        // filled (w.remaining is always 0 for a non-simulated / full fill, leaving these unchanged).
        if (t.isExactInput) {
            uint grossOut = t.isSellingBase
                ? _walkBase(side, w, amtSpecified, false) // quote out: round down
                : _walkQuote(side, w, amtSpecified, true); // quote is the input
            t.amountIn = amtSpecified - w.remaining;
            t.fee = FullMath.mulDivRoundingUp(grossOut, feePips, PIPS);
            t.amountOut = grossOut - t.fee;
        } else {
            require(feePips < PIPS, BookTooStale());
            uint grossTarget = FullMath.mulDivRoundingUp(amtSpecified, PIPS, PIPS - feePips);
            t.amountIn = t.isSellingBase
                ? _walkQuote(side, w, grossTarget, false) // quote is the output target, base in
                : _walkBase(side, w, grossTarget, true); // quote in: round up
            if (w.remaining == 0) {
                // Full fill: deliver exactly the requested net output.
                t.amountOut = amtSpecified;
                t.fee = grossTarget - amtSpecified;
            } else {
                // Price-limited partial fill: staleness fee on the gross output actually filled.
                uint grossFilled = grossTarget - w.remaining;
                t.fee = FullMath.mulDivRoundingUp(grossFilled, feePips, PIPS);
                t.amountOut = grossFilled - t.fee;
            }
        }
    }

    // =======================================================================
    // Walk Kernels
    // =======================================================================

    /// @dev Returns the liquidity (in base wei) available at tick `i`, lazily SLOADing the tick
    /// words only when the walk reaches them.
    function _avail(Side storage side, WalkParams memory w, uint i, uint[2] memory words, bool[2] memory isLoaded)
        internal
        view
        returns (uint)
    {
        uint liq;
        if (i < HEAD_TICKS) {
            liq = (w.slot0 >> (HEAD_SHIFT + (i << 3))) & MASK_8;
        } else if (i < HEAD_TICKS + WORD_TICKS) {
            if (!isLoaded[0]) {
                words[0] = side.wordA;
                isLoaded[0] = true;
            }
            liq = (words[0] >> ((i - HEAD_TICKS) << 3)) & MASK_8;
        } else {
            if (!isLoaded[1]) {
                words[1] = side.wordB;
                isLoaded[1] = true;
            }
            liq = (words[1] >> ((i - HEAD_TICKS - WORD_TICKS) << 3)) & MASK_8;
        }
        return liq * w.liqUnit;
    }

    /// @dev Walks the book consuming exactly `baseTarget` base wei of liquidity, returning the
    /// corresponding quote amount. isRoundUp when the quote amount is paid by the trader (exact
    /// output, buying base), rounded down when received by the trader (exact input, selling base).
    /// Reverts if the book is exhausted. Updates w.cur / w.amountLeft.
    function _walkBase(Side storage side, WalkParams memory w, uint baseTarget, bool isRoundUp)
        internal
        view
        returns (uint quoteAmount)
    {
        uint remaining = baseTarget;
        uint i = w.cur;
        uint start = i;
        uint newLeft;
        uint[2] memory words;
        bool[2] memory isLoaded;
        while (remaining != 0) {
            if (i > w.end) {
                if (w.simulate) break; // price-bounded simulation returns the partial fill
                revert InsufficientLiquidity();
            }
            uint avail;
            if (i == start && w.amountLeft != 0) {
                avail = w.amountLeft; // partially consumed tick from a previous trade
            } else {
                avail = _avail(side, w, i, words, isLoaded);
                if (avail == 0) {
                    unchecked { ++i; }
                    continue;
                }
            }
            uint price = (w.isBid ? w.tip - i : w.tip + i) * w.tickWidth;
            // Stop once the next tick's book price crosses the limit (checked pre-fee, as in v4)
            if (w.simulate && (w.isBid ? price < w.priceLimit : price > w.priceLimit)) break;
            if (remaining >= avail) {
                quoteAmount += isRoundUp ? FullMath.mulDivRoundingUp(avail, price, SCALE) : FullMath.mulDiv(avail, price, SCALE);
                remaining -= avail;
                unchecked { ++i; }
            } else {
                quoteAmount += isRoundUp ? FullMath.mulDivRoundingUp(remaining, price, SCALE) : FullMath.mulDiv(remaining, price, SCALE);
                newLeft = avail - remaining;
                remaining = 0;
            }
        }
        w.cur = i;
        w.amountLeft = newLeft;
        w.remaining = remaining;
    }

    /// @dev Walks the book consuming exactly `quoteTarget` quote wei, returning the corresponding
    /// base amount. quoteIsInput = true: the trader pays quote and receives the base (exact input,
    /// buying base) - full ticks cost rounded-up quote, partial base output rounded down.
    /// quoteIsInput = false: the trader receives the quote and pays base (exact output, selling
    /// base) - tick quote capacity rounded down, partial base input rounded up.
    /// Reverts if the book is exhausted. Updates w.cur / w.amountLeft.
    function _walkQuote(Side storage side, WalkParams memory w, uint quoteTarget, bool quoteIsInput)
        internal
        view
        returns (uint baseAmount)
    {
        uint remaining = quoteTarget;
        uint i = w.cur;
        uint start = i;
        uint newLeft;
        uint[2] memory words;
        bool[2] memory isLoaded;
        while (remaining != 0) {
            if (i > w.end) {
                if (w.simulate) break; // price-bounded simulation returns the partial fill
                revert InsufficientLiquidity();
            }
            uint avail;
            if (i == start && w.amountLeft != 0) {
                avail = w.amountLeft;
            } else {
                avail = _avail(side, w, i, words, isLoaded);
                if (avail == 0) {
                    unchecked { ++i; }
                    continue;
                }
            }
            uint price = (w.isBid ? w.tip - i : w.tip + i) * w.tickWidth;
            // Stop once the next tick's book price crosses the limit (checked pre-fee, as in v4)
            if (w.simulate && (w.isBid ? price < w.priceLimit : price > w.priceLimit)) break;
            uint availInQuote = quoteIsInput ? FullMath.mulDivRoundingUp(avail, price, SCALE) : FullMath.mulDiv(avail, price, SCALE);
            if (remaining >= availInQuote) {
                baseAmount += avail;
                remaining -= availInQuote;
                unchecked { ++i; }
            } else {
                uint basePart = quoteIsInput ? FullMath.mulDiv(remaining, SCALE, price) : FullMath.mulDivRoundingUp(remaining, SCALE, price);
                baseAmount += basePart;
                newLeft = avail - basePart;
                // rounding up can consume the tick exactly; 0 must mean "untouched tick"
                if (newLeft == 0) {
                    unchecked { ++i; }
                }
                remaining = 0;
            }
        }
        w.cur = i;
        w.amountLeft = newLeft;
        w.remaining = remaining;
    }

    // =======================================================================
    // Views
    // =======================================================================

    /// @notice Quotes a trade using the exact same code path as execution. The result matches a
    /// swap executed against the same book state in the same second: the staleness fee accrues
    /// per second, and any preceding trade or book update changes the result. `bookId` identifies
    /// the snapshot the quote was priced against. No protocol fee is included (matches
    /// swapDirect); for the via-Uniswap amounts use the base's quote(zeroToOne, amountSpecified,
    /// poolId), which applies the pool's protocol fee on top of this.
    /// @param amountSpecified Negative = exact input, positive = exact output (v4 convention)
    function quoteDirect(PoolId poolId, bool zeroForOne, int amountSpecified)
        external
        view
        returns (uint amountIn, uint amountOut, uint stalenessFee, uint40 bookId)
    {
        (TradeState memory t,,, uint slot0) = _priceTrade(poolId, zeroForOne, amountSpecified, false, 0);
        return (t.amountIn, t.amountOut, t.fee, uint40((slot0 >> ID_SHIFT) & MASK_40));
    }

    /// @notice Decoded view of one side of a pair's book
    function getBookSide(PoolId poolId, bool isSellingBase)
        external
        view
        returns (
            uint40 tipPrice,
            uint32 timestamp,
            uint40 bookId,
            uint8 curTick,
            uint8 endTick,
            uint96 amountLeft,
            uint8[68] memory ticks
        )
    {
        Side storage side = isSellingBase ? books[poolId].bid : books[poolId].ask;
        uint slot0 = side.slot0;
        tipPrice = uint40(slot0 & MASK_40);
        timestamp = uint32((slot0 >> TS_SHIFT) & MASK_32);
        bookId = uint40((slot0 >> ID_SHIFT) & MASK_40);
        curTick = uint8((slot0 >> CUR_SHIFT) & MASK_8);
        endTick = uint8((slot0 >> END_SHIFT) & MASK_8);
        amountLeft = uint96((slot0 >> LEFT_SHIFT) & MASK_96);
        uint wordA = side.wordA;
        uint wordB = side.wordB;
        for (uint i; i < NUM_TICKS; ++i) {
            if (i < HEAD_TICKS) ticks[i] = uint8((slot0 >> (HEAD_SHIFT + (i << 3))) & MASK_8);
            else if (i < HEAD_TICKS + WORD_TICKS) ticks[i] = uint8((wordA >> ((i - HEAD_TICKS) << 3)) & MASK_8);
            else ticks[i] = uint8((wordB >> ((i - HEAD_TICKS - WORD_TICKS) << 3)) & MASK_8);
        }
    }

    /// @notice Raw 3-slot view of one side of a pair's book
    function getBookSideRaw(PoolId poolId, bool isSellingBase) external view returns (uint slot0, uint wordA, uint wordB) {
        Side storage side = isSellingBase ? books[poolId].bid : books[poolId].ask;
        (slot0, wordA, wordB) = (side.slot0, side.wordA, side.wordB);
    }

    // =======================================================================
    // URC-3 Hook Stats Reporting
    // =======================================================================

    /// @dev Shared book-liquidity accounting behind `pseudoTotalValueLocked`, `getReserves` and
    /// `getEffectiveLiquidity`: the ask side's remaining base-wei and the bid side's remaining
    /// value in quote-wei, ordered by which currency is the pair's base.
    function _bookLiquidity(PoolId poolId) internal view returns (uint amount0, uint amount1) {
        PairConfig memory cfg = pairConfig[poolId];
        Book storage book = books[poolId];
        uint baseAmt = _sideBase(book.ask, cfg.baseLiqUnit);
        uint quoteAmt = _sideQuote(book.bid, cfg.tickWidth, cfg.baseLiqUnit);
        (amount0, amount1) = cfg.baseIsCurrency0 ? (baseAmt, quoteAmt) : (quoteAmt, baseAmt);
    }

    /// @inheritdoc IHookStats
    /// @dev The book IS the hook's reserves (no separate custody to report): everything the hook
    /// holds for a pair is either sitting in the ask/bid book or already claimed by a trade, so
    /// this reuses the exact same per-pair book accounting as `pseudoTotalValueLocked`.
    function getReserves(PoolKey calldata key) external view returns (uint amount0, uint amount1) {
        return _bookLiquidity(key.toId());
    }

    /// @inheritdoc IHookStats
    /// @dev All of HyFi's book liquidity is immediately swappable (no time-locks, vaults or
    /// utilization limits), so effective liquidity equals total reserves - same underlying
    /// accounting as `pseudoTotalValueLocked`/`getReserves`.
    function getEffectiveLiquidity(PoolKey calldata key) external view returns (uint amount0, uint amount1) {
        return _bookLiquidity(key.toId());
    }

    /// @inheritdoc IHookStats
    function hook() external view returns (address) {
        return address(this);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IHookStats).interfaceId || interfaceId == type(IALFHook).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    // =======================================================================
    // URC-4 Active Liquidity Framework (ALF)
    // =======================================================================

    /// @notice Conservative gas budget routers may set on `getIndicativeQuote` calls. Sized for a
    /// full-book walk (68 ticks, cold SLOADs) plus the external self-call overhead.
    uint32 public constant MAX_QUOTE_GAS = 200_000;

    /// @inheritdoc IALFHook
    /// @dev Non-binding quote for the via-Uniswap trading path: priced by the same book code as
    /// execution and then grossed/netted by the pool's protocol fee. HyFi needs no payload, so
    /// `hookData` is ignored. Reverts for a pool key that is not this hook or an unconfigured
    /// pair; returns 0 for a zero amount or when the book cannot serve the swap (insufficient
    /// liquidity, too stale). Non-view because the base's `quote` refreshes the token jar.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata)
        external
        returns (uint256 quoteAmount)
    {
        require(address(key.hooks) == address(this), InvalidPoolKey());
        PoolId poolId = key.toId();
        require(pairConfig[poolId].tickWidth != 0, PairNotConfigured());
        if (amountSpecified == 0) return 0;

        // Unavailable liquidity / stale book must return 0 rather than revert; catch the pricing
        // reverts via an external self-call to the protocol-fee-inclusive quote. `quote` returns
        // the unspecified amount (output for exact-input, input for exact-output).
        try this.quote(zeroForOne, amountSpecified, poolId) returns (uint amountUnspecified) {
            return amountUnspecified;
        } catch {
            return 0;
        }
    }

    /// @inheritdoc IALFHook
    /// @dev HyFi has no oracle/attestation/external-venue dependency that can go stale at the hook
    /// level; per-pair unavailability surfaces through `getIndicativeQuote` returning 0.
    function isLive() external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IALFHook
    function maxGas() external pure returns (uint32) {
        return MAX_QUOTE_GAS;
    }

    /// @inheritdoc IALFHook
    /// @dev Price-bounded simulation of the via-Uniswap path, priced on the same `_priceTrade`
    /// code as execution. Converts the v4 `sqrtPriceLimitX96` into HyFi's book-price units and
    /// lets the book walk stop once a tick's raw (pre-fee) price crosses it or the amount is
    /// exhausted, whichever comes first, then layers on the pool's Uniswap protocol fee. The limit
    /// is compared pre-fee, exactly as v4 bounds the pool price before fees. Following the ALF / v4
    /// convention, "no limit" is expressed by MIN_SQRT_PRICE+1 / MAX_SQRT_PRICE-1 (which price the
    /// full amount, bounded only by available liquidity); a `sqrtPriceLimitX96` at or past
    /// MIN_SQRT_PRICE / MAX_SQRT_PRICE (including 0) is untradable and returns (0, 0), matching
    /// SwapSimulator's soft-fail contract. `amountSpecified` follows the v4 sign convention
    /// (negative = exact input, positive = exact-output net amount). Returns the realized (amountIn
    /// incl. fees, amountOut net); (0, 0) when nothing fills within the limit. Ignores `hookData`
    /// (HyFi needs no payload).
    function swapToPrice(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata
    ) external view returns (uint256 amountIn, uint256 amountOut) {
        require(address(key.hooks) == address(this), InvalidPoolKey());
        PoolId poolId = key.toId();
        PairConfig memory cfg = pairConfig[poolId];
        require(cfg.tickWidth != 0, PairNotConfigured());
        if (amountSpecified == 0) return (0, 0);
        // Only a limit strictly inside (MIN_SQRT_PRICE, MAX_SQRT_PRICE) is tradable, matching
        // SwapSimulator's soft-fail contract. "No limit" is signalled by MIN_SQRT_PRICE+1 /
        // MAX_SQRT_PRICE-1 (they convert to non-binding book limits below), not by 0; a 0 or any
        // out-of-range value is untradable and returns (0, 0).
        if (sqrtPriceLimitX96 <= TickMath.MIN_SQRT_PRICE || sqrtPriceLimitX96 >= TickMath.MAX_SQRT_PRICE) {
            return (0, 0);
        }

        // Convert the sqrt-price limit into book-price units, then price on the execution path.
        uint priceLimit = _priceLimitFromSqrt(sqrtPriceLimitX96, cfg.baseIsCurrency0, zeroForOne == cfg.baseIsCurrency0);
        (TradeState memory t,,,) = _priceTrade(poolId, zeroForOne, amountSpecified, true, priceLimit);
        (amountIn, amountOut) = (t.amountIn, t.amountOut);
        if (amountOut == 0) return (0, 0); // best book price already past the limit

        // Layer on the Uniswap protocol fee (view mirror of BaseAggregatorHook._innerQuote).
        uint24 protocolFee = _getProtocolFee(poolManager, zeroForOne, poolId);
        if (protocolFee != 0 && _getTokenJar(poolManager) != address(0)) {
            if (amountSpecified < 0) {
                amountOut -= _calculateProtocolFeeAmount(protocolFee, true, amountOut);
            } else {
                amountIn += _calculateProtocolFeeAmount(protocolFee, false, amountIn);
            }
        }
    }

    /// @dev Converts a v4 `sqrtPriceLimitX96` (Q64.96 sqrt of currency1/currency0) into HyFi's
    /// book-price units (quote-wei per base-wei, scaled by 1e24) so it can be compared directly to
    /// a tick's `(tip +/- i) * tickWidth`. Accounts for base/quote orientation (quote/base = P
    /// when the base is currency0, else 1/P) and rounds so a tick sitting exactly at the limit is
    /// still fillable (down for a bid floor, up for an ask ceiling): the walk includes trades at
    /// exactly `priceLimit`, so the boundary tick is never rounded out of range.
    function _priceLimitFromSqrt(uint160 sqrtPriceLimitX96, bool baseIsCurrency0, bool isBid)
        internal
        pure
        returns (uint priceLimit)
    {
        uint priceX96 = FullMath.mulDiv(uint(sqrtPriceLimitX96), uint(sqrtPriceLimitX96), Q96); // P * 2**96
        if (baseIsCurrency0) {
            // quote/base = P  =>  L = P * 1e24
            priceLimit = isBid
                ? FullMath.mulDiv(priceX96, SCALE, Q96)
                : FullMath.mulDivRoundingUp(priceX96, SCALE, Q96);
        } else {
            // quote/base = 1/P  =>  L = 1e24 / P.  P -> 0 leaves no upper bound on quote/base.
            if (priceX96 == 0) return type(uint).max;
            priceLimit = isBid
                ? FullMath.mulDiv(SCALE, Q96, priceX96)
                : FullMath.mulDivRoundingUp(SCALE, Q96, priceX96);
        }
    }
}
