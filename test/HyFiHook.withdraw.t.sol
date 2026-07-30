// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {stdError} from "forge-std/StdError.sol";

contract HyFiHookWithdrawTest is HyFiSetup {
    address internal recipient = makeAddr("recipient");

    function test_withdraw_erc20_burnsClaimsAndPaysRecipient() public {
        Currency c = Currency.wrap(address(nvda));
        uint claimsBefore = claims(pm, address(hyfi), c);
        uint pmBefore = nvda.balanceOf(address(pm));

        vm.prank(withdrawer);
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.Withdrawal(recipient, c, 7e18);
        hyfi.withdraw(c, 7e18, recipient);

        assertEq(nvda.balanceOf(recipient), 7e18, "recipient paid exactly");
        assertEq(claimsBefore - claims(pm, address(hyfi), c), 7e18, "claims burned");
        assertEq(pmBefore - nvda.balanceOf(address(pm)), 7e18, "PM tokens released");
        assertEq(nvda.balanceOf(address(hyfi)), 0, "hook never holds tokens");
    }

    function test_withdraw_native_paysRecipient() public {
        Currency c = Currency.wrap(address(0));
        uint claimsBefore = claims(pm, address(hyfi), c);

        vm.prank(withdrawer);
        hyfi.withdraw(c, 1.5 ether, recipient);

        assertEq(recipient.balance, 1.5 ether, "recipient paid ETH");
        assertEq(claimsBefore - claims(pm, address(hyfi), c), 1.5 ether, "claims burned");
    }

    function test_withdraw_doesNotTouchBooks() public {
        (uint slot0Before,,) = hyfi.getBookSideRaw(nvdaPair.id, true);
        vm.prank(withdrawer);
        hyfi.withdraw(Currency.wrap(address(usdg)), 1e6, recipient);
        (uint slot0After,,) = hyfi.getBookSideRaw(nvdaPair.id, true);
        assertEq(slot0After, slot0Before, "book untouched by withdrawal");
    }

    function test_withdraw_RevertWhen_notWithdrawer() public {
        vm.prank(owner); // even the owner cannot withdraw directly
        vm.expectRevert(HyFi.NotWithdrawer.selector);
        hyfi.withdraw(Currency.wrap(address(usdg)), 1e6, recipient);
    }

    function test_withdraw_RevertWhen_exceedsClaims() public {
        Currency c = Currency.wrap(address(toka));
        uint bal = claims(pm, address(hyfi), c);
        vm.prank(withdrawer);
        vm.expectRevert(stdError.arithmeticError); // PM 6909 burn underflow
        hyfi.withdraw(c, bal + 1, recipient);
    }
}
