// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @dev All swaps go through the Universal Router, exactly like a regular user.
/// NVDA/USDG: base is currency1 (18 dec base, 6 dec quote)
/// TOKA/TOKB: base is currency0 (6 dec base, 18 dec quote)
/// ETH/USDG:  base is native currency0
contract HyFiHookBeforeSwapTest is HyFiSetup {
    // ------------------------------------------------------------------
    // NVDA/USDG (bid tip $180.00, ask tip $180.01, ticks [2, 3, 1] x 0.1 NVDA)
    // ------------------------------------------------------------------

    // ------------------------------------------------------------------
    // Comprehensive trade-invariant assertions
    // ------------------------------------------------------------------

    struct SideSnap {
        uint40 tip;
        uint32 ts;
        uint40 bookId;
        uint8 cur;
        uint8 end;
        uint96 left;
        uint8[68] ticks;
    }

    struct TradeSnap {
        Currency inC;
        Currency outC;
        bool tradedBid; // selling base hits the bid side
        uint traderIn;
        uint traderOut;
        uint pmIn;
        uint pmOut;
        uint hookInClaims;
        uint hookOutClaims;
        SideSnap tradedSide;
        SideSnap otherSide;
    }

    function _snapSide(PoolId id, bool bidSide) internal view returns (SideSnap memory s) {
        (s.tip, s.ts, s.bookId, s.cur, s.end, s.left, s.ticks) = hyfi.getBookSide(id, bidSide);
    }

    /// @dev Snapshots everything a trade on `p` can touch: input/output token balances of the
    /// trader and PoolManager, the hook's 6909 claims, and both sides of the book.
    function _snapTrade(Pair memory p, bool sellingBase) internal view returns (TradeSnap memory s) {
        s.tradedBid = sellingBase;
        bool zeroForOne = sellingBase == p.baseIsCurrency0;
        (s.inC, s.outC) = zeroForOne ? (p.key.currency0, p.key.currency1) : (p.key.currency1, p.key.currency0);
        s.traderIn = s.inC.balanceOf(trader);
        s.traderOut = s.outC.balanceOf(trader);
        s.pmIn = s.inC.balanceOf(address(pm));
        s.pmOut = s.outC.balanceOf(address(pm));
        s.hookInClaims = claims(pm, address(hyfi), s.inC);
        s.hookOutClaims = claims(pm, address(hyfi), s.outC);
        s.tradedSide = _snapSide(p.id, sellingBase);
        s.otherSide = _snapSide(p.id, !sellingBase);
    }

    /// @dev Full post-trade invariants against a `_snapTrade` snapshot: trader/PM token flows,
    /// 6909 claim deltas (input minted, net output burned - the fee stays as hook output claims),
    /// the hook custodies no raw tokens, the traded side's pointer moved to (expCur, expLeft) with
    /// everything else unchanged, the other side is untouched, and the config is unchanged.
    function _assertTrade(Pair memory p, TradeSnap memory s, uint amountIn, uint amountOut, uint8 expCur, uint96 expLeft)
        internal
        view
    {
        // trader token flow
        assertEq(s.traderIn - s.inC.balanceOf(trader), amountIn, "trader paid amountIn");
        assertEq(s.outC.balanceOf(trader) - s.traderOut, amountOut, "trader received amountOut");
        // PoolManager custodies every real token
        assertEq(s.inC.balanceOf(address(pm)) - s.pmIn, amountIn, "PM gained input tokens");
        assertEq(s.pmOut - s.outC.balanceOf(address(pm)), amountOut, "PM released output tokens");
        // hook 6909 claims: input minted, net output burned
        assertEq(claims(pm, address(hyfi), s.inC) - s.hookInClaims, amountIn, "hook input claims minted");
        assertEq(s.hookOutClaims - claims(pm, address(hyfi), s.outC), amountOut, "hook output claims burned");
        // hook never holds raw tokens
        assertEq(address(hyfi).balance, 0, "hook holds no ETH");
        assertEq(usdg.balanceOf(address(hyfi)), 0, "hook holds no USDG");
        assertEq(nvda.balanceOf(address(hyfi)), 0, "hook holds no NVDA");
        assertEq(toka.balanceOf(address(hyfi)), 0, "hook holds no TOKA");
        assertEq(tokb.balanceOf(address(hyfi)), 0, "hook holds no TOKB");
        // traded side: only the pointer moved
        _assertSideMoved(p.id, s.tradedBid, s.tradedSide, expCur, expLeft);
        // other side fully unchanged
        _assertSideEq(p.id, !s.tradedBid, s.otherSide);
        // config unchanged
        _assertConfigUnchanged(p);
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

    function test_beforeSwap_exactIn_sellBase_walksMultipleTicks() public {
        TradeSnap memory s = _snapTrade(nvdaPair, true);

        // 0.35 NVDA: 0.2 @ $180.00 = 36 USDG, 0.15 @ $179.99 = 26.9985 USDG => 62.9985 USDG
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.Trade(nvdaPair.id, address(router), _bookId(nvdaPair.id), true, true, 0.35e18, 62_998_500, 0);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.35e18, 62_998_500);

        // pointer advanced into tick 1 with 0.15 of 0.3 NVDA consumed
        _assertTrade(nvdaPair, s, 0.35e18, 62_998_500, 1, 1.5e17);
    }

    function test_beforeSwap_exactIn_buyBase_walksAskSide() public {
        // 100 USDG: tick0 0.2 NVDA @ $180.01 = 36.002, tick1 0.3 @ $180.02 = 54.006,
        // remaining 9.992 buys 0.055501860800977614 NVDA into tick 2 @ $180.03
        uint expectedOut = 0.5e18 + 0.055501860800977614e18;

        TradeSnap memory s = _snapTrade(nvdaPair, false);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, false, 100e6, uint128(expectedOut));
        _assertTrade(nvdaPair, s, 100e6, expectedOut, 2, 1e17 - 0.055501860800977614e18);
    }

    function test_beforeSwap_exactOut_buyBase() public {
        // 0.25 NVDA out: 0.2 @ $180.01 = 36.002 USDG + 0.05 @ $180.02 = 9.001 USDG => 45.003 USDG
        TradeSnap memory s = _snapTrade(nvdaPair, false);
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.Trade(nvdaPair.id, address(router), _bookId(nvdaPair.id), false, false, 45.003e6, 0.25e18, 0);
        swapExactOutAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, false, 0.25e18, 45.003e6);
        _assertTrade(nvdaPair, s, 45_003_000, 0.25e18, 1, 2.5e17);
    }

    function test_beforeSwap_exactOut_sellBase() public {
        // exactly 50 USDG out: tick0 capacity 36 USDG, remaining 14 USDG from tick1 @ $179.99
        // costs 0.077782099005500306 NVDA (base charged rounds up)
        uint expectedIn = 2e17 + 0.077782099005500306e18;

        TradeSnap memory s = _snapTrade(nvdaPair, true);
        swapExactOutAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 50e6, uint128(expectedIn));
        _assertTrade(nvdaPair, s, expectedIn, 50e6, 1, 3e17 - 0.077782099005500306e18);
    }

    function test_beforeSwap_secondSwapContinuesWhereFirstLeftOff() public {
        // first swap consumes exactly tick 0 (0.2 NVDA @ $180.00 = 36 USDG)
        TradeSnap memory s1 = _snapTrade(nvdaPair, true);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.2e18, 36_000_000);
        _assertTrade(nvdaPair, s1, 0.2e18, 36_000_000, 1, 0);

        // second swap in the same block continues at tick 1 @ $179.99 - liquidity is NOT reused
        TradeSnap memory s2 = _snapTrade(nvdaPair, true);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.1e18, 0);
        _assertTrade(nvdaPair, s2, 0.1e18, 17_999_000, 1, 2e17);
    }

    function test_beforeSwap_skipsEmptyTicks() public {
        uint8[] memory gappy = ticksArr(2, 0, 3);
        _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, gappy, gappy, uint32(block.timestamp));

        // 0.3 NVDA: 0.2 @ $180.00 = 36, tick1 empty (skipped), 0.1 @ $179.98 = 17.998
        TradeSnap memory s = _snapTrade(nvdaPair, true);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.3e18, 0);
        _assertTrade(nvdaPair, s, 0.3e18, 36_000_000 + 17_998_000, 2, 2e17);
    }

    function test_beforeSwap_exactIn_buyBase_skipsEmptyTicks() public {
        uint8[] memory gappy = ticksArr(2, 0, 3);
        _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, gappy, gappy, uint32(block.timestamp));

        // 40 USDG: 36.002 buys all of tick 0, tick 1 empty, 3.998 buys 0.022207409876131755
        // NVDA into tick 2 @ $180.03
        uint expectedOut = 2e17 + 0.022207409876131755e18;

        TradeSnap memory s = _snapTrade(nvdaPair, false);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, false, 40e6, uint128(expectedOut));
        _assertTrade(nvdaPair, s, 40e6, expectedOut, 2, 3e17 - 0.022207409876131755e18);
    }

    function test_beforeSwap_exactIn_sellBase_walksIntoWordAAndWordB() public {
        uint8[] memory deep = ticksFill(40, 1); // 40 ticks x 0.1 NVDA
        _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, deep, deep, uint32(block.timestamp));

        // 3.7 NVDA drains ticks 0..36 (through slot0 head, wordA, into wordB):
        // sum of (18000 - i) * 1000 for i in 0..36 = 665_334_000
        TradeSnap memory s = _snapTrade(nvdaPair, true);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 3.7e18, 665_334_000);
        _assertTrade(nvdaPair, s, 3.7e18, 665_334_000, 37, 0);
    }

    function test_beforeSwap_exactIn_buyBase_walksIntoWordAAndWordB() public {
        uint8[] memory deep = ticksFill(40, 1);
        _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, deep, deep, uint32(block.timestamp));

        // cost of ask ticks 0..36 = sum of (18001 + i) * 1000 for i in 0..36 = 666_703_000
        TradeSnap memory s = _snapTrade(nvdaPair, false);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, false, 666_703_000, 3.7e18);
        _assertTrade(nvdaPair, s, 666_703_000, 3.7e18, 37, 0);
    }

    function test_beforeSwap_exactIn_sellBase_resumesPartialTick() public {
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.35e18, 0); // leaves tick 1 partial

        // next 0.1 NVDA comes out of tick 1's remaining 0.15 @ $179.99 = 17.999 USDG
        TradeSnap memory s = _snapTrade(nvdaPair, true);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.1e18, 0);
        _assertTrade(nvdaPair, s, 0.1e18, 17_999_000, 1, 0.5e17);
    }

    function test_beforeSwap_exactIn_buyBase_resumesPartialTick() public {
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, false, 100e6, 0); // leaves tick 2 partial

        // next 5 USDG buys 0.027773148919624507 NVDA from tick 2's remainder @ $180.03;
        // tick 2 had 0.044498139199022386 NVDA left after the first swap
        uint expectedOut = 0.027773148919624507e18;
        TradeSnap memory s = _snapTrade(nvdaPair, false);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, false, 5e6, uint128(expectedOut));
        _assertTrade(nvdaPair, s, 5e6, expectedOut, 2, 0.044498139199022386e18 - 0.027773148919624507e18);
    }

    function test_beforeSwap_exactOut_sellBase_roundingConsumesTickExactly() public {
        // TOK pair tick 0 capacity is exactly 1000 TOKB (2e7 TOKA @ $50.00). Asking for 1 wei
        // less rounds the charged base up to the full tick: amountLeft would be 0, so the
        // pointer must advance to keep "amountLeft == 0" meaning "untouched tick".
        uint wantOut = 1_000e18 - 1;
        TradeSnap memory s = _snapTrade(tokPair, true);
        swapExactOutAs(router, tokPair.key, tokPair.baseIsCurrency0, trader, true, uint128(wantOut), 2e7);
        _assertTrade(tokPair, s, 2e7, wantOut, 1, 0);
    }

    // ------------------------------------------------------------------
    // Staleness fee (100 pips/second on all fixture pairs)
    // ------------------------------------------------------------------

    function test_beforeSwap_exactIn_chargesStalenessFeeOnOutput() public {
        vm.warp(block.timestamp + 10); // 10s x 100 pips = 1000 pips = 0.1%

        // gross 0.2 NVDA @ $180.00 = 36 USDG, fee = 36 * 0.1% = 0.036 USDG, net = 35.964 USDG
        TradeSnap memory s = _snapTrade(nvdaPair, true);
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.Trade(nvdaPair.id, address(router), _bookId(nvdaPair.id), true, true, 0.2e18, 35.964e6, 36e3);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.2e18, 35.964e6);
        // full tick 0 walked for the gross output; only the net is paid, the fee stays as hook claims
        _assertTrade(nvdaPair, s, 0.2e18, 35_964_000, 1, 0);
    }

    function test_beforeSwap_exactOut_grossesUpWalkByFee() public {
        vm.warp(block.timestamp + 10); // 0.1% fee

        uint wantOut = 20e6; // 20 USDG net
        // gross = ceil(20e6 * 1e6 / 999000) = 20.020021e6; walks bid tick0 @ $180.00,
        // costing 0.111222338888888889 NVDA (base charged rounds up)
        uint expectedIn = 0.111222338888888889e18;

        TradeSnap memory s = _snapTrade(nvdaPair, true);
        swapExactOutAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, uint128(wantOut), uint128(expectedIn));
        _assertTrade(nvdaPair, s, expectedIn, wantOut, 0, 2e17 - 0.111222338888888889e18);
    }

    function test_beforeSwap_exactIn_feeCappedAt100Percent_outputsZero() public {
        vm.warp(block.timestamp + 100_000); // 100k s x 100 pips >> 100% -> capped

        // input still charged, zero output; tick 0 fully walked for the (entirely retained) gross
        TradeSnap memory s = _snapTrade(nvdaPair, true);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.2e18, 0);
        _assertTrade(nvdaPair, s, 0.2e18, 0, 1, 0);
    }

    function test_beforeSwap_RevertWhen_exactOutBookTooStale() public {
        vm.warp(block.timestamp + 100_000); // fee capped at 100%: no gross output satisfies exact-out
        vm.expectRevert(hookRevert(address(hyfi), IHooks.beforeSwap.selector, HyFi.BookTooStale.selector));
        swapExactOutAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 1e6, type(uint128).max);
    }

    // ------------------------------------------------------------------
    // TOKA(6 dec, currency0 base)/TOKB(18 dec) - inverse decimal gap + flipped ordering
    // ------------------------------------------------------------------

    function test_beforeSwap_exactIn_sellBase_tokPair() public {
        // 25 TOKA: 20 @ $50.00 = 1000 TOKB, 5 @ $49.99 = 249.95 TOKB => 1249.95 TOKB
        TradeSnap memory s = _snapTrade(tokPair, true);
        swapExactInAs(router, tokPair.key, tokPair.baseIsCurrency0, trader, true, 25e6, 1_249.95e18);
        _assertTrade(tokPair, s, 25e6, 1_249.95e18, 1, 25e6);
    }

    function test_beforeSwap_exactIn_buyBase_tokPair() public {
        // 2000 TOKB: tick0 20 TOKA @ $50.01 = 1000.2 TOKB, remaining 999.8 TOKB buys
        // 19.988004 TOKA @ $50.02 (rounded down) => 39.988004 TOKA into tick 1
        TradeSnap memory s = _snapTrade(tokPair, false);
        swapExactInAs(router, tokPair.key, tokPair.baseIsCurrency0, trader, false, 2_000e18, 39.988004e6);
        _assertTrade(tokPair, s, 2_000e18, 39.988004e6, 1, 10.011996e6);
    }

    function test_beforeSwap_exactOut_buyBase_tokPair() public {
        // 30 TOKA out: 20 @ $50.01 = 1000.2 TOKB + 10 @ $50.02 = 500.2 TOKB => 1500.4 TOKB
        TradeSnap memory s = _snapTrade(tokPair, false);
        swapExactOutAs(router, tokPair.key, tokPair.baseIsCurrency0, trader, false, 30e6, 1_500.4e18);
        _assertTrade(tokPair, s, 1_500.4e18, 30e6, 1, 20e6);
    }

    function test_beforeSwap_exactOut_sellBase_tokPair() public {
        // exactly 1200 TOKB out: tick0 capacity 1000 TOKB @ $50.00, remaining 200 TOKB from
        // tick1 @ $49.99 costs 24.000801 - 20 = 4.000801 TOKA (base charged rounds up)
        TradeSnap memory s = _snapTrade(tokPair, true);
        swapExactOutAs(router, tokPair.key, tokPair.baseIsCurrency0, trader, true, 1_200e18, 24.000801e6);
        _assertTrade(tokPair, s, 24.000801e6, 1_200e18, 1, 25.999199e6);
    }

    // ------------------------------------------------------------------
    // Native ETH/USDG (base is the native currency0)
    // ------------------------------------------------------------------

    function test_beforeSwap_exactIn_sellNativeBase() public {
        // 0.2 ETH @ $3000.00 = 600 USDG (exactly tick 0)
        TradeSnap memory s = _snapTrade(ethPair, true);
        swapExactInAs(router, ethPair.key, ethPair.baseIsCurrency0, trader, true, 0.2e18, 600e6);
        _assertTrade(ethPair, s, 0.2e18, 600e6, 1, 0);
    }

    function test_beforeSwap_exactIn_buyNativeBase() public {
        // 300 USDG buys 0.099999666667777774 ETH into tick 0 (the total base in tick 0 costs 600.002 USDG in full)
        uint expectedOut = 0.099999666667777774e18;
        TradeSnap memory s = _snapTrade(ethPair, false);
        swapExactInAs(router, ethPair.key, ethPair.baseIsCurrency0, trader, false, 300e6, uint128(expectedOut));
        _assertTrade(ethPair, s, 300e6, expectedOut, 0, 2e17 - 0.099999666667777774e18);
    }

    function test_beforeSwap_exactOut_buyNativeBase() public {
        // 0.25 ETH out: 0.2 @ $3000.01 = 600.002 USDG + 0.05 @ $3000.02 = 150.001 USDG => 750.003
        TradeSnap memory s = _snapTrade(ethPair, false);
        swapExactOutAs(router, ethPair.key, ethPair.baseIsCurrency0, trader, false, 0.25e18, 750.003e6);
        _assertTrade(ethPair, s, 750.003e6, 0.25e18, 1, 2.5e17);
    }

    function test_beforeSwap_exactOut_sellNativeBase() public {
        // exactly 500 USDG out: tick0 capacity 600 USDG @ $3000.00; 500 USDG costs
        // 0.166666666666666667 ETH (base charged rounds up), staying in tick 0
        TradeSnap memory s = _snapTrade(ethPair, true);
        swapExactOutAs(router, ethPair.key, ethPair.baseIsCurrency0, trader, true, 500e6, 0.166666666666666667e18);
        _assertTrade(ethPair, s, 0.166666666666666667e18, 500e6, 0, 2e17 - 0.166666666666666667e18);
    }

    // ------------------------------------------------------------------
    // Reverts / access
    // ------------------------------------------------------------------

    function test_beforeSwap_RevertWhen_insufficientLiquidity() public {
        // book has 0.6 NVDA total on the bid side
        vm.expectRevert(hookRevert(address(hyfi), IHooks.beforeSwap.selector, HyFi.InsufficientLiquidity.selector));
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.7e18, 0);
    }

    function test_beforeSwap_RevertWhen_insufficientLiquidity_buyingBase() public {
        // the whole ask book costs ~108.011 USDG; 200 USDG exhausts it mid-walk
        vm.expectRevert(hookRevert(address(hyfi), IHooks.beforeSwap.selector, HyFi.InsufficientLiquidity.selector));
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, false, 200e6, 0);
    }

    function test_beforeSwap_RevertWhen_callerNotPoolManager() public {
        vm.expectRevert(HyFi.NotPoolManager.selector);
        hyfi.beforeSwap(trader, nvdaPair.key, SwapParams(true, -1e18, 0), "");
    }

    function test_beforeSwap_RevertWhen_pairNotConfigured() public {
        PoolKey memory key = nvdaPair.key;
        key.tickSpacing = nvdaPair.key.tickSpacing + 60; // different poolId, never configured
        vm.prank(address(pm));
        vm.expectRevert(HyFi.PairNotConfigured.selector);
        hyfi.beforeSwap(trader, key, SwapParams(true, -1e18, 0), "");
    }
}
