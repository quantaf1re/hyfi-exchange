// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract HyFiHookSetWithdrawerTest is HyFiSetup {
    address internal newWithdrawer = makeAddr("newWithdrawer");
    address internal recipient = makeAddr("recipient");

    function test_setWithdrawer_setsAddressAndEmits() public {
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.WithdrawerSet(newWithdrawer);
        vm.prank(owner);
        hyfi.setWithdrawer(newWithdrawer);

        assertEq(hyfi.withdrawer(), newWithdrawer, "withdrawer changed");
        // unchanged: other roles
        assertEq(hyfi.owner(), owner, "owner unchanged");
        assertEq(hyfi.updater(), updater, "updater unchanged");
    }

    function test_setWithdrawer_newWithdrawerCanWithdraw_oldCannot() public {
        vm.prank(owner);
        hyfi.setWithdrawer(newWithdrawer);

        Currency c = Currency.wrap(address(usdg));
        vm.prank(withdrawer);
        vm.expectRevert(HyFi.NotWithdrawer.selector);
        hyfi.withdraw(c, 1e6, recipient);

        vm.prank(newWithdrawer);
        hyfi.withdraw(c, 1e6, recipient);
        assertEq(usdg.balanceOf(recipient), 1e6, "withdrawn by new withdrawer");
    }

    function test_setWithdrawer_RevertWhen_notOwner() public {
        vm.prank(withdrawer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, withdrawer));
        hyfi.setWithdrawer(newWithdrawer);
    }
}
