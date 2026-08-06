// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";

/// @dev URC-4 hook-level metadata: `isLive` (coarse health) and `maxGas` (quote gas budget).
/// `swapToPrice` (price-bounded simulation) has its own dedicated test file.
contract HyFiHookAlfMetadataTest is HyFiSetup {
    function test_isLive_returnsTrue() public view {
        assertTrue(hyfi.isLive(), "hook is live");
    }

    function test_maxGas_returnsDeclaredBudget() public view {
        assertEq(hyfi.maxGas(), hyfi.MAX_QUOTE_GAS(), "maxGas == MAX_QUOTE_GAS");
        assertGt(hyfi.maxGas(), 0, "maxGas is a positive budget");
    }
}
