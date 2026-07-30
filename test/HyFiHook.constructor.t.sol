// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract HyFiHookConstructorTest is HyFiSetup {
    function test_constructor_setsRolesAndPoolManager() public view {
        assertEq(hyfi.owner(), owner, "owner");
        assertEq(hyfi.updater(), updater, "updater");
        assertEq(hyfi.withdrawer(), withdrawer, "withdrawer");
        assertEq(address(hyfi.poolManager()), address(pm), "poolManager");
    }

    function test_constructor_hookAddressHasExactFlags() public view {
        assertEq(uint160(address(hyfi)) & ALL_HOOK_MASK, HOOK_FLAGS, "flag bits");
    }

    function test_constructor_RevertWhen_addressFlagsWrong() public {
        // plain CREATE deployment lands on an address without the mined flag bits.
        // HookAddressNotValid carries the (unpredictable) deployed address, so match the selector.
        vm.expectPartialRevert(Hooks.HookAddressNotValid.selector);
        new HyFi(pm, owner, updater, withdrawer);
    }

    function test_constructor_emitsRoleEvents() public {
        bytes memory creation = abi.encodePacked(type(HyFi).creationCode, abi.encode(pm, owner, updater, withdrawer));
        (bytes32 salt, address predicted) = mineHookSalt(address(this), creation);
        vm.expectEmit(true, true, true, true, predicted);
        emit HyFi.UpdaterSet(updater);
        vm.expectEmit(true, true, true, true, predicted);
        emit HyFi.WithdrawerSet(withdrawer);
        new HyFi{salt: salt}(pm, owner, updater, withdrawer);
    }
}
