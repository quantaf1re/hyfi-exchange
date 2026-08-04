// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestToken} from "./mocks/TestToken.sol";

/// @dev The direct exact-output swap path: `swapExactOutDirect` sends exactly `amountOut` of the output
/// token to `recipient`, pulling the required input from the caller (with native excess refunded).
/// No PoolManager, no Uniswap protocol fee. Pricing matches the Uniswap path.
contract HyFiHookSwapExactOutTest is HyFiSetup {
    function _tokens(Pair memory p, bool sellingBase) internal pure returns (address tIn, address tOut) {
        (tIn, tOut) = sellingBase
            ? (Currency.unwrap(p.base), Currency.unwrap(p.quote))
            : (Currency.unwrap(p.quote), Currency.unwrap(p.base));
    }

    // ------------------------------------------------------------------
    // NVDA/USDG
    // ------------------------------------------------------------------

    function test_swapExactOut_buyBase() public {
        (address tIn, address tOut) = _tokens(nvdaPair, false);
        TradeSnap memory s = _snapTrade(nvdaPair, false);
        vm.startPrank(trader);
        IERC20(tIn).approve(address(hyfi), 45.003e6);
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.Trade(nvdaPair.id, trader, _bookId(nvdaPair.id), false, false, 45.003e6, 0.25e18, 0);
        (uint amountIn, uint amountOut) = hyfi.swapExactOutDirect(tIn, tOut, 0.25e18, trader);
        vm.stopPrank();

        assertEq(amountIn, 45_003_000, "returned amountIn");
        assertEq(amountOut, 0.25e18, "returned amountOut");
        _assertTrade(nvdaPair, s, 45_003_000, 0.25e18, 1, 2.5e17);
    }

    function test_swapExactOut_sellBase() public {
        (address tIn, address tOut) = _tokens(nvdaPair, true);
        uint expectedIn = 2e17 + 0.077782099005500306e18;
        TradeSnap memory s = _snapTrade(nvdaPair, true);
        swapExactOutDirectAs(hyfi, trader, tIn, tOut, 50e6, trader, expectedIn);
        _assertTrade(nvdaPair, s, expectedIn, 50e6, 1, 3e17 - 0.077782099005500306e18);
    }

    // ------------------------------------------------------------------
    // TOKA(6 dec base)/TOKB(18 dec)
    // ------------------------------------------------------------------

    function test_swapExactOut_buyBase_tokPair() public {
        (address tIn, address tOut) = _tokens(tokPair, false);
        TradeSnap memory s = _snapTrade(tokPair, false);
        swapExactOutDirectAs(hyfi, trader, tIn, tOut, 30e6, trader, 1_500.4e18);
        _assertTrade(tokPair, s, 1_500.4e18, 30e6, 1, 20e6);
    }

    function test_swapExactOut_sellBase_tokPair() public {
        (address tIn, address tOut) = _tokens(tokPair, true);
        TradeSnap memory s = _snapTrade(tokPair, true);
        swapExactOutDirectAs(hyfi, trader, tIn, tOut, 1_200e18, trader, 24.000801e6);
        _assertTrade(tokPair, s, 24.000801e6, 1_200e18, 1, 25.999199e6);
    }

    function test_swapExactOut_roundingConsumesTickExactly() public {
        (address tIn, address tOut) = _tokens(tokPair, true);
        uint wantOut = 1_000e18 - 1;
        TradeSnap memory s = _snapTrade(tokPair, true);
        swapExactOutDirectAs(hyfi, trader, tIn, tOut, wantOut, trader, 2e7);
        _assertTrade(tokPair, s, 2e7, wantOut, 1, 0);
    }

    // ------------------------------------------------------------------
    // Native ETH/USDG
    // ------------------------------------------------------------------

    function test_swapExactOut_buyNativeBase() public {
        // buying native base with USDG: tokenIn = USDG, tokenOut = native
        (address tIn, address tOut) = _tokens(ethPair, false);
        TradeSnap memory s = _snapTrade(ethPair, false);
        swapExactOutDirectAs(hyfi, trader, tIn, tOut, 0.25e18, trader, 750.003e6);
        _assertTrade(ethPair, s, 750.003e6, 0.25e18, 1, 2.5e17);
    }

    function test_swapExactOut_sellNativeBase_refundsExcess() public {
        // selling native base for USDG: over-fund with 1 ETH, only 0.166... ETH is spent
        (address tIn, address tOut) = _tokens(ethPair, true);
        uint expectedIn = 0.166666666666666667e18;
        TradeSnap memory s = _snapTrade(ethPair, true);
        swapExactOutDirectAs(hyfi, trader, tIn, tOut, 500e6, trader, 1 ether);
        // net native spent == expectedIn (the 1 ETH overfund minus refund)
        _assertTrade(ethPair, s, expectedIn, 500e6, 0, uint96(2e17 - expectedIn));
    }

    // ------------------------------------------------------------------
    // Staleness fee
    // ------------------------------------------------------------------

    function test_swapExactOut_grossesUpWalkByFee() public {
        vm.warp(block.timestamp + 10); // 0.1%
        (address tIn, address tOut) = _tokens(nvdaPair, true);
        uint expectedIn = 0.111222338888888889e18;
        TradeSnap memory s = _snapTrade(nvdaPair, true);
        swapExactOutDirectAs(hyfi, trader, tIn, tOut, 20e6, trader, expectedIn);
        _assertTrade(nvdaPair, s, expectedIn, 20e6, 0, 2e17 - 0.111222338888888889e18);
    }

    // ------------------------------------------------------------------
    // Reverts
    // ------------------------------------------------------------------

    function test_swapExactOut_RevertWhen_bookTooStale() public {
        vm.warp(block.timestamp + 100_000); // fee capped at 100%
        (address tIn, address tOut) = _tokens(nvdaPair, true);
        vm.startPrank(trader);
        nvda.approve(address(hyfi), type(uint).max);
        vm.expectRevert(HyFi.BookTooStale.selector);
        hyfi.swapExactOutDirect(tIn, tOut, 1e6, trader);
        vm.stopPrank();
    }

    function test_swapExactOut_RevertWhen_pairNotConfigured() public {
        TestToken a = new TestToken("A", "A", 18);
        TestToken b = new TestToken("B", "B", 18);
        a.mint(trader, 100e18);
        vm.startPrank(trader);
        a.approve(address(hyfi), type(uint).max);
        vm.expectRevert(HyFi.PairNotConfigured.selector);
        hyfi.swapExactOutDirect(address(a), address(b), 1e18, trader);
        vm.stopPrank();
    }

    function test_swapExactOut_RevertWhen_insufficientLiquidity() public {
        (address tIn, address tOut) = _tokens(nvdaPair, true);
        vm.startPrank(trader);
        nvda.approve(address(hyfi), type(uint).max);
        vm.expectRevert(HyFi.InsufficientLiquidity.selector);
        hyfi.swapExactOutDirect(tIn, tOut, 200e6, trader); // whole bid book only yields ~108 USDG
        vm.stopPrank();
    }

    function test_swapExactOut_RevertWhen_valueSentWithErc20() public {
        (address tIn, address tOut) = _tokens(nvdaPair, true);
        vm.deal(trader, 1 ether);
        vm.startPrank(trader);
        nvda.approve(address(hyfi), type(uint).max);
        vm.expectRevert(HyFi.InvalidMsgValue.selector);
        hyfi.swapExactOutDirect{value: 1 wei}(tIn, tOut, 20e6, trader);
        vm.stopPrank();
    }
}
