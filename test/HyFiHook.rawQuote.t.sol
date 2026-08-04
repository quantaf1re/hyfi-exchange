// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";

/// @dev The IAggregatorHook quote entrypoint `quote(bool, int, PoolId)` inherited from
/// BaseAggregatorHook, which calls HyFi._rawQuote and applies the pool's protocol fee on top
/// (0.1%, live from block ~27,000,000). It returns only the unspecified amount, net of the
/// protocol fee: amountOut - fee for exact-in, amountIn + fee for exact-out. This is the routed
/// (via-Uniswap) price; the fee-free book amounts come from HyFi's own quoteDirect.
contract HyFiHookRawQuoteTest is HyFiSetup {
    function test_rawQuote_exactIn_returnsAmountOut() public {
        bool zeroForOne = nvdaPair.baseIsCurrency0; // selling base
        uint unspecified = hyfi.quote(zeroForOne, -int(0.35e18), nvdaPair.id);
        (, uint amountOut,,) = hyfi.quoteDirect(nvdaPair.id, zeroForOne, -int(0.35e18));
        // routed quote is the book output net of the 0.1% protocol fee
        assertEq(unspecified, amountOut - _uniFeeExactIn(amountOut), "exact-in returns amountOut net of fee");
        assertEq(amountOut, 62_998_500, "matches priced book output");
        assertEq(unspecified, 62_998_500 - 62_999, "net of protocol fee");
    }

    function test_rawQuote_exactOut_returnsAmountIn() public {
        bool zeroForOne = !nvdaPair.baseIsCurrency0; // buying base
        uint unspecified = hyfi.quote(zeroForOne, int(0.25e18), nvdaPair.id);
        (uint amountIn,,,) = hyfi.quoteDirect(nvdaPair.id, zeroForOne, int(0.25e18));
        // routed quote is the book input plus the 0.1% protocol fee
        assertEq(unspecified, amountIn + _uniFeeExactOut(amountIn), "exact-out returns amountIn plus fee");
        assertEq(amountIn, 45_003_000, "matches priced book input");
        assertEq(unspecified, 45_003_000 + 45_049, "plus protocol fee");
    }

    function test_rawQuote_matchesDirectSwapNetOfFee() public {
        bool zeroForOne = nvdaPair.baseIsCurrency0; // selling base
        uint unspecified = hyfi.quote(zeroForOne, -int(0.2e18), nvdaPair.id);
        // selling base: tokenIn = NVDA, tokenOut = USDG. The direct swap has NO protocol fee, so
        // its gross output equals the routed quote grossed back up by the fee.
        (, uint amountOut) = swapExactInDirectAs(hyfi, trader, address(nvda), address(usdg), 0.2e18, trader);
        assertEq(unspecified, amountOut - _uniFeeExactIn(amountOut), "routed quote is direct output net of fee");
    }
}
