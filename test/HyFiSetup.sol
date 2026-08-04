// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {HyFi} from "../src/HyFi.sol";
import {Utils, IUniversalRouterMinimal, IPermit2Minimal} from "./Utils.sol";
import {TestToken} from "./mocks/TestToken.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IProtocolFees} from "@uniswap/v4-core/src/interfaces/IProtocolFees.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal view of the live v4 protocol-fee adapter (the PoolManager's protocolFeeController
/// on Robinhood Chain from block ~27,000,000). `triggerFeeUpdate` is permissionless and pushes the
/// policy's computed fee onto a pool; `TOKEN_JAR` is where collected protocol fees are sent.
interface IV4FeeAdapter {
    function triggerFeeUpdate(PoolKey calldata key) external;
    function TOKEN_JAR() external view returns (address);
}

/// @notice Shared fork-test fixture. Deploys the hook at a mined address, configures three pairs
/// with very different decimals/orderings, initializes their pools, funds an MM + trader, seeds
/// deposits and pushes an initial book for each pair.
///
/// Run with: forge test --fork-url robin --fork-block-number 27000000
abstract contract HyFiSetup is Test, Utils {
    using StateLibrary for IPoolManager;

    struct Pair {
        PoolKey key;
        PoolId id;
        Currency base;
        Currency quote;
        bool baseIsCurrency0;
        uint128 tickWidth;
        uint88 baseLiqUnit;
        uint24 feePerSecond;
        uint40 bidTip;
        uint40 askTip;
    }

    HyFi internal hyfi;
    IPoolManager internal pm = getPm(block.chainid);
    IUniversalRouterMinimal internal router = getRouter(block.chainid);
    IPermit2Minimal internal permit2 = getPermit2(block.chainid);

    address internal owner = makeAddr("owner");
    address internal updater = makeAddr("updater");
    address internal withdrawer = makeAddr("withdrawer");
    address internal mm = makeAddr("mm");
    address internal trader = makeAddr("trader");

    // Pair 1: NVDA (18 dec) / USDG (6 dec), base is currency1 (USDG address < NVDA address)
    Pair internal nvdaPair;
    // Pair 2: TOKA (6 dec) / TOKB (18 dec), base forced to currency0 - big inverse decimal gap
    Pair internal tokPair;
    // Pair 3: native ETH / USDG, base is currency0 (native = address(0))
    Pair internal ethPair;

    IERC20 internal usdg = getERC20(block.chainid, "USDG");
    IERC20 internal nvda = getERC20(block.chainid, "NVDA");
    TestToken internal toka;
    TestToken internal tokb;

    uint40 internal bookIdCounter;
    mapping(PoolId => uint40) internal lastBookId;
    uint8[] internal DEFAULT_TICKS = ticksArr(2, 3, 1);

    // --- Uniswap protocol fee (live from block ~27,000,000 on Robinhood Chain) ------------------
    // The v4 fee policy classifies our custom-accounting hook and assigns a raw per-direction
    // protocol fee; the aggregator base multiplies it by its protocolFeeMultiplier, so routed swaps
    // pay that effective pips amount on the unspecified side, skimmed to the token jar. Both are
    // read from the actual deployment in setUp (not hardcoded) so this tracks the live chain config.
    // Direct swaps/quotes bypass the PoolManager and never incur it.
    uint24 internal PROTOCOL_FEE_PIPS;
    address internal tokenJar;

    function setUp() public virtual {
        vm.label(address(pm), "PoolManager");
        vm.label(address(router), "UniversalRouter");
        vm.label(address(usdg), "USDG");
        vm.label(address(nvda), "NVDA");

        // Deploy the hook at a mined address carrying exactly the required flag bits
        bytes memory creation = abi.encodePacked(type(HyFi).creationCode, abi.encode(pm, owner, updater, withdrawer));
        (bytes32 salt,) = mineHookSalt(address(this), creation);
        hyfi = new HyFi{salt: salt}(pm, owner, updater, withdrawer);
        vm.label(address(hyfi), "HyFi");

        // TOKA (6 dec base) forced to a lower address than TOKB (18 dec quote) => baseIsCurrency0
        toka = new TestToken("Token A", "TOKA", 6);
        tokb = _deployTokbAbove(address(toka));

        // --- pair configs ---------------------------------------------------
        // NVDA/USDG: $0.01 ticks, 0.1 NVDA per liquidity unit, ~$180
        nvdaPair = _configurePair(
            Currency.wrap(address(nvda)),
            Currency.wrap(address(usdg)),
            calcTickWidth(10 ** 4, 18), // $0.01 in USDG wei per whole NVDA => 1e10
            uint88(1e17), // 0.1 NVDA
            100, // 100 pips/second staleness fee
            18000, // bid tip $180.00
            18001 // ask tip $180.01
        );
        // TOKA/TOKB: $0.01 ticks (in 18-dec TOKB), 10 TOKA per unit, ~$50
        tokPair = _configurePair(
            Currency.wrap(address(toka)),
            Currency.wrap(address(tokb)),
            calcTickWidth(10 ** 16, 6), // 0.01 TOKB per whole TOKA => 1e34
            uint88(10 * 1e6), // 10 TOKA
            100,
            5000, // bid tip $50.00
            5001 // ask tip $50.01
        );
        // ETH/USDG: $0.01 ticks, 0.1 ETH per unit, ~$3000
        ethPair = _configurePair(
            Currency.wrap(address(0)),
            Currency.wrap(address(usdg)),
            calcTickWidth(10 ** 4, 18), // 1e10
            uint88(1e17), // 0.1 ETH
            100,
            300000, // bid tip $3000.00
            300001 // ask tip $3000.01
        );

        // --- fund MM and deposit hook liquidity ------------------------------
        deal(address(usdg), mm, 10_000_000e6);
        deal(address(nvda), mm, 100_000e18);
        toka.mint(mm, 10_000_000e6);
        tokb.mint(mm, 10_000_000e18);
        vm.deal(mm, 10_000 ether);

        // Seed the PoolManager with a reserve buffer of the synthetic tokens. On the Uniswap path
        // the hook takes the swapper's input from the PoolManager before the swapper settles, so
        // the PoolManager must have that token on hand (the real fork tokens already do; these
        // freshly deployed test tokens would not). The buffer is preserved net across every swap.
        toka.mint(address(pm), 100_000_000e6);
        tokb.mint(address(pm), 100_000_000e18);

        depositAs(hyfi, mm, Currency.wrap(address(usdg)), 5_000_000e6);
        depositAs(hyfi, mm, Currency.wrap(address(nvda)), 50_000e18);
        depositAs(hyfi, mm, Currency.wrap(address(toka)), 5_000_000e6);
        depositAs(hyfi, mm, Currency.wrap(address(tokb)), 5_000_000e18);
        depositAs(hyfi, mm, Currency.wrap(address(0)), 5_000 ether);

        // --- fund trader and set router approvals ----------------------------
        deal(address(usdg), trader, 1_000_000e6);
        deal(address(nvda), trader, 10_000e18);
        toka.mint(trader, 1_000_000e6);
        tokb.mint(trader, 1_000_000e18);
        vm.deal(trader, 1_000 ether);
        approveRouterAs(permit2, address(router), trader, address(usdg));
        approveRouterAs(permit2, address(router), trader, address(nvda));
        approveRouterAs(permit2, address(router), trader, address(toka));
        approveRouterAs(permit2, address(router), trader, address(tokb));

        // --- initial books ----------------------------------------------------
        _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, DEFAULT_TICKS, DEFAULT_TICKS, uint32(block.timestamp));
        _updateBookAt(tokPair, tokPair.bidTip, tokPair.askTip, DEFAULT_TICKS, DEFAULT_TICKS, uint32(block.timestamp));
        _updateBookAt(ethPair, ethPair.bidTip, ethPair.askTip, DEFAULT_TICKS, DEFAULT_TICKS, uint32(block.timestamp));

        // --- switch on the live Uniswap protocol fee --------------------------
        // Freshly initialized pools carry a zero protocol fee until someone pushes the policy's
        // computed fee onto them. `triggerFeeUpdate` is permissionless; on the real chain the fee
        // infra has been triggered on live pools, so mirror that here for the via-Uniswap tests.
        IV4FeeAdapter feeAdapter = IV4FeeAdapter(IProtocolFees(address(pm)).protocolFeeController());
        tokenJar = feeAdapter.TOKEN_JAR();
        feeAdapter.triggerFeeUpdate(nvdaPair.key);
        feeAdapter.triggerFeeUpdate(tokPair.key);
        feeAdapter.triggerFeeUpdate(ethPair.key);

        // Read the effective protocol fee back from the live deployment: the raw per-direction fee
        // the policy just pushed onto the pool, times HyFi's own protocolFeeMultiplier. Both sides
        // are symmetric for our classification, so either direction's raw fee is representative.
        (,, uint24 rawProtocolFee,) = pm.getSlot0(nvdaPair.id);
        PROTOCOL_FEE_PIPS = uint24(ProtocolFeeLibrary.getZeroForOneFee(rawProtocolFee)) * hyfi.protocolFeeMultiplier();
    }

    // ------------------------------------------------------------------
    // Fixture helpers
    // ------------------------------------------------------------------

    /// @dev Deploys TOKB at an address strictly greater than `below` so TOKA is currency0
    function _deployTokbAbove(address below) internal returns (TestToken t) {
        for (uint i;; ++i) {
            bytes32 salt = keccak256(abi.encode("TOKB", i));
            address predicted = vm.computeCreate2Address(
                salt, keccak256(abi.encodePacked(type(TestToken).creationCode, abi.encode("Token B", "TOKB", uint8(18))))
            );
            if (predicted > below) {
                t = new TestToken{salt: salt}("Token B", "TOKB", 18);
                return t;
            }
        }
    }

    function _configurePair(
        Currency base,
        Currency quote,
        uint128 tickWidth,
        uint88 baseLiqUnit,
        uint24 feePerSecond,
        uint40 bidTip,
        uint40 askTip
    ) internal returns (Pair memory p) {
        (PoolKey memory key, bool baseIsCurrency0) = poolKeyFor(Currency.unwrap(base), Currency.unwrap(quote), address(hyfi));
        p = Pair({
            key: key,
            id: key.toId(),
            base: base,
            quote: quote,
            baseIsCurrency0: baseIsCurrency0,
            tickWidth: tickWidth,
            baseLiqUnit: baseLiqUnit,
            feePerSecond: feePerSecond,
            bidTip: bidTip,
            askTip: askTip
        });
        vm.prank(owner);
        hyfi.setPairConfig(key, tickWidth, baseLiqUnit, feePerSecond, baseIsCurrency0);
        pm.initialize(key, SQRT_PRICE_1_1);
    }

    /// @dev Pushes a book for `p`, tracking a fresh strictly-increasing bookId per pair
    function _updateBookAt(
        Pair memory p,
        uint40 bidTip,
        uint40 askTip,
        uint8[] memory bidTicks,
        uint8[] memory askTicks,
        uint32 ts
    ) internal returns (uint40 bookId) {
        bookId = ++bookIdCounter;
        updateBookAs(hyfi, updater, p.id, bookId, bidTip, askTip, bidTicks, askTicks, ts);
        lastBookId[p.id] = bookId;
    }

    /// @dev The bookId most recently pushed for a pair by the fixture helpers
    function _bookId(PoolId id) internal view returns (uint40) {
        return lastBookId[id];
    }

    // ------------------------------------------------------------------
    // Shared trade invariants (used by both swap paths)
    // ------------------------------------------------------------------
    // With real-token custody the two swap paths settle identically when the caller and the
    // recipient are the same trader: the hook gains `amountIn` of the input token and releases
    // `amountOut` of the output token, the trader is debited/credited symmetrically, and the
    // PoolManager's balances are net unchanged (it is bypassed entirely on the direct path, and
    // nets to zero on the Uniswap path). Only the traded side's walk pointer moves.
    //
    // SideSnap/TradeSnap and the pure snapshot builders (snapSide/snapTrade) live in Utils, since
    // they're stateless helpers; these thin wrappers just fill in this fixture's hyfi/pm/trader.

    function _snapSide(PoolId id, bool bidSide) internal view returns (SideSnap memory s) {
        return snapSide(hyfi, id, bidSide);
    }

    function _snapTrade(Pair memory p, bool sellingBase) internal view returns (TradeSnap memory s) {
        return snapTrade(hyfi, pm, trader, tokenJar, p.key, p.baseIsCurrency0, sellingBase);
    }

    /// @dev Full post-trade invariants against a `_snapTrade` snapshot: trader flows, the hook's
    /// real-token custody delta, the PoolManager left net-flat, the traded side's pointer moved to
    /// (expCur, expLeft) with everything else unchanged, the other side untouched, config unchanged.
    function _assertTrade(Pair memory p, TradeSnap memory s, uint amountIn, uint amountOut, uint8 expCur, uint96 expLeft)
        internal
        view
    {
        // trader token flow
        assertEq(s.traderIn - s.inC.balanceOf(trader), amountIn, "trader paid amountIn");
        assertEq(s.outC.balanceOf(trader) - s.traderOut, amountOut, "trader received amountOut");
        // the hook custodies real tokens: input in, output out
        assertEq(s.inC.balanceOf(address(hyfi)) - s.hookIn, amountIn, "hook gained input tokens");
        assertEq(s.hookOut - s.outC.balanceOf(address(hyfi)), amountOut, "hook released output tokens");
        // PoolManager balances net unchanged
        assertEq(s.inC.balanceOf(address(pm)), s.pmIn, "PM input balance unchanged");
        assertEq(s.outC.balanceOf(address(pm)), s.pmOut, "PM output balance unchanged");
        // traded side: only the pointer moved
        _assertSideMoved(p.id, s.tradedBid, s.tradedSide, expCur, expLeft);
        // other side fully unchanged
        _assertSideEq(p.id, !s.tradedBid, s.otherSide);
        // config unchanged
        _assertConfigUnchanged(p);
    }

    /// @dev Via-Uniswap counterpart to `_assertTrade`. The book trade is identical (same gross
    /// amountIn/amountOut, same pointer move), but the Uniswap protocol fee is skimmed from the
    /// PoolManager to the token jar on the unspecified side: the output for exact-in, the input for
    /// exact-out. So the trader receives `amountOut - fee` (exact-in) or pays `amountIn + fee`
    /// (exact-out), while the hook still custodies the gross book amounts and the PoolManager nets
    /// flat (the fee it hands the jar is reimbursed by the trader).
    function _assertTradeViaUni(
        Pair memory p,
        TradeSnap memory s,
        uint amountIn,
        uint amountOut,
        bool exactInput,
        uint8 expCur,
        uint96 expLeft
    ) internal view {
        uint fee = exactInput ? _uniFeeExactIn(amountOut) : _uniFeeExactOut(amountIn);
        uint traderIn = exactInput ? amountIn : amountIn + fee;
        uint traderOut = exactInput ? amountOut - fee : amountOut;

        // trader token flow, net of the protocol fee
        assertEq(s.traderIn - s.inC.balanceOf(trader), traderIn, "trader paid net input");
        assertEq(s.outC.balanceOf(trader) - s.traderOut, traderOut, "trader received net output");
        // the hook custodies real tokens at the gross book amounts (the fee leaves the PM, not the hook)
        assertEq(s.inC.balanceOf(address(hyfi)) - s.hookIn, amountIn, "hook gained gross input");
        assertEq(s.hookOut - s.outC.balanceOf(address(hyfi)), amountOut, "hook released gross output");
        // PoolManager balances net unchanged
        assertEq(s.inC.balanceOf(address(pm)), s.pmIn, "PM input balance unchanged");
        assertEq(s.outC.balanceOf(address(pm)), s.pmOut, "PM output balance unchanged");
        // the protocol fee lands in the token jar, on the unspecified currency only
        if (exactInput) {
            assertEq(s.outC.balanceOf(tokenJar) - s.jarOut, fee, "jar received output-side fee");
            assertEq(s.inC.balanceOf(tokenJar), s.jarIn, "jar input side untouched");
        } else {
            assertEq(s.inC.balanceOf(tokenJar) - s.jarIn, fee, "jar received input-side fee");
            assertEq(s.outC.balanceOf(tokenJar), s.jarOut, "jar output side untouched");
        }
        // traded side: only the pointer moved
        _assertSideMoved(p.id, s.tradedBid, s.tradedSide, expCur, expLeft);
        // other side fully unchanged
        _assertSideEq(p.id, !s.tradedBid, s.otherSide);
        // config unchanged
        _assertConfigUnchanged(p);
    }

    /// @dev The protocol fee on an exact-input swap: PROTOCOL_FEE_PIPS of the gross output, rounded up.
    function _uniFeeExactIn(uint grossOut) internal view returns (uint) {
        return FullMath.mulDivRoundingUp(grossOut, PROTOCOL_FEE_PIPS, 1_000_000);
    }

    /// @dev The protocol fee on an exact-output swap: charged on top of the gross input so it is
    /// PROTOCOL_FEE_PIPS of the total the trader pays, rounded up.
    function _uniFeeExactOut(uint grossIn) internal view returns (uint) {
        return FullMath.mulDivRoundingUp(grossIn, PROTOCOL_FEE_PIPS, 1_000_000 - PROTOCOL_FEE_PIPS);
    }

    function _assertSideMoved(PoolId id, bool bidSide, SideSnap memory b, uint8 expCur, uint96 expLeft) internal view {
        SideSnap memory a = _snapSide(id, bidSide);
        assertEq(a.cur, expCur, "traded curTick");
        assertEq(a.left, expLeft, "traded amountLeft");
        assertEq(a.tip, b.tip, "traded tip unchanged");
        assertEq(a.ts, b.ts, "traded timestamp unchanged");
        assertEq(a.bookId, b.bookId, "traded bookId unchanged");
        assertEq(a.end, b.end, "traded endTick unchanged");
        for (uint i; i < 68; ++i) {
            assertEq(a.ticks[i], b.ticks[i], "traded tick value unchanged");
        }
    }

    function _assertSideEq(PoolId id, bool bidSide, SideSnap memory b) internal view {
        SideSnap memory a = _snapSide(id, bidSide);
        assertEq(a.tip, b.tip, "side tip unchanged");
        assertEq(a.ts, b.ts, "side timestamp unchanged");
        assertEq(a.bookId, b.bookId, "side bookId unchanged");
        assertEq(a.cur, b.cur, "side curTick unchanged");
        assertEq(a.end, b.end, "side endTick unchanged");
        assertEq(a.left, b.left, "side amountLeft unchanged");
        for (uint i; i < 68; ++i) {
            assertEq(a.ticks[i], b.ticks[i], "side tick value unchanged");
        }
    }

    function _assertConfigUnchanged(Pair memory p) internal view {
        (uint128 tw, uint88 blu, uint24 fps, bool b0) = hyfi.pairConfig(p.id);
        assertEq(tw, p.tickWidth, "config tickWidth unchanged");
        assertEq(blu, p.baseLiqUnit, "config baseLiqUnit unchanged");
        assertEq(fps, p.feePerSecond, "config feePerSecond unchanged");
        assertEq(b0, p.baseIsCurrency0, "config baseIsCurrency0 unchanged");
    }
}
