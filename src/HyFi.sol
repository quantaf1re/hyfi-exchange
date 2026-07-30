// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title HyFi
/// @notice The onchain component of the HyFi hybrid exchange. A Uniswap v4 hook that holds all
/// deposited liquidity as PoolManager ERC-6909 claims and prices swaps against a compressed,
/// offchain-aggregated orderbook that a permissioned updater pushes onchain every block.
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
/// Deployment: the hook address must have exactly the beforeInitialize, beforeSwap and
/// beforeSwapReturnDelta flag bits set (mined via CREATE2).
contract HyFi is IHooks, IUnlockCallback, Ownable2Step {
    using SafeERC20 for IERC20;
    using SafeCast for uint;

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    /// @notice Fixed-point scale of `tickWidth` (quote-wei per base-wei, scaled by 1e24)
    uint public constant SCALE = 1e24;
    /// @notice Pips denominator (1e-6). The staleness fee is capped at 100%
    uint public constant PIPS = 1e6;
    /// @notice Number of ticks per side of a book
    uint public constant NUM_TICKS = 68;

    uint internal constant HEAD_TICKS = 4; // ticks stored in slot0
    uint internal constant WORD_TICKS = 32; // ticks per full word
    uint internal constant MAX_TICK_INDEX = 67;

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

    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

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

    struct CallbackData {
        bool isDeposit;
        Currency currency;
        uint amount;
        address account;
    }

    /// @dev In-memory walk state. cur/amountLeft are updated by the walk kernels.
    struct WalkParams {
        uint slot0;
        uint tip;
        uint tickWidth;
        uint liqUnit;
        uint cur;
        uint amountLeft;
        uint end;
        bool isBid;
    }

    /// @dev Scratch space for beforeSwap (avoids stack-too-deep)
    struct TradeState {
        PoolId poolId;
        bool isExactInput;
        bool isSellingBase;
        uint amountIn;
        uint amountOut;
        uint fee;
    }

    // ------------------------------------------------------------------
    // State
    // ------------------------------------------------------------------

    IPoolManager public immutable poolManager;

    /// @notice Address permitted to push compressed book updates
    address public updater;
    /// @notice Address permitted to execute withdrawals (per offchain CEX accounting)
    address public withdrawer;

    mapping(PoolId => PairConfig) public pairConfig;
    mapping(PoolId => Book) internal books;

    // ------------------------------------------------------------------
    // Events / errors
    // ------------------------------------------------------------------

    event Deposit(address indexed depositor, address indexed beneficiary, Currency indexed currency, uint amount);
    event Withdrawal(address indexed recipient, Currency indexed currency, uint amount);
    event UpdaterSet(address updater);
    event WithdrawerSet(address withdrawer);
    event PairConfigSet(
        PoolId indexed poolId, uint128 tickWidth, uint88 baseLiqUnit, uint24 feePerSecond, bool baseIsCurrency0
    );
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

    error NotPoolManager();
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
    error HookNotImplemented();

    // ------------------------------------------------------------------
    // Setup
    // ------------------------------------------------------------------

    modifier onlyPoolManager() {
        require(msg.sender == address(poolManager), NotPoolManager());
        _;
    }

    constructor(IPoolManager poolManager_, address owner_, address updater_, address withdrawer_) Ownable(owner_) {
        poolManager = poolManager_;
        updater = updater_;
        withdrawer = withdrawer_;
        Hooks.validateHookPermissions(
            IHooks(address(this)),
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
        emit UpdaterSet(updater_);
        emit WithdrawerSet(withdrawer_);
    }

    // ------------------------------------------------------------------
    // Owner
    // ------------------------------------------------------------------

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
        require(address(key.hooks) == address(this), InvalidPoolKey());
        require(tickWidth != 0 && baseLiqUnit != 0, InvalidConfig());
        PoolId poolId = key.toId();
        pairConfig[poolId] = PairConfig(tickWidth, baseLiqUnit, feePerSecond, baseIsCurrency0);

        // Clear tip/pointers/head ticks but keep timestamp+bookId so the slots stay non-zero.
        Book storage book = books[poolId];
        book.bid.slot0 &= TS_ID_MASK;
        book.ask.slot0 &= TS_ID_MASK;
        emit PairConfigSet(poolId, tickWidth, baseLiqUnit, feePerSecond, baseIsCurrency0);
    }

    // ------------------------------------------------------------------
    // Deposits / withdrawals (all liquidity is PoolManager ERC-6909 claims)
    // ------------------------------------------------------------------

    /// @notice Deposits `amount` of `currency`, credited to this contract as ERC-6909 claims.
    /// Tokens are pulled from the caller; `beneficiary` is who the deposit is attributed to
    /// offchain via the emitted event.
    function deposit(Currency currency, uint amount, address beneficiary) external payable {
        if (currency.isAddressZero()) {
            require(msg.value == amount, InvalidMsgValue());
        } else {
            require(msg.value == 0, InvalidMsgValue());
        }
        poolManager.unlock(abi.encode(CallbackData(true, currency, amount, msg.sender)));
        emit Deposit(msg.sender, beneficiary, currency, amount);
    }

    /// @notice Withdraws `amount` of `currency` to `recipient`. Only callable by the withdrawer,
    /// after the offchain CEX has removed the MM's liquidity and the book has been updated.
    function withdraw(Currency currency, uint amount, address recipient) external {
        require(msg.sender == withdrawer, NotWithdrawer());
        poolManager.unlock(abi.encode(CallbackData(false, currency, amount, recipient)));
        emit Withdrawal(recipient, currency, amount);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        CallbackData memory cb = abi.decode(data, (CallbackData));
        if (cb.isDeposit) {
            if (cb.currency.isAddressZero()) {
                poolManager.settle{value: cb.amount}();
            } else {
                poolManager.sync(cb.currency);
                IERC20(Currency.unwrap(cb.currency)).safeTransferFrom(cb.account, address(poolManager), cb.amount);
                poolManager.settle();
            }
            poolManager.mint(address(this), cb.currency.toId(), cb.amount);
        } else {
            poolManager.burn(address(this), cb.currency.toId(), cb.amount);
            poolManager.take(cb.currency, cb.account, cb.amount);
        }
        return "";
    }

    // ------------------------------------------------------------------
    // Book updates
    // ------------------------------------------------------------------

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

    // ------------------------------------------------------------------
    // Hook: swaps
    // ------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Custom-curve hook: prices the swap against the compressed book, settles both legs in
    /// ERC-6909 claims and returns deltas that zero out the core AMM swap entirely.
    function beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (TradeState memory t, WalkParams memory w, Side storage side, uint slot0) =
            _priceTrade(key.toId(), params.zeroForOne, params.amountSpecified);

        // Persist the walk pointer - the only book write a trade makes
        side.slot0 = (slot0 & CUR_LEFT_CLEAR) | (w.cur << CUR_SHIFT) | (w.amountLeft << LEFT_SHIFT);

        emit Trade(
            t.poolId,
            sender,
            uint40((slot0 >> ID_SHIFT) & MASK_40),
            t.isSellingBase,
            t.isExactInput,
            t.amountIn,
            t.amountOut,
            t.fee
        );

        return (IHooks.beforeSwap.selector, _settle(key, params.zeroForOne, t.isExactInput, t.amountIn, t.amountOut), 0);
    }

    /// @dev Prices a trade against the current book with no state changes. Shared by beforeSwap
    /// (which then persists the walk pointer and settles) and quote, so that quotes can never
    /// diverge from execution.
    function _priceTrade(PoolId poolId, bool zeroForOne, int amountSpecified)
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

        // Staleness fee in pips, accrued per second since the inputted book timestamp, capped at 100%
        // (book timestamps are validated <= block.timestamp at update time)
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
            isBid: t.isSellingBase
        });

        // The fee is always taken in the output token: the book is walked for the gross output
        // and the trader receives the net; the difference stays in the contract for the MMs.
        if (t.isExactInput) {
            t.amountIn = amtSpecified;
            uint grossOut = t.isSellingBase
                ? _walkBase(side, w, amtSpecified, false) // quote out: round down
                : _walkQuote(side, w, amtSpecified, true); // quote is the input
            t.fee = FullMath.mulDivRoundingUp(grossOut, feePips, PIPS);
            t.amountOut = grossOut - t.fee;
        } else {
            require(feePips < PIPS, BookTooStale());
            t.amountOut = amtSpecified;
            uint grossOut = FullMath.mulDivRoundingUp(amtSpecified, PIPS, PIPS - feePips);
            t.fee = grossOut - amtSpecified;
            t.amountIn = t.isSellingBase
                ? _walkQuote(side, w, grossOut, false) // quote is the output target, base in
                : _walkBase(side, w, grossOut, true); // quote in: round up
        }
    }

    /// @dev Settles both legs in 6909 claims (take the input, pay the output) and builds the
    /// BeforeSwapDelta that zeroes out the core swap and charges/credits the swapper.
    function _settle(PoolKey calldata key, bool zeroForOne, bool isExactInput, uint amountIn, uint amountOut)
        internal
        returns (BeforeSwapDelta)
    {
        (Currency inC, Currency outC) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        poolManager.mint(address(this), inC.toId(), amountIn);
        poolManager.burn(address(this), outC.toId(), amountOut);
        return isExactInput
            ? toBeforeSwapDelta(amountIn.toInt128(), -amountOut.toInt128())
            : toBeforeSwapDelta(-amountOut.toInt128(), amountIn.toInt128());
    }

    // ------------------------------------------------------------------
    // Walk kernels
    // ------------------------------------------------------------------

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
            require(i <= w.end, InsufficientLiquidity());
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
            require(i <= w.end, InsufficientLiquidity());
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
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @notice Quotes a trade using the exact same code path as execution. The result matches a
    /// swap executed against the same book state in the same second: the staleness fee accrues
    /// per second, and any preceding trade or book update changes the result. `bookId` identifies
    /// the snapshot the quote was priced against.
    /// @param amountSpecified Negative = exact input, positive = exact output (v4 convention)
    function quote(PoolId poolId, bool zeroForOne, int amountSpecified)
        external
        view
        returns (uint amountIn, uint amountOut, uint stalenessFee, uint40 bookId)
    {
        (TradeState memory t,,, uint slot0) = _priceTrade(poolId, zeroForOne, amountSpecified);
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

    // ------------------------------------------------------------------
    // Other hook callbacks
    // ------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Pools can only be initialized for pairs the owner has configured. Since the config is
    /// keyed by poolId, this pins the exact PoolKey (fee, tickSpacing, currencies).
    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        require(pairConfig[key.toId()].tickWidth != 0, PairNotConfigured());
        return IHooks.beforeInitialize.selector;
    }

    // Unused hooks - no permission flags set, so the PoolManager never calls them. Adding/removing
    // v4 concentrated liquidity is permitted, but that liquidity is never used by trades:
    // beforeSwap always returns a delta that zeroes out the core swap, so the AMM curve never
    // executes (and this contract never calls poolManager.swap itself, the one path that would
    // skip the hook).
    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external pure returns (bytes4) { revert HookNotImplemented(); }
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }
    function afterAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }
    function afterRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure returns (bytes4, BalanceDelta) { revert HookNotImplemented(); }
    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external pure returns (bytes4, int128) { revert HookNotImplemented(); }
    function beforeDonate(address, PoolKey calldata, uint, uint, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }
    function afterDonate(address, PoolKey calldata, uint, uint, bytes calldata)
        external pure returns (bytes4) { revert HookNotImplemented(); }
}
