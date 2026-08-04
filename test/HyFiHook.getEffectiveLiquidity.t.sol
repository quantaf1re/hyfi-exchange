// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/// @dev URC-3 `getEffectiveLiquidity` reports the exact same per-pair book accounting as
/// `getReserves`/`pseudoTotalValueLocked`: all of HyFi's book liquidity is immediately
/// swappable (no time-locks, vaults or utilization limits), so effective liquidity equals
/// total reserves.
contract HyFiHookGetEffectiveLiquidityTest is HyFiSetup {
    function _assertMatchesReserves(PoolKey memory key) internal view {
        (uint res0, uint res1) = hyfi.getReserves(key);
        (uint eff0, uint eff1) = hyfi.getEffectiveLiquidity(key);
        assertEq(eff0, res0, "effective amount0 == reserves amount0");
        assertEq(eff1, res1, "effective amount1 == reserves amount1");
    }

    function test_getEffectiveLiquidity_freshBook_nvdaPair() public view {
        // base = NVDA (currency1). ask base = 0.6 NVDA. bid value = 107.995 USDG.
        (uint a0, uint a1) = hyfi.getEffectiveLiquidity(nvdaPair.key);
        assertEq(a0, 107_995_000, "amount0 = USDG bid value");
        assertEq(a1, 0.6e18, "amount1 = NVDA ask capacity");
        _assertMatchesReserves(nvdaPair.key);
    }

    function test_getEffectiveLiquidity_freshBook_tokPair() public view {
        // base = TOKA (currency0). ask base = 60 TOKA. bid value = 2999.5 TOKB.
        (uint a0, uint a1) = hyfi.getEffectiveLiquidity(tokPair.key);
        assertEq(a0, 60e6, "amount0 = TOKA ask capacity");
        assertEq(a1, 2_999.5e18, "amount1 = TOKB bid value");
        _assertMatchesReserves(tokPair.key);
    }

    function test_getEffectiveLiquidity_freshBook_ethPair() public view {
        // base = native (currency0). ask base = 0.6 ETH. bid value = 1799.995 USDG.
        (uint a0, uint a1) = hyfi.getEffectiveLiquidity(ethPair.key);
        assertEq(a0, 0.6e18, "amount0 = ETH ask capacity");
        assertEq(a1, 1_799_995_000, "amount1 = USDG bid value");
        _assertMatchesReserves(ethPair.key);
    }

    function test_getEffectiveLiquidity_matchesReserves_afterPartialTick() public {
        // sell 0.35 NVDA: leaves bid tick 1 partially filled
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.35e18, 0);
        _assertMatchesReserves(nvdaPair.key);
    }

    function test_getEffectiveLiquidity_unconfiguredPair_returnsZero() public view {
        PoolKey memory key = PoolKey(Currency.wrap(address(1)), Currency.wrap(address(2)), 0, 1, IHooks(address(hyfi)));
        (uint a0, uint a1) = hyfi.getEffectiveLiquidity(key);
        assertEq(a0, 0, "amount0 zero");
        assertEq(a1, 0, "amount1 zero");
    }
}
