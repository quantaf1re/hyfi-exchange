// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract HyFiHookBeforeInitializeTest is HyFiSetup {
    function test_beforeInitialize_allowsConfiguredKey() public {
        // a second pool for the same tokens but different tickSpacing = a different poolId
        PoolKey memory key = nvdaPair.key;
        key.tickSpacing = 120;
        vm.prank(owner);
        hyfi.setPairConfig(key, nvdaPair.tickWidth, nvdaPair.baseLiqUnit, 0, false);

        pm.initialize(key, SQRT_PRICE_1_1); // does not revert

        // unchanged: the original pair's config
        (uint128 tickWidth,,,) = hyfi.pairConfig(nvdaPair.id);
        
        assertEq(tickWidth, nvdaPair.tickWidth, "original config untouched");
    }

    function test_beforeInitialize_RevertWhen_pairNotConfigured() public {
        PoolKey memory key = nvdaPair.key;
        key.tickSpacing = 120; // never configured
        vm.expectRevert(hookRevert(address(hyfi), IHooks.beforeInitialize.selector, HyFi.PairNotConfigured.selector));
        pm.initialize(key, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_RevertWhen_callerNotPoolManager() public {
        vm.expectRevert(HyFi.NotPoolManager.selector);
        hyfi.beforeInitialize(address(this), nvdaPair.key, SQRT_PRICE_1_1);
    }
}
