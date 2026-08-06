// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {IHookStats} from "../src/interfaces/IHookStats.sol";
import {IALFHook} from "../src/interfaces/IALFHook.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @dev supportsInterface (IERC165) declares support for the URC-3 IHookStats interface.
contract HyFiHookSupportsInterfaceTest is HyFiSetup {
    function test_supportsInterface_true_forIHookStats() public view {
        assertTrue(hyfi.supportsInterface(type(IHookStats).interfaceId), "IHookStats supported");
    }

    function test_supportsInterface_true_forIALFHook() public view {
        assertTrue(hyfi.supportsInterface(type(IALFHook).interfaceId), "IALFHook supported");
    }

    function test_supportsInterface_true_forIERC165() public view {
        assertTrue(hyfi.supportsInterface(type(IERC165).interfaceId), "IERC165 supported");
    }

    function test_supportsInterface_false_forUnrelatedInterface() public view {
        assertFalse(hyfi.supportsInterface(bytes4(0xdeadbeef)), "unrelated interface not supported");
    }
}
