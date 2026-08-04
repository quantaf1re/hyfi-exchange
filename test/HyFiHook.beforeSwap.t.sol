// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

/// @dev The Uniswap v4 swap path: swaps route through the Universal Router into the inherited
/// BaseAggregatorHook.beforeSwap, which calls HyFi._conductSwap. Liquidity is settled with real
/// tokens (the hook takes the input from the PoolManager and pays the output from its own
/// balance), so the PoolManager nets flat. The book trade (gross amountIn/amountOut and the
/// pointer walk) is identical to the direct path, but the Uniswap protocol fee (0.1%, live from
/// block ~27,000,000) is skimmed to the token jar on the unspecified side: the trader receives
/// `amountOut - fee` on exact-in and pays `amountIn + fee` on exact-out. See `_assertTradeViaUni`.
/// Slippage bounds are left loose (0 / max) since the exact net amounts are checked in the
/// assertion; the HyFi.Trade event still carries the gross book amounts (protocol fee is applied
/// by the aggregator base afterward, in its own HookSwap event).
/// NVDA/USDG: base is currency1 (18 dec base, 6 dec quote)
/// TOKA/TOKB: base is currency0 (6 dec base, 18 dec quote)
/// ETH/USDG:  base is native currency0
/// The Trade event's `sender` on this path is the PoolManager (msg.sender inside beforeSwap).
contract HyFiHookBeforeSwapTest is HyFiSetup {
    uint128 internal constant NO_MIN = 0;
    uint128 internal constant NO_MAX = type(uint128).max;

    // ------------------------------------------------------------------
    // NVDA/USDG (bid tip $180.00, ask tip $180.01, ticks [2, 3, 1] x 0.1 NVDA)
    // ------------------------------------------------------------------

    function test_beforeSwap_exactIn_sellBase_walksMultipleTicks() public {
        TradeSnap memory s = _snapTrade(nvdaPair, true);

        // 0.35 NVDA: 0.2 @ $180.00 = 36 USDG, 0.15 @ $179.99 = 26.9985 USDG => 62.9985 USDG
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.Trade(nvdaPair.id, address(pm), _bookId(nvdaPair.id), true, true, 0.35e18, 62_998_500, 0);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.35e18, NO_MIN);

        // pointer advanced into tick 1 with 0.15 of 0.3 NVDA consumed
        _assertTradeViaUni(nvdaPair, s, 0.35e18, 62_998_500, true, 1, 1.5e17);
    }

    function test_beforeSwap_exactIn_buyBase_walksAskSide() public {
        // 100 USDG: tick0 0.2 NVDA @ $180.01 = 36.002, tick1 0.3 @ $180.02 = 54.006,
        // remaining 9.992 buys 0.055501860800977614 NVDA into tick 2 @ $180.03
        uint expectedOut = 0.5e18 + 0.055501860800977614e18;

        TradeSnap memory s = _snapTrade(nvdaPair, false);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, false, 100e6, NO_MIN);
        _assertTradeViaUni(nvdaPair, s, 100e6, expectedOut, true, 2, 1e17 - 0.055501860800977614e18);
    }

    function test_beforeSwap_exactOut_buyBase() public {
        // 0.25 NVDA out: 0.2 @ $180.01 = 36.002 USDG + 0.05 @ $180.02 = 9.001 USDG => 45.003 USDG
        TradeSnap memory s = _snapTrade(nvdaPair, false);
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.Trade(nvdaPair.id, address(pm), _bookId(nvdaPair.id), false, false, 45.003e6, 0.25e18, 0);
        swapExactOutAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, false, 0.25e18, NO_MAX);
        _assertTradeViaUni(nvdaPair, s, 45_003_000, 0.25e18, false, 1, 2.5e17);
    }

    function test_beforeSwap_exactOut_sellBase() public {
        // exactly 50 USDG out: tick0 capacity 36 USDG, remaining 14 USDG from tick1 @ $179.99
        // costs 0.077782099005500306 NVDA (base charged rounds up)
        uint expectedIn = 2e17 + 0.077782099005500306e18;

        TradeSnap memory s = _snapTrade(nvdaPair, true);
        swapExactOutAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 50e6, NO_MAX);
        _assertTradeViaUni(nvdaPair, s, expectedIn, 50e6, false, 1, 3e17 - 0.077782099005500306e18);
    }

    function test_beforeSwap_secondSwapContinuesWhereFirstLeftOff() public {
        // first swap consumes exactly tick 0 (0.2 NVDA @ $180.00 = 36 USDG)
        TradeSnap memory s1 = _snapTrade(nvdaPair, true);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.2e18, NO_MIN);
        _assertTradeViaUni(nvdaPair, s1, 0.2e18, 36_000_000, true, 1, 0);

        // second swap in the same block continues at tick 1 @ $179.99 - liquidity is NOT reused
        TradeSnap memory s2 = _snapTrade(nvdaPair, true);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.1e18, NO_MIN);
        _assertTradeViaUni(nvdaPair, s2, 0.1e18, 17_999_000, true, 1, 2e17);
    }

    function test_beforeSwap_skipsEmptyTicks() public {
        uint8[] memory gappy = ticksArr(2, 0, 3);
        _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, gappy, gappy, uint32(block.timestamp));

        // 0.3 NVDA: 0.2 @ $180.00 = 36, tick1 empty (skipped), 0.1 @ $179.98 = 17.998
        TradeSnap memory s = _snapTrade(nvdaPair, true);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.3e18, NO_MIN);
        _assertTradeViaUni(nvdaPair, s, 0.3e18, 36_000_000 + 17_998_000, true, 2, 2e17);
    }

    function test_beforeSwap_exactIn_buyBase_skipsEmptyTicks() public {
        uint8[] memory gappy = ticksArr(2, 0, 3);
        _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, gappy, gappy, uint32(block.timestamp));

        // 40 USDG: 36.002 buys all of tick 0, tick 1 empty, 3.998 buys 0.022207409876131755
        // NVDA into tick 2 @ $180.03
        uint expectedOut = 2e17 + 0.022207409876131755e18;

        TradeSnap memory s = _snapTrade(nvdaPair, false);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, false, 40e6, NO_MIN);
        _assertTradeViaUni(nvdaPair, s, 40e6, expectedOut, true, 2, 3e17 - 0.022207409876131755e18);
    }

    function test_beforeSwap_exactIn_sellBase_walksIntoWordAAndWordB() public {
        uint8[] memory deep = ticksFill(40, 1); // 40 ticks x 0.1 NVDA
        _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, deep, deep, uint32(block.timestamp));

        // 3.7 NVDA drains ticks 0..36 (through slot0 head, wordA, into wordB):
        // sum of (18000 - i) * 1000 for i in 0..36 = 665_334_000
        TradeSnap memory s = _snapTrade(nvdaPair, true);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 3.7e18, NO_MIN);
        _assertTradeViaUni(nvdaPair, s, 3.7e18, 665_334_000, true, 37, 0);
    }

    function test_beforeSwap_exactIn_buyBase_walksIntoWordAAndWordB() public {
        uint8[] memory deep = ticksFill(40, 1);
        _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, deep, deep, uint32(block.timestamp));

        // cost of ask ticks 0..36 = sum of (18001 + i) * 1000 for i in 0..36 = 666_703_000
        TradeSnap memory s = _snapTrade(nvdaPair, false);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, false, 666_703_000, NO_MIN);
        _assertTradeViaUni(nvdaPair, s, 666_703_000, 3.7e18, true, 37, 0);
    }

    function test_beforeSwap_exactIn_sellBase_resumesPartialTick() public {
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.35e18, NO_MIN); // leaves tick 1 partial

        // next 0.1 NVDA comes out of tick 1's remaining 0.15 @ $179.99 = 17.999 USDG
        TradeSnap memory s = _snapTrade(nvdaPair, true);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.1e18, NO_MIN);
        _assertTradeViaUni(nvdaPair, s, 0.1e18, 17_999_000, true, 1, 0.5e17);
    }

    function test_beforeSwap_exactIn_buyBase_resumesPartialTick() public {
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, false, 100e6, NO_MIN); // leaves tick 2 partial

        // next 5 USDG buys 0.027773148919624507 NVDA from tick 2's remainder @ $180.03;
        // tick 2 had 0.044498139199022386 NVDA left after the first swap
        uint expectedOut = 0.027773148919624507e18;
        TradeSnap memory s = _snapTrade(nvdaPair, false);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, false, 5e6, NO_MIN);
        _assertTradeViaUni(nvdaPair, s, 5e6, expectedOut, true, 2, 0.044498139199022386e18 - 0.027773148919624507e18);
    }

    function test_beforeSwap_exactOut_sellBase_roundingConsumesTickExactly() public {
        // TOK pair tick 0 capacity is exactly 1000 TOKB (2e7 TOKA @ $50.00). Asking for 1 wei
        // less rounds the charged base up to the full tick: amountLeft would be 0, so the
        // pointer must advance to keep "amountLeft == 0" meaning "untouched tick".
        uint wantOut = 1_000e18 - 1;
        TradeSnap memory s = _snapTrade(tokPair, true);
        swapExactOutAs(router, tokPair.key, tokPair.baseIsCurrency0, trader, true, uint128(wantOut), NO_MAX);
        _assertTradeViaUni(tokPair, s, 2e7, wantOut, false, 1, 0);
    }

    // ------------------------------------------------------------------
    // Staleness fee (100 pips/second on all fixture pairs)
    // ------------------------------------------------------------------

    function test_beforeSwap_exactIn_chargesStalenessFeeOnOutput() public {
        vm.warp(block.timestamp + 10); // 10s x 100 pips = 1000 pips = 0.1%

        // gross 0.2 NVDA @ $180.00 = 36 USDG, staleness fee = 0.036 USDG => 35.964 USDG book output;
        // the via-Uniswap protocol fee then applies on top of that book output
        TradeSnap memory s = _snapTrade(nvdaPair, true);
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.Trade(nvdaPair.id, address(pm), _bookId(nvdaPair.id), true, true, 0.2e18, 35.964e6, 36e3);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.2e18, NO_MIN);
        _assertTradeViaUni(nvdaPair, s, 0.2e18, 35_964_000, true, 1, 0);
    }

    function test_beforeSwap_exactOut_grossesUpWalkByFee() public {
        vm.warp(block.timestamp + 10); // 0.1% staleness fee

        uint wantOut = 20e6; // 20 USDG net of staleness
        // gross = ceil(20e6 * 1e6 / 999000) = 20.020021e6; walks bid tick0 @ $180.00,
        // costing 0.111222338888888889 NVDA (base charged rounds up)
        uint expectedIn = 0.111222338888888889e18;

        TradeSnap memory s = _snapTrade(nvdaPair, true);
        swapExactOutAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, uint128(wantOut), NO_MAX);
        _assertTradeViaUni(nvdaPair, s, expectedIn, wantOut, false, 0, 2e17 - 0.111222338888888889e18);
    }

    function test_beforeSwap_exactIn_feeCappedAt100Percent_outputsZero() public {
        vm.warp(block.timestamp + 100_000); // 100k s x 100 pips >> 100% -> capped

        // input still charged, zero output; tick 0 fully walked for the (entirely retained) gross.
        // Zero book output => zero protocol fee too.
        TradeSnap memory s = _snapTrade(nvdaPair, true);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.2e18, NO_MIN);
        _assertTradeViaUni(nvdaPair, s, 0.2e18, 0, true, 1, 0);
    }

    function test_beforeSwap_RevertWhen_exactOutBookTooStale() public {
        vm.warp(block.timestamp + 100_000); // fee capped at 100%: no gross output satisfies exact-out
        vm.expectRevert(hookRevert(address(hyfi), IHooks.beforeSwap.selector, HyFi.BookTooStale.selector));
        swapExactOutAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 1e6, NO_MAX);
    }

    // ------------------------------------------------------------------
    // TOKA(6 dec, currency0 base)/TOKB(18 dec) - inverse decimal gap + flipped ordering
    // ------------------------------------------------------------------

    function test_beforeSwap_exactIn_sellBase_tokPair() public {
        // 25 TOKA: 20 @ $50.00 = 1000 TOKB, 5 @ $49.99 = 249.95 TOKB => 1249.95 TOKB
        TradeSnap memory s = _snapTrade(tokPair, true);
        swapExactInAs(router, tokPair.key, tokPair.baseIsCurrency0, trader, true, 25e6, NO_MIN);
        _assertTradeViaUni(tokPair, s, 25e6, 1_249.95e18, true, 1, 25e6);
    }

    function test_beforeSwap_exactIn_buyBase_tokPair() public {
        // 2000 TOKB: tick0 20 TOKA @ $50.01 = 1000.2 TOKB, remaining 999.8 TOKB buys
        // 19.988004 TOKA @ $50.02 (rounded down) => 39.988004 TOKA into tick 1
        TradeSnap memory s = _snapTrade(tokPair, false);
        swapExactInAs(router, tokPair.key, tokPair.baseIsCurrency0, trader, false, 2_000e18, NO_MIN);
        _assertTradeViaUni(tokPair, s, 2_000e18, 39.988004e6, true, 1, 10.011996e6);
    }

    function test_beforeSwap_exactOut_buyBase_tokPair() public {
        // 30 TOKA out: 20 @ $50.01 = 1000.2 TOKB + 10 @ $50.02 = 500.2 TOKB => 1500.4 TOKB
        TradeSnap memory s = _snapTrade(tokPair, false);
        swapExactOutAs(router, tokPair.key, tokPair.baseIsCurrency0, trader, false, 30e6, NO_MAX);
        _assertTradeViaUni(tokPair, s, 1_500.4e18, 30e6, false, 1, 20e6);
    }

    function test_beforeSwap_exactOut_sellBase_tokPair() public {
        // exactly 1200 TOKB out: tick0 capacity 1000 TOKB @ $50.00, remaining 200 TOKB from
        // tick1 @ $49.99 costs 24.000801 - 20 = 4.000801 TOKA (base charged rounds up)
        TradeSnap memory s = _snapTrade(tokPair, true);
        swapExactOutAs(router, tokPair.key, tokPair.baseIsCurrency0, trader, true, 1_200e18, NO_MAX);
        _assertTradeViaUni(tokPair, s, 24.000801e6, 1_200e18, false, 1, 25.999199e6);
    }

    // ------------------------------------------------------------------
    // Native ETH/USDG (base is the native currency0)
    // ------------------------------------------------------------------

    function test_beforeSwap_exactIn_sellNativeBase() public {
        // 0.2 ETH @ $3000.00 = 600 USDG (exactly tick 0)
        TradeSnap memory s = _snapTrade(ethPair, true);
        swapExactInAs(router, ethPair.key, ethPair.baseIsCurrency0, trader, true, 0.2e18, NO_MIN);
        _assertTradeViaUni(ethPair, s, 0.2e18, 600e6, true, 1, 0);
    }

    function test_beforeSwap_exactIn_buyNativeBase() public {
        // 300 USDG buys 0.099999666667777774 ETH into tick 0 (tick 0 costs 600.002 USDG in full)
        uint expectedOut = 0.099999666667777774e18;
        TradeSnap memory s = _snapTrade(ethPair, false);
        swapExactInAs(router, ethPair.key, ethPair.baseIsCurrency0, trader, false, 300e6, NO_MIN);
        _assertTradeViaUni(ethPair, s, 300e6, expectedOut, true, 0, 2e17 - 0.099999666667777774e18);
    }

    function test_beforeSwap_exactOut_buyNativeBase() public {
        // 0.25 ETH out: 0.2 @ $3000.01 = 600.002 USDG + 0.05 @ $3000.02 = 150.001 USDG => 750.003
        TradeSnap memory s = _snapTrade(ethPair, false);
        swapExactOutAs(router, ethPair.key, ethPair.baseIsCurrency0, trader, false, 0.25e18, NO_MAX);
        _assertTradeViaUni(ethPair, s, 750.003e6, 0.25e18, false, 1, 2.5e17);
    }

    function test_beforeSwap_exactOut_sellNativeBase() public {
        // exactly 500 USDG out: tick0 capacity 600 USDG @ $3000.00; 500 USDG costs
        // 0.166666666666666667 ETH (base charged rounds up), staying in tick 0
        TradeSnap memory s = _snapTrade(ethPair, true);
        // native input: the router is over-funded with `value` and sweeps the excess, so the bound
        // must be an affordable ETH amount (not type(uint128).max) that covers input + protocol fee
        swapExactOutAs(router, ethPair.key, ethPair.baseIsCurrency0, trader, true, 500e6, 0.2e18);
        _assertTradeViaUni(ethPair, s, 0.166666666666666667e18, 500e6, false, 0, 2e17 - 0.166666666666666667e18);
    }

    // ------------------------------------------------------------------
    // Reverts / access
    // ------------------------------------------------------------------

    function test_beforeSwap_RevertWhen_insufficientLiquidity() public {
        // book has 0.6 NVDA total on the bid side
        vm.expectRevert(hookRevert(address(hyfi), IHooks.beforeSwap.selector, HyFi.InsufficientLiquidity.selector));
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.7e18, NO_MIN);
    }

    function test_beforeSwap_RevertWhen_insufficientLiquidity_buyingBase() public {
        // the whole ask book costs ~108.011 USDG; 200 USDG exhausts it mid-walk
        vm.expectRevert(hookRevert(address(hyfi), IHooks.beforeSwap.selector, HyFi.InsufficientLiquidity.selector));
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, false, 200e6, NO_MIN);
    }

    function test_beforeSwap_RevertWhen_callerNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
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
