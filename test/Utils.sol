// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {HyFi} from "../src/HyFi.sol";
import {Addrs} from "../script/Addrs.sol";
import {CommonBase} from "forge-std/Base.sol";
import {console2} from "forge-std/console2.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "@uniswap/v4-periphery/src/libraries/ActionConstants.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface IUniversalRouterMinimal {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint deadline) external payable;
}

interface IPermit2Minimal {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function allowance(address owner, address token, address spender) external view returns (uint160 amount, uint48 expiration, uint48 nonce);
}

/// @notice Stateless helpers + shared constants for tests and future scripts. Functions take all
/// relevant values as inputs (no instantiated state) so any contract can inherit or call them.
/// Inherits CommonBase for `vm`, which both forge-std Test and Script provide.
contract Utils is CommonBase {
    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------

    uint public constant SCALE = 1e24; // must match HyFi.SCALE
    uint public constant PIPS = 1e6; // must match HyFi.PIPS
    uint public constant NUM_TICKS = 68; // must match HyFi.NUM_TICKS

    /// @dev beforeInitialize | beforeSwap | beforeSwapReturnDelta
    uint160 public constant HOOK_FLAGS = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);

    uint160 public constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 public constant DEFAULT_FEE = 0;
    int24 public constant DEFAULT_TICK_SPACING = 1;
    address public constant ADDR_ZERO = address(0);

    // ------------------------------------------------------------------
    // Hook deployment
    // ------------------------------------------------------------------

    /// @notice Mines a CREATE2 salt such that the deployed address carries exactly HOOK_FLAGS
    function mineHookSalt(address deployer, bytes memory creationCodeWithArgs)
        public
        view
        returns (bytes32 salt, address hook)
    {
        bytes32 initHash = keccak256(creationCodeWithArgs);
        for (uint i; i < 500_000; ++i) {
            address a = address(uint160(uint(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), initHash)))));
            if ((uint160(a) & ALL_HOOK_MASK) == HOOK_FLAGS && a.code.length == 0) return (bytes32(i), a);
        }
        revert("Utils: hook salt not found");
    }

    // ------------------------------------------------------------------
    // Pool keys / pair config
    // ------------------------------------------------------------------

    /// @notice Builds the canonical PoolKey for a nominal base/quote pair with the given hook
    function poolKeyFor(address base, address quote, address hook)
        public
        pure
        returns (PoolKey memory key, bool baseIsCurrency0)
    {
        baseIsCurrency0 = base < quote;
        (address c0, address c1) = baseIsCurrency0 ? (base, quote) : (quote, base);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: DEFAULT_FEE,
            tickSpacing: DEFAULT_TICK_SPACING,
            hooks: IHooks(hook)
        });
    }

    /// @notice tickWidth (quote-wei per base-wei, x1e24) for a tick worth `tickQuoteWei` of the
    /// quote token per 1 whole base token
    function calcTickWidth(uint tickQuoteWei, uint8 baseDecimals) public pure returns (uint128) {
        return uint128(tickQuoteWei * SCALE / (10 ** baseDecimals));
    }

    // ------------------------------------------------------------------
    // Book packing
    // ------------------------------------------------------------------

    /// @notice Packs a tick array (index 0 = tip) into the slot0 head + word layout, LSB-first
    function packTicks(uint8[] memory ticks) public pure returns (uint32 headTicks, uint wordA, uint wordB) {
        require(ticks.length > 0 && ticks.length <= NUM_TICKS, "Utils: bad tick count");
        for (uint i; i < ticks.length; ++i) {
            if (i < 4) headTicks |= uint32(ticks[i]) << uint32(i * 8);
            else if (i < 36) wordA |= uint(ticks[i]) << ((i - 4) * 8);
            else wordB |= uint(ticks[i]) << ((i - 36) * 8);
        }
    }

    /// @notice Builds a SideUpdate from a tick array; endTick = last index of the array
    function sideUpdate(uint40 tipPrice, uint8[] memory ticks) public pure returns (HyFi.SideUpdate memory u) {
        (uint32 head, uint wordA, uint wordB) = packTicks(ticks);
        u = HyFi.SideUpdate({
            tipPrice: tipPrice,
            endTick: uint8(ticks.length - 1),
            headTicks: head,
            wordA: wordA,
            wordB: wordB
        });
    }

    function pairUpdate(PoolId poolId, uint40 bookId, HyFi.SideUpdate memory bid, HyFi.SideUpdate memory ask)
        public
        pure
        returns (HyFi.PairUpdate[] memory updates)
    {
        updates = new HyFi.PairUpdate[](1);
        updates[0] = HyFi.PairUpdate({poolId: poolId, bookId: bookId, bid: bid, ask: ask});
    }

    /// @notice Packs the fields of a side's slot0 exactly as HyFi stores them
    function packSlot0(uint40 tipPrice, uint32 timestamp, uint40 bookId, uint8 curTick, uint8 endTick, uint96 amountLeft, uint32 headTicks)
        public
        pure
        returns (uint)
    {
        return uint(tipPrice) | (uint(timestamp) << 40) | (uint(bookId) << 72) | (uint(curTick) << 112)
            | (uint(endTick) << 120) | (uint(amountLeft) << 128) | (uint(headTicks) << 224);
    }

    // ------------------------------------------------------------------
    // Pricing math (mirrors HyFi's formulas for building expected values)
    // ------------------------------------------------------------------

    /// @notice Price of tick i (quote-wei per base-wei, x1e24)
    function tickPrice(uint tip, uint i, bool isBid, uint tickWidth) public pure returns (uint) {
        return (isBid ? tip - i : tip + i) * tickWidth;
    }

    function baseToQuote(uint baseAmount, uint price, bool roundUp) public pure returns (uint) {
        return roundUp ? FullMath.mulDivRoundingUp(baseAmount, price, SCALE) : FullMath.mulDiv(baseAmount, price, SCALE);
    }

    function quoteToBase(uint quoteAmount, uint price, bool roundUp) public pure returns (uint) {
        return
            roundUp ? FullMath.mulDivRoundingUp(quoteAmount, SCALE, price) : FullMath.mulDiv(quoteAmount, SCALE, price);
    }

    /// @notice Converts a pool's sqrtPriceX96 into a nominal price scaled 1e18, adjusting for
    /// each token's decimals. `invert = false` returns token0's price in terms of token1
    /// (token1 per token0); `invert = true` returns the reciprocal (token0 per token1).
    function getPriceFromSqrtPriceX96(uint160 sqrtPriceX96, bool invert, uint8 decimals0, uint8 decimals1)
        public
        pure
        returns (uint price1e18)
    {
        uint ratioX192 = uint(sqrtPriceX96) * uint(sqrtPriceX96);
        if (!invert) {
            uint scaled = FullMath.mulDiv(ratioX192, 10 ** decimals0, 1 << 192);
            price1e18 = FullMath.mulDiv(scaled, 1e18, 10 ** decimals1);
        } else {
            uint scaled = FullMath.mulDiv(1 << 192, 10 ** decimals1, ratioX192);
            price1e18 = FullMath.mulDiv(scaled, 1e18, 10 ** decimals0);
        }
    }

    /// @notice Implied nominal price (output per input) from a quoted in/out pair, scaled 1e18
    function priceFromQuote(uint amountIn, uint amountOut, uint8 decimalsIn, uint8 decimalsOut)
        public
        pure
        returns (uint price1e18)
    {
        if (amountIn == 0) return 0;
        uint scaled = FullMath.mulDiv(amountOut, 10 ** decimalsIn, amountIn);
        price1e18 = FullMath.mulDiv(scaled, 1e18, 10 ** decimalsOut);
    }

    /// @notice Staleness fee on a gross output amount
    function stalenessFee(uint grossOut, uint elapsedSeconds, uint feePerSecond) public pure returns (uint) {
        uint feePips = elapsedSeconds * feePerSecond;
        if (feePips > PIPS) feePips = PIPS;
        return FullMath.mulDivRoundingUp(grossOut, feePips, PIPS);
    }

    /// @notice Gross output that must be walked for the trader to net `amountOut`
    function grossUpOutput(uint amountOut, uint elapsedSeconds, uint feePerSecond) public pure returns (uint) {
        uint feePips = elapsedSeconds * feePerSecond;
        if (feePips > PIPS) feePips = PIPS;
        return FullMath.mulDivRoundingUp(amountOut, PIPS, PIPS - feePips);
    }

    /// @notice Independent reimplementation of the base-consuming walk (fresh book, cur = 0),
    /// for constructing expected values on multi-tick fills
    function expectedWalkBase(
        uint8[] memory ticks,
        uint tip,
        bool isBid,
        uint tickWidth,
        uint liqUnit,
        uint baseTarget,
        bool roundUp
    ) public pure returns (uint quoteAmount) {
        uint remaining = baseTarget;
        for (uint i; i < ticks.length && remaining != 0; ++i) {
            uint avail = uint(ticks[i]) * liqUnit;
            if (avail == 0) continue;
            uint take = remaining >= avail ? avail : remaining;
            quoteAmount += baseToQuote(take, tickPrice(tip, i, isBid, tickWidth), roundUp);
            remaining -= take;
        }
        require(remaining == 0, "Utils: book too small");
    }

    /// @notice Independent reimplementation of the quote-consuming walk (fresh book, cur = 0)
    function expectedWalkQuote(
        uint8[] memory ticks,
        uint tip,
        bool isBid,
        uint tickWidth,
        uint liqUnit,
        uint quoteTarget,
        bool quoteIsInput
    ) public pure returns (uint baseAmount) {
        uint remaining = quoteTarget;
        for (uint i; i < ticks.length && remaining != 0; ++i) {
            uint avail = uint(ticks[i]) * liqUnit;
            if (avail == 0) continue;
            uint price = tickPrice(tip, i, isBid, tickWidth);
            uint tickQuote = baseToQuote(avail, price, quoteIsInput);
            if (remaining >= tickQuote) {
                baseAmount += avail;
                remaining -= tickQuote;
            } else {
                baseAmount += quoteToBase(remaining, price, !quoteIsInput);
                remaining = 0;
            }
        }
        require(remaining == 0, "Utils: book too small");
    }

    // ------------------------------------------------------------------
    // Universal Router calldata
    // ------------------------------------------------------------------

    function encodeExactInSingle(PoolKey memory key, bool zeroForOne, uint128 amountIn, uint128 minOut)
        public
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: minOut,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        params[1] = abi.encode(cin, uint(amountIn));
        params[2] = abi.encode(cout, uint(minOut));
        commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    function encodeExactOutSingle(PoolKey memory key, bool zeroForOne, uint128 amountOut, uint128 maxIn)
        public
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(
            IV4Router.ExactOutputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountOut: amountOut,
                amountInMaximum: maxIn,
                minHopPriceX36: 0,
                hookData: ""
            })
        );
        (Currency cin, Currency cout) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        params[1] = abi.encode(cin, uint(maxIn));
        params[2] = abi.encode(cout, uint(amountOut));
        commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);
    }

    // ------------------------------------------------------------------
    // Small array literals
    // ------------------------------------------------------------------

    function ticksArr(uint8 a) public pure returns (uint8[] memory t) {
        t = new uint8[](1);
        t[0] = a;
    }

    function ticksArr(uint8 a, uint8 b) public pure returns (uint8[] memory t) {
        t = new uint8[](2);
        (t[0], t[1]) = (a, b);
    }

    function ticksArr(uint8 a, uint8 b, uint8 c) public pure returns (uint8[] memory t) {
        t = new uint8[](3);
        (t[0], t[1], t[2]) = (a, b, c);
    }

    function ticksArr(uint8 a, uint8 b, uint8 c, uint8 d, uint8 e) public pure returns (uint8[] memory t) {
        t = new uint8[](5);
        (t[0], t[1], t[2], t[3], t[4]) = (a, b, c, d, e);
    }

    /// @notice A tick array of `n` entries all equal to `v`
    function ticksFill(uint n, uint8 v) public pure returns (uint8[] memory t) {
        t = new uint8[](n);
        for (uint i; i < n; ++i) {
            t[i] = v;
        }
    }

    // ------------------------------------------------------------------
    // Typed address resolution (raw address table lives in script/Addrs.sol)
    // ------------------------------------------------------------------

    function getPm(uint chainId) public pure returns (IPoolManager) {
        return IPoolManager(Addrs.get(chainId, "PoolManager"));
    }

    function getRouter(uint chainId) public pure returns (IUniversalRouterMinimal) {
        return IUniversalRouterMinimal(Addrs.get(chainId, "UniversalRouter"));
    }

    function getPermit2(uint chainId) public pure returns (IPermit2Minimal) {
        return IPermit2Minimal(Addrs.get(chainId, "Permit2"));
    }

    function getHyFi(uint chainId) public pure returns (HyFi) {
        return HyFi(Addrs.get(chainId, "HyFi"));
    }

    /// @notice Resolves an ERC20 by its name/symbol in the address book
    function getERC20(uint chainId, string memory name) public pure returns (IERC20) {
        return IERC20(Addrs.get(chainId, name));
    }

    // ------------------------------------------------------------------
    // Console logging
    // ------------------------------------------------------------------

    /// @notice Formats a wei-denominated amount as a trimmed nominal decimal string, e.g.
    /// formatNumToStrDecimal(2.5e18, 18) = "2.5", formatNumToStrDecimal(3.4e6, 6) = "3.4"
    function formatNumToStrDecimal(uint amountWei, uint8 decimals) internal pure returns (string memory) {
        uint base = 10 ** decimals;
        uint whole = amountWei / base;
        uint frac = amountWei % base;
        if (frac == 0) return Strings.toString(whole);

        bytes memory fracDigits = bytes(Strings.toString(frac));
        bytes memory padded = new bytes(decimals);
        uint padLen = decimals - fracDigits.length;
        for (uint i; i < padLen; ++i) {
            padded[i] = "0";
        }
        for (uint i; i < fracDigits.length; ++i) {
            padded[padLen + i] = fracDigits[i];
        }

        uint end = padded.length;
        while (end > 0 && padded[end - 1] == "0") {
            --end;
        }
        bytes memory trimmed = new bytes(end);
        for (uint i; i < end; ++i) {
            trimmed[i] = padded[i];
        }
        return string(abi.encodePacked(Strings.toString(whole), ".", trimmed));
    }

    /// @notice Logs a labeled wei-denominated token amount as "label: 2.5 NVDA"
    function logTokenAmount(string memory label, string memory symbol, uint amount, uint8 decimals) internal pure {
        console2.log(string.concat(label, ": ", formatNumToStrDecimal(amount, decimals), " ", symbol));
    }

    // ------------------------------------------------------------------
    // Onchain actions - core (no cheatcodes; broadcast-safe for mainnet scripts,
    // executed as msg.sender / the broadcaster). Wrap multi-call cores in
    // vm.startBroadcast()/stopBroadcast() so every inner call is broadcast.
    // ------------------------------------------------------------------

    /// @notice Deposits `amount` of `currency` into the hook, credited to `beneficiary`.
    /// Pulls tokens from / sends value as msg.sender.
    function deposit(HyFi hyfi, Currency currency, uint amount, address beneficiary) public {
        if (currency.isAddressZero()) {
            hyfi.deposit{value: amount}(currency, amount, beneficiary);
        } else {
            IERC20(Currency.unwrap(currency)).approve(address(hyfi), amount);
            hyfi.deposit(currency, amount, beneficiary);
        }
    }

    /// @notice Grants `router` a max Permit2 allowance for `token` as msg.sender
    function approveRouter(IPermit2Minimal permit2, address router, address token) public {
        IERC20(token).approve(address(permit2), type(uint).max);
        permit2.approve(token, router, type(uint160).max, type(uint48).max);
    }

    /// @notice Pushes a single-pair book update as msg.sender (must be the updater). The caller
    /// supplies the bookId (must be strictly increasing per pair) and the inputted timestamp.
    function updateBook(
        HyFi hyfi,
        PoolId id,
        uint40 bookId,
        uint40 bidTip,
        uint40 askTip,
        uint8[] memory bidTicks,
        uint8[] memory askTicks,
        uint32 ts
    ) public {
        hyfi.updateBooks(pairUpdate(id, bookId, sideUpdate(bidTip, bidTicks), sideUpdate(askTip, askTicks)), ts);
    }

    /// @notice Executes an exact-input single swap through the Universal Router as msg.sender
    /// @param sellingBase true = sell base for quote (hits bid side)
    function swapExactIn(
        IUniversalRouterMinimal router,
        PoolKey memory key,
        bool baseIsCurrency0,
        bool sellingBase,
        uint128 amountIn,
        uint128 minOut
    ) public {
        bool zeroForOne = sellingBase == baseIsCurrency0;
        (bytes memory commands, bytes[] memory inputs) = encodeExactInSingle(key, zeroForOne, amountIn, minOut);
        Currency cin = zeroForOne ? key.currency0 : key.currency1;
        uint value = cin.isAddressZero() ? amountIn : 0;
        router.execute{value: value}(commands, inputs, block.timestamp);
    }

    /// @notice Executes an exact-output single swap through the Universal Router as msg.sender
    /// @dev When the input currency is native, the router is over-funded with `maxIn` and a SWEEP
    /// returns the unspent ETH change to the caller.
    function swapExactOut(
        IUniversalRouterMinimal router,
        PoolKey memory key,
        bool baseIsCurrency0,
        bool sellingBase,
        uint128 amountOut,
        uint128 maxIn
    ) public {
        bool zeroForOne = sellingBase == baseIsCurrency0;
        Currency cin = zeroForOne ? key.currency0 : key.currency1;
        (bytes memory commands, bytes[] memory inputs) = encodeExactOutSingle(key, zeroForOne, amountOut, maxIn);
        if (cin.isAddressZero()) {
            // native input: over-fund with maxIn and sweep the unspent change back to the caller
            commands = abi.encodePacked(commands, uint8(Commands.SWEEP));
            bytes[] memory withSweep = new bytes[](2);
            withSweep[0] = inputs[0];
            withSweep[1] = abi.encode(Currency.wrap(address(0)), ActionConstants.MSG_SENDER, uint(0));
            router.execute{value: maxIn}(commands, withSweep, block.timestamp);
        } else {
            router.execute(commands, inputs, block.timestamp);
        }
    }

    // ------------------------------------------------------------------
    // Onchain actions - test variants that impersonate a specific actor via prank
    // (cheatcode-based; NOT usable in mainnet broadcast scripts)
    // ------------------------------------------------------------------

    function depositAs(HyFi hyfi, address from, Currency currency, uint amount) public {
        vm.startPrank(from);
        deposit(hyfi, currency, amount, from);
        vm.stopPrank();
    }

    function approveRouterAs(IPermit2Minimal permit2, address router, address user, address token) public {
        vm.startPrank(user);
        approveRouter(permit2, router, token);
        vm.stopPrank();
    }

    function updateBookAs(
        HyFi hyfi,
        address updater,
        PoolId id,
        uint40 bookId,
        uint40 bidTip,
        uint40 askTip,
        uint8[] memory bidTicks,
        uint8[] memory askTicks,
        uint32 ts
    ) public {
        vm.prank(updater);
        updateBook(hyfi, id, bookId, bidTip, askTip, bidTicks, askTicks, ts);
    }

    function swapExactInAs(
        IUniversalRouterMinimal router,
        PoolKey memory key,
        bool baseIsCurrency0,
        address user,
        bool sellingBase,
        uint128 amountIn,
        uint128 minOut
    ) public {
        vm.prank(user);
        swapExactIn(router, key, baseIsCurrency0, sellingBase, amountIn, minOut);
    }

    function swapExactOutAs(
        IUniversalRouterMinimal router,
        PoolKey memory key,
        bool baseIsCurrency0,
        address user,
        bool sellingBase,
        uint128 amountOut,
        uint128 maxIn
    ) public {
        vm.prank(user);
        swapExactOut(router, key, baseIsCurrency0, sellingBase, amountOut, maxIn);
    }

    // ------------------------------------------------------------------
    // State reads
    // ------------------------------------------------------------------

    /// @notice `holder`'s ERC-6909 claim balance for `currency` on the PoolManager
    function claims(IPoolManager pm, address holder, Currency currency) public view returns (uint) {
        return IERC6909Claims(address(pm)).balanceOf(holder, currency.toId());
    }

    /// @notice Raw 3-slot view of one side of a pair's book
    function rawSide(HyFi hyfi, PoolId id, bool isSellingBase)
        public
        view
        returns (uint slot0, uint wordA, uint wordB)
    {
        return hyfi.getBookSideRaw(id, isSellingBase);
    }

    // ------------------------------------------------------------------
    // Revert helpers
    // ------------------------------------------------------------------

    /// @notice Expected revert data when a hook callback reverts inside the PoolManager. The PM
    /// wraps the hook's inner error in CustomRevert.WrappedError(hook, hookSelector, reason, ctx).
    /// @param hookSelector the IHooks callback selector (e.g. IHooks.beforeSwap.selector)
    /// @param innerError the selector of the argless custom error the hook reverts with
    function hookRevert(address hook, bytes4 hookSelector, bytes4 innerError) public pure returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            hook,
            hookSelector,
            abi.encodeWithSelector(innerError),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }
}
