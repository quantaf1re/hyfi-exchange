// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HyFi} from "../src/HyFi.sol";

/// @dev URC-4 `getIndicativeQuote` assumes the swap routes via Uniswap, so it returns the same
/// protocol-fee-inclusive price as the base's `quote`: output amount for exact-input, input
/// amount for exact-output. Returns 0 for a zero amount or a book that cannot serve the swap;
/// reverts for foreign/unconfigured pool keys.
contract HyFiHookGetIndicativeQuoteTest is HyFiSetup {
    function test_getIndicativeQuote_exactIn_returnsOutput() public {
        bool zeroForOne = nvdaPair.baseIsCurrency0; // selling base
        uint amountOut = hyfi.quote(zeroForOne, -int(0.35e18), nvdaPair.id);

        uint q = hyfi.getIndicativeQuote(nvdaPair.key, zeroForOne, -int(0.35e18), "");
        assertEq(q, amountOut, "indicative quote == base quote output");
    }

    function test_getIndicativeQuote_exactOut_returnsInput() public {
        bool zeroForOne = !nvdaPair.baseIsCurrency0; // buying base
        uint amountIn = hyfi.quote(zeroForOne, int(0.25e18), nvdaPair.id);

        uint q = hyfi.getIndicativeQuote(nvdaPair.key, zeroForOne, int(0.25e18), "");
        assertEq(q, amountIn, "indicative quote == base quote input");
    }

    function test_getIndicativeQuote_ignoresHookData() public {
        bool zeroForOne = nvdaPair.baseIsCurrency0;
        uint qEmpty = hyfi.getIndicativeQuote(nvdaPair.key, zeroForOne, -int(0.35e18), "");
        uint qPayload = hyfi.getIndicativeQuote(nvdaPair.key, zeroForOne, -int(0.35e18), hex"deadbeef");
        assertEq(qEmpty, qPayload, "hookData is ignored");
    }

    function test_getIndicativeQuote_zeroAmount_returnsZero() public {
        uint q = hyfi.getIndicativeQuote(nvdaPair.key, nvdaPair.baseIsCurrency0, 0, "");
        assertEq(q, 0, "zero amount => zero quote");
    }

    function test_getIndicativeQuote_insufficientLiquidity_returnsZero() public {
        // Far more base than the book can serve => walk reverts internally, quote returns 0.
        uint q = hyfi.getIndicativeQuote(nvdaPair.key, nvdaPair.baseIsCurrency0, -int(1_000e18), "");
        assertEq(q, 0, "unavailable liquidity => zero quote");
    }

    function test_getIndicativeQuote_foreignHook_reverts() public {
        PoolKey memory key = PoolKey(Currency.wrap(address(1)), Currency.wrap(address(2)), 0, 1, IHooks(address(0xBEEF)));
        vm.expectRevert(HyFi.InvalidPoolKey.selector);
        hyfi.getIndicativeQuote(key, true, -int(1e18), "");
    }

    function test_getIndicativeQuote_unconfiguredPair_reverts() public {
        PoolKey memory key = PoolKey(Currency.wrap(address(1)), Currency.wrap(address(2)), 0, 1, IHooks(address(hyfi)));
        vm.expectRevert(HyFi.PairNotConfigured.selector);
        hyfi.getIndicativeQuote(key, true, -int(1e18), "");
    }
}
