// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

contract HyFiHookDepositTest is HyFiSetup {
    address internal beneficiary = makeAddr("beneficiary");

    function test_deposit_erc20_movesTokensAndMintsClaims() public {
        Currency c = Currency.wrap(address(usdg));
        uint mmBefore = usdg.balanceOf(mm);
        uint pmBefore = usdg.balanceOf(address(pm));
        uint claimsBefore = claims(pm, address(hyfi), c);

        vm.startPrank(mm);
        usdg.approve(address(hyfi), 123e6);
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.Deposit(mm, beneficiary, c, 123e6);
        hyfi.deposit(c, 123e6, beneficiary);
        vm.stopPrank();

        assertEq(mmBefore - usdg.balanceOf(mm), 123e6, "depositor debited");
        assertEq(usdg.balanceOf(address(pm)) - pmBefore, 123e6, "PM received tokens");
        assertEq(claims(pm, address(hyfi), c) - claimsBefore, 123e6, "hook claims minted");
        // unchanged: hook itself never holds tokens
        assertEq(usdg.balanceOf(address(hyfi)), 0, "hook token balance stays 0");
    }

    function test_deposit_native_movesEthAndMintsClaims() public {
        Currency c = Currency.wrap(address(0));
        uint mmBefore = mm.balance;
        uint pmBefore = address(pm).balance;
        uint claimsBefore = claims(pm, address(hyfi), c);

        vm.prank(mm);
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.Deposit(mm, beneficiary, c, 2 ether);
        hyfi.deposit{value: 2 ether}(c, 2 ether, beneficiary);

        assertEq(mmBefore - mm.balance, 2 ether, "depositor debited");
        assertEq(address(pm).balance - pmBefore, 2 ether, "PM received ETH");
        assertEq(claims(pm, address(hyfi), c) - claimsBefore, 2 ether, "hook claims minted");
        assertEq(address(hyfi).balance, 0, "hook ETH balance stays 0");
    }

    function test_deposit_permissionless_anyoneCanDeposit() public {
        Currency c = Currency.wrap(address(toka));
        toka.mint(trader, 5e6);
        uint claimsBefore = claims(pm, address(hyfi), c);
        vm.startPrank(trader);
        toka.approve(address(hyfi), 5e6);
        hyfi.deposit(c, 5e6, trader);
        vm.stopPrank();
        assertEq(claims(pm, address(hyfi), c) - claimsBefore, 5e6, "non-role deposit accepted");
    }

    function test_deposit_RevertWhen_nativeValueMismatch() public {
        vm.prank(mm);
        vm.expectRevert(HyFi.InvalidMsgValue.selector);
        hyfi.deposit{value: 1 ether}(Currency.wrap(address(0)), 2 ether, mm);
    }

    function test_deposit_RevertWhen_valueSentWithErc20() public {
        vm.prank(mm);
        vm.expectRevert(HyFi.InvalidMsgValue.selector);
        hyfi.deposit{value: 1 wei}(Currency.wrap(address(usdg)), 1e6, mm);
    }
}
