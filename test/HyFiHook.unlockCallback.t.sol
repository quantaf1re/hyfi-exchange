// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract HyFiHookUnlockCallbackTest is HyFiSetup {
    function test_unlockCallback_RevertWhen_callerNotPoolManager() public {
        bytes memory data = abi.encode(HyFi.CallbackData(true, Currency.wrap(address(usdg)), 1e6, mm));
        vm.prank(mm);
        vm.expectRevert(HyFi.NotPoolManager.selector);
        hyfi.unlockCallback(data);
    }

    function test_unlockCallback_RevertWhen_callerIsOwner() public {
        bytes memory data = abi.encode(HyFi.CallbackData(false, Currency.wrap(address(usdg)), 1e6, owner));
        vm.prank(owner);
        vm.expectRevert(HyFi.NotPoolManager.selector);
        hyfi.unlockCallback(data);
    }

    // the PM-invoked deposit and withdraw paths are exercised end-to-end in
    // HyFiHook.deposit.t.sol / HyFiHook.withdraw.t.sol
}
