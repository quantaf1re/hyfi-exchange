// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @dev URC-3 `getReserves` reports the exact same per-pair book accounting as
/// `pseudoTotalValueLocked` - none of HyFi's liquidity is locked/vaulted, it's all sitting
/// directly in the book.
contract HyFiHookGetReservesTest is HyFiSetup {
    function _assertMatchesTVL(PoolKey memory key) internal view {
        (uint tvl0, uint tvl1) = hyfi.pseudoTotalValueLocked(key.toId());
        (uint res0, uint res1) = hyfi.getReserves(key);
        assertEq(res0, tvl0, "reserves amount0 == pseudoTVL amount0");
        assertEq(res1, tvl1, "reserves amount1 == pseudoTVL amount1");
    }

    function test_getReserves_freshBook_nvdaPair() public view {
        // base = NVDA (currency1). ask base = 0.6 NVDA. bid value = 107.995 USDG.
        (uint a0, uint a1) = hyfi.getReserves(nvdaPair.key);
        assertEq(a0, 107_995_000, "amount0 = USDG bid value");
        assertEq(a1, 0.6e18, "amount1 = NVDA ask capacity");
        _assertMatchesTVL(nvdaPair.key);
    }

    function test_getReserves_freshBook_tokPair() public view {
        // base = TOKA (currency0). ask base = 60 TOKA. bid value = 2999.5 TOKB.
        (uint a0, uint a1) = hyfi.getReserves(tokPair.key);
        assertEq(a0, 60e6, "amount0 = TOKA ask capacity");
        assertEq(a1, 2_999.5e18, "amount1 = TOKB bid value");
        _assertMatchesTVL(tokPair.key);
    }

    function test_getReserves_freshBook_ethPair() public view {
        // base = native (currency0). ask base = 0.6 ETH. bid value = 1799.995 USDG.
        (uint a0, uint a1) = hyfi.getReserves(ethPair.key);
        assertEq(a0, 0.6e18, "amount0 = ETH ask capacity");
        assertEq(a1, 1_799_995_000, "amount1 = USDG bid value");
        _assertMatchesTVL(ethPair.key);
    }

    function test_getReserves_shrinksAfterBidSideConsumed() public {
        (uint a0Before,) = hyfi.getReserves(nvdaPair.key);

        // sell 0.2 NVDA: drains bid tick0 (36 USDG of value) exactly
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.2e18, 0);

        (uint a0After,) = hyfi.getReserves(nvdaPair.key);
        assertEq(a0Before - a0After, 36_000_000, "bid value dropped by consumed tick");
        _assertMatchesTVL(nvdaPair.key);
    }

    function test_getReserves_partialTick_honorsAmountLeft() public {
        // sell 0.35 NVDA: leaves bid tick 1 partially filled
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.35e18, 0);
        _assertMatchesTVL(nvdaPair.key);
    }

    function test_getReserves_unconfiguredPair_returnsZero() public view {
        PoolKey memory key = PoolKey(Currency.wrap(address(1)), Currency.wrap(address(2)), 0, 1, IHooks(address(hyfi)));
        (uint a0, uint a1) = hyfi.getReserves(key);
        assertEq(a0, 0, "amount0 zero");
        assertEq(a1, 0, "amount1 zero");
    }
}
