// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";
import {TestToken} from "./mocks/TestToken.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";

contract HyFiHookBeforeInitializeTest is HyFiSetup {
    function test_beforeInitialize_allowsConfiguredKey() public {
        // fresh, uninitialized pair (fee 0, tickSpacing 1 - the only shape HyFi allows)
        TestToken x = new TestToken("X", "X", 18);
        TestToken y = new TestToken("Y", "Y", 6);
        (PoolKey memory key, bool baseIsCurrency0) = poolKeyFor(address(x), address(y), address(hyfi));

        vm.prank(owner);
        hyfi.setPairConfig(key, 1e10, 1e17, 0, baseIsCurrency0);

        pm.initialize(key, SQRT_PRICE_1_1); // does not revert

        (uint128 tickWidth,,,) = hyfi.pairConfig(key.toId());
        assertEq(tickWidth, 1e10, "config stored");
        // unchanged: an existing pair's config
        (uint128 nvdaTw,,,) = hyfi.pairConfig(nvdaPair.id);
        assertEq(nvdaTw, nvdaPair.tickWidth, "existing config untouched");
    }

    function test_beforeInitialize_RevertWhen_pairNotConfigured() public {
        TestToken x = new TestToken("X", "X", 18);
        TestToken y = new TestToken("Y", "Y", 6);
        (PoolKey memory key,) = poolKeyFor(address(x), address(y), address(hyfi));
        vm.expectRevert(hookRevert(address(hyfi), IHooks.beforeInitialize.selector, HyFi.PairNotConfigured.selector));
        pm.initialize(key, SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_RevertWhen_callerNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hyfi.beforeInitialize(address(this), nvdaPair.key, SQRT_PRICE_1_1);
    }
}
