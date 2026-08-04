// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {BaseHook} from "@uniswap/v4-hooks-public/base/BaseHook.sol";
import {IAggregatorHook} from "@uniswap/v4-hooks-public/aggregator-hooks/interfaces/IAggregatorHook.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @dev Hooks inherited from BaseHook/BaseAggregatorHook that HyFi does not use. beforeAddLiquidity
/// is flag-enabled but forbids v4 concentrated liquidity (reverts LiquidityNotAllowed); the rest
/// carry no permission flags and revert HookNotImplemented if ever reached. All are gated by
/// onlyPoolManager, so a non-PoolManager caller reverts NotPoolManager first.
contract HyFiHookUnusedHooksTest is HyFiSetup {
    ModifyLiquidityParams internal mlp = ModifyLiquidityParams(0, 0, 0, 0);
    SwapParams internal sp = SwapParams(true, -1, 0);

    function test_beforeAddLiquidity_RevertWhen_liquidityNotAllowed() public {
        vm.prank(address(pm));
        vm.expectRevert(IAggregatorHook.LiquidityNotAllowed.selector);
        hyfi.beforeAddLiquidity(address(0), nvdaPair.key, mlp, "");
    }

    function test_afterInitialize_RevertWhen_called() public {
        vm.prank(address(pm));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hyfi.afterInitialize(address(0), nvdaPair.key, 0, 0);
    }

    function test_afterAddLiquidity_RevertWhen_called() public {
        vm.prank(address(pm));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hyfi.afterAddLiquidity(address(0), nvdaPair.key, mlp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
    }

    function test_beforeRemoveLiquidity_RevertWhen_called() public {
        vm.prank(address(pm));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hyfi.beforeRemoveLiquidity(address(0), nvdaPair.key, mlp, "");
    }

    function test_afterRemoveLiquidity_RevertWhen_called() public {
        vm.prank(address(pm));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hyfi.afterRemoveLiquidity(address(0), nvdaPair.key, mlp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
    }

    function test_afterSwap_RevertWhen_called() public {
        vm.prank(address(pm));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hyfi.afterSwap(address(0), nvdaPair.key, sp, BalanceDelta.wrap(0), "");
    }

    function test_beforeDonate_RevertWhen_called() public {
        vm.prank(address(pm));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hyfi.beforeDonate(address(0), nvdaPair.key, 0, 0, "");
    }

    function test_afterDonate_RevertWhen_called() public {
        vm.prank(address(pm));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hyfi.afterDonate(address(0), nvdaPair.key, 0, 0, "");
    }

    function test_unusedHook_RevertWhen_callerNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hyfi.afterSwap(address(0), nvdaPair.key, sp, BalanceDelta.wrap(0), "");
    }
}
