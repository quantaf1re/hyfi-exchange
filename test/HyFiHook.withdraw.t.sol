// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @dev Withdrawals are plain token transfers out of the hook's own balance, gated on the
/// withdrawer role. The PoolManager is not involved. Every test asserts both what changed
/// (recipient credited, hook debited for the withdrawn currency) and what didn't (unrelated
/// currencies, the PoolManager's balances, the books, pair configs and roles).
contract HyFiHookWithdrawTest is HyFiSetup {
    address internal recipient = makeAddr("recipient");

    /// @dev Snapshot of everything a withdrawal must NOT touch, regardless of which currency moves.
    struct Invariants {
        uint pmUsdg;
        uint pmNvda;
        uint pmToka;
        uint pmTokb;
        uint pmEth;
        SideSnap nvdaBid;
        SideSnap nvdaAsk;
        SideSnap tokBid;
        SideSnap ethBid;
    }

    function _snapInvariants() internal view returns (Invariants memory inv) {
        inv.pmUsdg = usdg.balanceOf(address(pm));
        inv.pmNvda = nvda.balanceOf(address(pm));
        inv.pmToka = toka.balanceOf(address(pm));
        inv.pmTokb = tokb.balanceOf(address(pm));
        inv.pmEth = address(pm).balance;
        inv.nvdaBid = _snapSide(nvdaPair.id, true);
        inv.nvdaAsk = _snapSide(nvdaPair.id, false);
        inv.tokBid = _snapSide(tokPair.id, true);
        inv.ethBid = _snapSide(ethPair.id, true);
    }

    function _assertInvariantsUnchanged(Invariants memory inv) internal view {
        assertEq(usdg.balanceOf(address(pm)), inv.pmUsdg, "PM USDG unchanged");
        assertEq(nvda.balanceOf(address(pm)), inv.pmNvda, "PM NVDA unchanged");
        assertEq(toka.balanceOf(address(pm)), inv.pmToka, "PM TOKA unchanged");
        assertEq(tokb.balanceOf(address(pm)), inv.pmTokb, "PM TOKB unchanged");
        assertEq(address(pm).balance, inv.pmEth, "PM ETH unchanged");
        _assertSideEq(nvdaPair.id, true, inv.nvdaBid);
        _assertSideEq(nvdaPair.id, false, inv.nvdaAsk);
        _assertSideEq(tokPair.id, true, inv.tokBid);
        _assertSideEq(ethPair.id, true, inv.ethBid);
        _assertConfigUnchanged(nvdaPair);
        _assertConfigUnchanged(tokPair);
        _assertConfigUnchanged(ethPair);
        assertEq(hyfi.owner(), owner, "owner unchanged");
        assertEq(hyfi.updater(), updater, "updater unchanged");
        assertEq(hyfi.withdrawer(), withdrawer, "withdrawer unchanged");
    }

    function test_withdraw_erc20_paysRecipientFromHook() public {
        uint hookBefore = nvda.balanceOf(address(hyfi));
        uint hookUsdgBefore = usdg.balanceOf(address(hyfi));
        Invariants memory inv = _snapInvariants();

        vm.prank(withdrawer);
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.Withdrawal(recipient, Currency.wrap(address(nvda)), 7e18);
        hyfi.withdraw(Currency.wrap(address(nvda)), 7e18, recipient);

        // changed
        assertEq(nvda.balanceOf(recipient), 7e18, "recipient paid exactly");
        assertEq(hookBefore - nvda.balanceOf(address(hyfi)), 7e18, "hook balance debited");
        // unchanged
        assertEq(usdg.balanceOf(address(hyfi)), hookUsdgBefore, "unrelated currency untouched");
        _assertInvariantsUnchanged(inv);
    }

    function test_withdraw_native_paysRecipient() public {
        uint hookBefore = address(hyfi).balance;
        uint recipientBefore = recipient.balance;
        uint hookUsdgBefore = usdg.balanceOf(address(hyfi));
        Invariants memory inv = _snapInvariants();

        vm.prank(withdrawer);
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.Withdrawal(recipient, Currency.wrap(address(0)), 1.5 ether);
        hyfi.withdraw(Currency.wrap(address(0)), 1.5 ether, recipient);

        // changed
        assertEq(recipient.balance - recipientBefore, 1.5 ether, "recipient paid ETH");
        assertEq(hookBefore - address(hyfi).balance, 1.5 ether, "hook ETH debited");
        // unchanged
        assertEq(usdg.balanceOf(address(hyfi)), hookUsdgBefore, "unrelated currency untouched");
        _assertInvariantsUnchanged(inv);
    }

    function test_withdraw_doesNotTouchBooksConfigOrRoles() public {
        Invariants memory inv = _snapInvariants();
        vm.prank(withdrawer);
        hyfi.withdraw(Currency.wrap(address(usdg)), 1e6, recipient);
        _assertInvariantsUnchanged(inv);
    }

    function test_withdraw_RevertWhen_notWithdrawer() public {
        vm.prank(owner); // even the owner cannot withdraw directly
        vm.expectRevert(HyFi.NotWithdrawer.selector);
        hyfi.withdraw(Currency.wrap(address(usdg)), 1e6, recipient);
    }

    function test_withdraw_RevertWhen_exceedsBalance() public {
        // TOKA is a mock whose transfer fails when the hook is short; CurrencyLibrary bubbles it up
        Currency c = Currency.wrap(address(toka));
        uint bal = toka.balanceOf(address(hyfi));
        vm.prank(withdrawer);
        vm.expectRevert();
        hyfi.withdraw(c, bal + 1, recipient);
    }
}
