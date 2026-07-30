// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract HyFiHookQuoteTest is HyFiSetup {
    function test_quote_exactIn_sellBase_matchesSwapExactly() public {
        bool zeroForOne = nvdaPair.baseIsCurrency0; // selling base
        (uint amountIn, uint amountOut, uint fee, uint40 bookId) = hyfi.quote(nvdaPair.id, zeroForOne, -int(0.35e18));

        assertEq(amountIn, 0.35e18, "quoted amountIn");
        assertEq(amountOut, 62.998500e6, "quoted amountOut");
        assertEq(fee, 0, "no fee at zero elapsed");
        assertEq(bookId, _bookId(nvdaPair.id), "quoted against current snapshot");

        uint usdgBefore = usdg.balanceOf(trader);
        uint nvdaBefore = nvda.balanceOf(trader);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.35e18, uint128(amountOut));
        assertEq(usdg.balanceOf(trader) - usdgBefore, amountOut, "swap output == quote");
        assertEq(nvdaBefore - nvda.balanceOf(trader), amountIn, "swap input == quote");
    }

    function test_quote_exactOut_buyBase_matchesSwapExactly() public {
        bool zeroForOne = !nvdaPair.baseIsCurrency0; // buying base
        (uint amountIn, uint amountOut, uint fee,) = hyfi.quote(nvdaPair.id, zeroForOne, int(0.25e18));

        assertEq(amountOut, 0.25e18, "quoted amountOut");
        assertEq(amountIn, 45.003e6, "quoted amountIn");
        assertEq(fee, 0, "no fee at zero elapsed");

        uint usdgBefore = usdg.balanceOf(trader);
        swapExactOutAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, false, 0.25e18, uint128(amountIn));
        assertEq(usdgBefore - usdg.balanceOf(trader), amountIn, "swap input == quote");
    }

    function test_quote_exactIn_buyBase_matchesSwapExactly() public {
        bool zeroForOne = !nvdaPair.baseIsCurrency0; // buying base (paying quote in)
        (uint amountIn, uint amountOut, uint fee,) = hyfi.quote(nvdaPair.id, zeroForOne, -int(100e6));

        // ticks 0+1 fully consumed (36.002 + 54.006 USDG), remainder buys into tick 2 @ $180.03:
        // 9.992 USDG / $180.03 = 0.055501860800977614 NVDA (rounded down)
        assertEq(amountIn, 100e6, "quoted amountIn");
        assertEq(amountOut, 0.5e18 + 0.055501860800977614e18, "quoted amountOut");
        assertEq(fee, 0, "no fee at zero elapsed");

        uint usdgBefore = usdg.balanceOf(trader);
        uint nvdaBefore = nvda.balanceOf(trader);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, false, 100e6, uint128(amountOut));
        assertEq(usdgBefore - usdg.balanceOf(trader), amountIn, "swap input == quote");
        assertEq(nvda.balanceOf(trader) - nvdaBefore, amountOut, "swap output == quote");
    }

    function test_quote_exactOut_sellBase_matchesSwapExactly() public {
        bool zeroForOne = nvdaPair.baseIsCurrency0; // selling base (receiving exact quote out)
        (uint amountIn, uint amountOut, uint fee,) = hyfi.quote(nvdaPair.id, zeroForOne, int(50e6));

        // tick0 capacity 36 USDG, remaining 14 USDG from tick1 @ $179.99:
        // 14 USDG / $179.99 = 0.077782099005500306 NVDA (rounded up, base charged)
        assertEq(amountOut, 50e6, "quoted amountOut");
        assertEq(amountIn, 2e17 + 0.077782099005500306e18, "quoted amountIn");
        assertEq(fee, 0, "no fee at zero elapsed");

        uint usdgBefore = usdg.balanceOf(trader);
        uint nvdaBefore = nvda.balanceOf(trader);
        swapExactOutAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 50e6, uint128(amountIn));
        assertEq(usdg.balanceOf(trader) - usdgBefore, amountOut, "swap output == quote");
        assertEq(nvdaBefore - nvda.balanceOf(trader), amountIn, "swap input == quote");
    }

    function test_quote_includesStalenessFee() public {
        vm.warp(block.timestamp + 10); // 0.1% fee
        bool zeroForOne = nvdaPair.baseIsCurrency0;
        (, uint amountOut, uint fee,) = hyfi.quote(nvdaPair.id, zeroForOne, -int(0.2e18));

        assertEq(fee, 36e3, "quoted fee = 0.1% of 36 USDG");
        assertEq(amountOut, 35.964e6, "quoted net output");

        uint usdgBefore = usdg.balanceOf(trader);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.2e18, uint128(amountOut));
        assertEq(usdg.balanceOf(trader) - usdgBefore, amountOut, "swap matches fee-inclusive quote");
    }

    function test_quote_doesNotMutateState() public {
        (uint slot0Before,,) = hyfi.getBookSideRaw(nvdaPair.id, true);
        hyfi.quote(nvdaPair.id, nvdaPair.baseIsCurrency0, -int(0.35e18));
        (uint slot0After,,) = hyfi.getBookSideRaw(nvdaPair.id, true);
        assertEq(slot0After, slot0Before, "quote left the book untouched");

        // and quoting twice returns identical results
        (uint in1, uint out1,,) = hyfi.quote(nvdaPair.id, nvdaPair.baseIsCurrency0, -int(0.35e18));
        (uint in2, uint out2,,) = hyfi.quote(nvdaPair.id, nvdaPair.baseIsCurrency0, -int(0.35e18));
        assertEq(in1, in2, "idempotent in");
        assertEq(out1, out2, "idempotent out");
    }

    function test_quote_reflectsPointerAfterPartialFill() public {
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.2e18, 0); // drains tick 0

        // next 0.1 NVDA is quoted off tick 1 @ $179.99
        (, uint amountOut,,) = hyfi.quote(nvdaPair.id, nvdaPair.baseIsCurrency0, -int(0.1e18));
        assertEq(amountOut, 17_999_000, "quote continues from the pointer");
    }

    function test_quote_RevertWhen_pairNotConfigured() public {
        vm.expectRevert(HyFi.PairNotConfigured.selector);
        hyfi.quote(PoolId.wrap(bytes32(uint(1))), true, -int(1e18));
    }

    function test_quote_RevertWhen_insufficientLiquidity() public {
        vm.expectRevert(HyFi.InsufficientLiquidity.selector);
        hyfi.quote(nvdaPair.id, nvdaPair.baseIsCurrency0, -int(0.7e18)); // book holds 0.6
    }

    function test_quote_RevertWhen_insufficientLiquidity_buyingBase() public {
        vm.expectRevert(HyFi.InsufficientLiquidity.selector);
        hyfi.quote(nvdaPair.id, !nvdaPair.baseIsCurrency0, -int(200e6)); // ask book costs ~108 USDG
    }

    function test_quote_RevertWhen_exactOutBookTooStale() public {
        vm.warp(block.timestamp + 100_000); // fee capped at 100%
        vm.expectRevert(HyFi.BookTooStale.selector);
        hyfi.quote(nvdaPair.id, nvdaPair.baseIsCurrency0, int(1e6));
    }
}
