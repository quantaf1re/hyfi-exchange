// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @dev These callbacks carry no permission flags, so the PoolManager never invokes them; they
/// exist only to satisfy IHooks and revert if reached.
contract HyFiHookUnusedHooksTest is HyFiSetup {
    ModifyLiquidityParams internal mlp = ModifyLiquidityParams(0, 0, 0, 0);
    SwapParams internal sp = SwapParams(true, -1, 0);

    function test_afterInitialize_RevertWhen_called() public {
        vm.expectRevert(HyFi.HookNotImplemented.selector);
        hyfi.afterInitialize(address(0), nvdaPair.key, 0, 0);
    }

    function test_beforeAddLiquidity_RevertWhen_called() public {
        vm.expectRevert(HyFi.HookNotImplemented.selector);
        hyfi.beforeAddLiquidity(address(0), nvdaPair.key, mlp, "");
    }

    function test_afterAddLiquidity_RevertWhen_called() public {
        vm.expectRevert(HyFi.HookNotImplemented.selector);
        hyfi.afterAddLiquidity(address(0), nvdaPair.key, mlp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
    }

    function test_beforeRemoveLiquidity_RevertWhen_called() public {
        vm.expectRevert(HyFi.HookNotImplemented.selector);
        hyfi.beforeRemoveLiquidity(address(0), nvdaPair.key, mlp, "");
    }

    function test_afterRemoveLiquidity_RevertWhen_called() public {
        vm.expectRevert(HyFi.HookNotImplemented.selector);
        hyfi.afterRemoveLiquidity(address(0), nvdaPair.key, mlp, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
    }

    function test_afterSwap_RevertWhen_called() public {
        vm.expectRevert(HyFi.HookNotImplemented.selector);
        hyfi.afterSwap(address(0), nvdaPair.key, sp, BalanceDelta.wrap(0), "");
    }

    function test_beforeDonate_RevertWhen_called() public {
        vm.expectRevert(HyFi.HookNotImplemented.selector);
        hyfi.beforeDonate(address(0), nvdaPair.key, 0, 0, "");
    }

    function test_afterDonate_RevertWhen_called() public {
        vm.expectRevert(HyFi.HookNotImplemented.selector);
        hyfi.afterDonate(address(0), nvdaPair.key, 0, 0, "");
    }
}
