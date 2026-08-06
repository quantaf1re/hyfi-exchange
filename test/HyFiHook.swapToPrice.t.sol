// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {HyFi} from "../src/HyFi.sol";

/// @dev URC-4 `swapToPrice`: price-bounded simulation of the via-Uniswap path. The book walk
/// stops once a tick's raw (pre-fee) price crosses the converted `sqrtPriceLimitX96`, or the
/// requested amount is exhausted, whichever comes first; the Uniswap protocol fee is then layered
/// on top exactly as `getIndicativeQuote`/`quote` do. All tests run at zero elapsed time (no
/// staleness fee), isolating the price-limit behavior.
contract HyFiHookSwapToPriceTest is HyFiSetup {
    // ------------------------------------------------------------------
    // Loose limits: matches an unrestricted quote exactly
    // ------------------------------------------------------------------

    function test_swapToPrice_exactIn_looseLimit_matchesFullQuote() public {
        bool zeroForOne = nvdaPair.baseIsCurrency0; // selling base -> bid side
        // The loosest possible bound for this book: exactly the worst (last) bid tick's price.
        uint tick2Price = uint(nvdaPair.bidTip - 2) * nvdaPair.tickWidth;
        uint160 looseLimit = sqrtPriceX96FromBookPrice(tick2Price, nvdaPair.baseIsCurrency0);

        int amountSpecified = -int(0.35e18);
        uint expectedOut = hyfi.quote(zeroForOne, amountSpecified, nvdaPair.id);

        (uint amountIn, uint amountOut) = hyfi.swapToPrice(nvdaPair.key, zeroForOne, amountSpecified, looseLimit, "");
        assertEq(amountIn, 0.35e18, "full amount consumed (limit non-binding)");
        assertEq(amountOut, expectedOut, "matches protocol-fee-inclusive full quote");
    }

    function test_swapToPrice_exactOut_looseLimit_matchesFullQuote() public {
        bool zeroForOne = !nvdaPair.baseIsCurrency0; // buying base -> ask side
        uint tick2Price = uint(nvdaPair.askTip + 2) * nvdaPair.tickWidth;
        uint160 looseLimit = sqrtPriceX96FromBookPrice(tick2Price, nvdaPair.baseIsCurrency0);

        int amountSpecified = int(0.25e18);
        uint expectedIn = hyfi.quote(zeroForOne, amountSpecified, nvdaPair.id);

        (uint amountIn, uint amountOut) = hyfi.swapToPrice(nvdaPair.key, zeroForOne, amountSpecified, looseLimit, "");
        assertEq(amountOut, 0.25e18, "full output delivered (limit non-binding)");
        assertEq(amountIn, expectedIn, "matches protocol-fee-inclusive full quote");
    }

    // ------------------------------------------------------------------
    // "No limit" sentinels + out-of-range limits (ALF convention)
    // ------------------------------------------------------------------

    /// @dev The ALF convention (per SwapSimulator) signals "no limit" with MIN_SQRT_PRICE+1 /
    /// MAX_SQRT_PRICE-1, which convert to non-binding book limits and price the whole amount.
    function test_swapToPrice_exactIn_noLimitSentinel_matchesFullQuote() public {
        bool zeroForOne = nvdaPair.baseIsCurrency0; // selling base
        uint160 noLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        int amountSpecified = -int(0.35e18);

        uint expectedOut = hyfi.quote(zeroForOne, amountSpecified, nvdaPair.id);
        (uint amountIn, uint amountOut) = hyfi.swapToPrice(nvdaPair.key, zeroForOne, amountSpecified, noLimit, "");
        assertEq(amountIn, 0.35e18, "full amount consumed (no-limit sentinel)");
        assertEq(amountOut, expectedOut, "matches protocol-fee-inclusive full quote");
    }

    function test_swapToPrice_exactOut_noLimitSentinel_matchesFullQuote() public {
        bool zeroForOne = !nvdaPair.baseIsCurrency0; // buying base
        uint160 noLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        int amountSpecified = int(0.25e18);

        uint expectedIn = hyfi.quote(zeroForOne, amountSpecified, nvdaPair.id);
        (uint amountIn, uint amountOut) = hyfi.swapToPrice(nvdaPair.key, zeroForOne, amountSpecified, noLimit, "");
        assertEq(amountOut, 0.25e18, "full output delivered (no-limit sentinel)");
        assertEq(amountIn, expectedIn, "matches protocol-fee-inclusive full quote");
    }

    /// @dev 0 is out of range (< MIN_SQRT_PRICE), not the "no limit" sentinel: HyFi soft-fails to
    /// (0, 0), matching SwapSimulator's "at or past MIN/MAX => (0, 0)" contract.
    function test_swapToPrice_zeroSqrtLimit_isOutOfRange_returnsZero() public view {
        (uint aIn0, uint aOut0) = hyfi.swapToPrice(nvdaPair.key, nvdaPair.baseIsCurrency0, -int(45e6), 0, "");
        assertEq(aIn0, 0, "0 limit => zero amountIn");
        assertEq(aOut0, 0, "0 limit => zero amountOut");

        // The boundary values themselves are rejected (strictly inside the range is required).
        (uint aInMin,) = hyfi.swapToPrice(nvdaPair.key, nvdaPair.baseIsCurrency0, -int(45e6), TickMath.MIN_SQRT_PRICE, "");
        assertEq(aInMin, 0, "MIN_SQRT_PRICE boundary => zero");
        (uint aInMax,) = hyfi.swapToPrice(nvdaPair.key, nvdaPair.baseIsCurrency0, -int(45e6), TickMath.MAX_SQRT_PRICE, "");
        assertEq(aInMax, 0, "MAX_SQRT_PRICE boundary => zero");
    }

    // ------------------------------------------------------------------
    // Tight limits: nothing fills
    // ------------------------------------------------------------------

    function test_swapToPrice_exactIn_tightLimit_returnsZero() public view {
        bool zeroForOne = nvdaPair.baseIsCurrency0; // selling base -> bid side
        // A full tick better than the tip: no bid tick can ever qualify.
        uint tooTight = (uint(nvdaPair.bidTip) + 1) * nvdaPair.tickWidth;
        uint160 limitSqrt = sqrtPriceX96FromBookPrice(tooTight, nvdaPair.baseIsCurrency0);

        (uint amountIn, uint amountOut) = hyfi.swapToPrice(nvdaPair.key, zeroForOne, -int(0.2e18), limitSqrt, "");
        assertEq(amountIn, 0, "no fill: limit stricter than the best tick");
        assertEq(amountOut, 0, "no fill: limit stricter than the best tick");
    }

    function test_swapToPrice_exactOut_tightLimit_returnsZero() public view {
        bool zeroForOne = !nvdaPair.baseIsCurrency0; // buying base -> ask side
        uint tooTight = (uint(nvdaPair.askTip) - 1) * nvdaPair.tickWidth;
        uint160 limitSqrt = sqrtPriceX96FromBookPrice(tooTight, nvdaPair.baseIsCurrency0);

        (uint amountIn, uint amountOut) = hyfi.swapToPrice(nvdaPair.key, zeroForOne, int(0.1e18), limitSqrt, "");
        assertEq(amountIn, 0, "no fill: limit stricter than the best tick");
        assertEq(amountOut, 0, "no fill: limit stricter than the best tick");
    }

    // ------------------------------------------------------------------
    // Binding limits: partial fill, cut off by price rather than amount
    // ------------------------------------------------------------------

    function test_swapToPrice_exactIn_priceLimitStopsBeforeAmountExhausted() public view {
        bool zeroForOne = nvdaPair.baseIsCurrency0; // selling base -> bid side
        // Target tick1's price exactly: the limit is inclusive, so tick1 fills and tick2 does not.
        uint tick1Price = uint(nvdaPair.bidTip - 1) * nvdaPair.tickWidth;
        uint160 limitSqrt = sqrtPriceX96FromBookPrice(tick1Price, nvdaPair.baseIsCurrency0);

        // Book state: ticks [2, 3, 1] at prices 18000, 17999, 17998
        // Tick 0: 2 units * 0.1 NVDA = 0.2 NVDA @ 18000 * 1e10 = 36e6 quote
        // Tick 1: 3 units * 0.1 NVDA = 0.3 NVDA @ 17999 * 1e10 = 53.997e6 quote (at the limit)
        // Tick 2 is below the limit, so stop after tick 1.
        // Total consumed: 0.5 NVDA, gross output: 89.997e6
        uint expectedAmountIn = 0.5e18;
        uint expectedGrossOut = 89_997_000; // 36e6 + 53.997e6
        uint expectedAmountOut = expectedGrossOut - FullMath.mulDivRoundingUp(expectedGrossOut, PROTOCOL_FEE_PIPS, PIPS);

        int amountSpecified = -int(0.6e18);
        (uint amountIn, uint amountOut) = hyfi.swapToPrice(nvdaPair.key, zeroForOne, amountSpecified, limitSqrt, "");
        assertEq(amountIn, expectedAmountIn, "consumed 0.5 NVDA (ticks 0 + 1, tick1 at the limit)");
        assertEq(amountOut, expectedAmountOut, "net quote after protocol fee");
    }

    function test_swapToPrice_exactOut_priceLimitStopsBeforeAmountExhausted() public view {
        bool zeroForOne = !nvdaPair.baseIsCurrency0; // buying base -> ask side
        // Target tick0 price: the limit only allows tick0 to fill, not tick1 or beyond.
        uint tick0Price = uint(nvdaPair.askTip) * nvdaPair.tickWidth;
        uint160 limitSqrt = sqrtPriceX96FromBookPrice(tick0Price, nvdaPair.baseIsCurrency0);

        // Book state (ask side): ticks [2, 3, 1] at prices 18001, 18002, 18003
        // Tick 0: 2 units * 0.1 NVDA = 0.2 NVDA costs 18001 * 1e10 = 36.002e6 quote (rounded up)
        // Tick 1 and beyond exceed the price limit, so stop.
        // Delivered: 0.2 NVDA, gross quote: 36.002e6
        uint expectedAmountOut = 0.2e18;
        uint expectedGrossIn = 36_002_000;
        uint expectedAmountIn = expectedGrossIn + FullMath.mulDivRoundingUp(expectedGrossIn, PROTOCOL_FEE_PIPS, PIPS - PROTOCOL_FEE_PIPS);

        int amountSpecified = int(0.6e18);
        (uint amountIn, uint amountOut) = hyfi.swapToPrice(nvdaPair.key, zeroForOne, amountSpecified, limitSqrt, "");
        assertEq(amountOut, expectedAmountOut, "delivered 0.2 NVDA (tick 0 only, price limit binds)");
        assertEq(amountIn, expectedAmountIn, "quote paid (gross + protocol fee)");
    }

    // ------------------------------------------------------------------
    // Misc
    // ------------------------------------------------------------------

    function test_swapToPrice_ignoresHookData() public view {
        bool zeroForOne = nvdaPair.baseIsCurrency0;
        uint tick2Price = uint(nvdaPair.bidTip - 2) * nvdaPair.tickWidth;
        uint160 looseLimit = sqrtPriceX96FromBookPrice(tick2Price, nvdaPair.baseIsCurrency0);

        (uint inEmpty, uint outEmpty) = hyfi.swapToPrice(nvdaPair.key, zeroForOne, -int(0.35e18), looseLimit, "");
        (uint inPayload, uint outPayload) =
            hyfi.swapToPrice(nvdaPair.key, zeroForOne, -int(0.35e18), looseLimit, hex"deadbeef");
        assertEq(inEmpty, inPayload, "hookData ignored (amountIn)");
        assertEq(outEmpty, outPayload, "hookData ignored (amountOut)");
    }

    function test_swapToPrice_zeroAmount_returnsZeroZero() public view {
        (uint amountIn, uint amountOut) = hyfi.swapToPrice(nvdaPair.key, nvdaPair.baseIsCurrency0, 0, 0, "");
        assertEq(amountIn, 0, "zero amount => zero amountIn");
        assertEq(amountOut, 0, "zero amount => zero amountOut");
    }

    function test_swapToPrice_foreignHook_reverts() public {
        PoolKey memory key = PoolKey(Currency.wrap(address(1)), Currency.wrap(address(2)), 0, 1, IHooks(address(0xBEEF)));
        vm.expectRevert(HyFi.InvalidPoolKey.selector);
        hyfi.swapToPrice(key, true, -int(1e18), 0, "");
    }

    function test_swapToPrice_unconfiguredPair_reverts() public {
        PoolKey memory key = PoolKey(Currency.wrap(address(1)), Currency.wrap(address(2)), 0, 1, IHooks(address(hyfi)));
        vm.expectRevert(HyFi.PairNotConfigured.selector);
        hyfi.swapToPrice(key, true, -int(1e18), 0, "");
    }
}
