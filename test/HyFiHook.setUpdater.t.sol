// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract HyFiHookSetUpdaterTest is HyFiSetup {
    address internal newUpdater = makeAddr("newUpdater");

    function test_setUpdater_setsAddressAndEmits() public {
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.UpdaterSet(newUpdater);
        vm.prank(owner);
        hyfi.setUpdater(newUpdater);

        assertEq(hyfi.updater(), newUpdater, "updater changed");
        // unchanged: other roles
        assertEq(hyfi.owner(), owner, "owner unchanged");
        assertEq(hyfi.withdrawer(), withdrawer, "withdrawer unchanged");
    }

    function test_setUpdater_newUpdaterCanUpdate_oldCannot() public {
        vm.prank(owner);
        hyfi.setUpdater(newUpdater);

        HyFi.PairUpdate[] memory updates = pairUpdate(
            nvdaPair.id, ++bookIdCounter, sideUpdate(nvdaPair.bidTip, DEFAULT_TICKS), sideUpdate(nvdaPair.askTip, DEFAULT_TICKS)
        );
        vm.prank(updater);
        vm.expectRevert(HyFi.NotUpdater.selector);
        hyfi.updateBooks(updates, uint32(block.timestamp));

        vm.prank(newUpdater);
        hyfi.updateBooks(updates, uint32(block.timestamp));
        (,, uint40 bookId,,,,) = hyfi.getBookSide(nvdaPair.id, true);
        assertEq(bookId, bookIdCounter, "book updated by new updater");
    }

    function test_setUpdater_RevertWhen_notOwner() public {
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, updater));
        hyfi.setUpdater(newUpdater);
    }
}
