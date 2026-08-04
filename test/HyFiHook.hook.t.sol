// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";

/// @dev URC-3 `hook` reports the address of the contract being reported on, which for HyFi is
/// always itself.
contract HyFiHookHookTest is HyFiSetup {
    function test_hook_returnsThisContractAddress() public view {
        assertEq(hyfi.hook(), address(hyfi), "hook() reports itself");
    }
}
