// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @dev Deposits are plain token transfers into the hook, which custodies liquidity directly
/// (no ERC-6909 claims, the PoolManager is not involved). Every test asserts both what changed
/// (depositor debited, hook credited for the deposited currency) and what didn't (the
/// beneficiary's own balance - it's attribution-only, the PoolManager's balances, unrelated
/// currencies, the books, pair configs and roles).
contract HyFiHookDepositTest is HyFiSetup {
    address internal beneficiary = makeAddr("beneficiary");

    /// @dev Snapshot of everything a deposit must NOT touch, regardless of which currency moves.
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

    function test_deposit_erc20_pullsTokensIntoHook() public {
        Currency c = Currency.wrap(address(usdg));
        uint mmBefore = usdg.balanceOf(mm);
        uint hookBefore = usdg.balanceOf(address(hyfi));
        uint beneficiaryBefore = usdg.balanceOf(beneficiary);
        uint hookNvdaBefore = nvda.balanceOf(address(hyfi));
        Invariants memory inv = _snapInvariants();

        vm.startPrank(mm);
        usdg.approve(address(hyfi), 123e6);
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.Deposit(mm, beneficiary, c, 123e6);
        hyfi.deposit(c, 123e6, beneficiary);
        vm.stopPrank();

        // changed
        assertEq(mmBefore - usdg.balanceOf(mm), 123e6, "depositor debited");
        assertEq(usdg.balanceOf(address(hyfi)) - hookBefore, 123e6, "hook custodies the tokens");
        // unchanged
        assertEq(usdg.balanceOf(beneficiary), beneficiaryBefore, "beneficiary is attribution-only, receives nothing");
        assertEq(nvda.balanceOf(address(hyfi)), hookNvdaBefore, "unrelated currency untouched");
        _assertInvariantsUnchanged(inv);
    }

    function test_deposit_native_movesEthIntoHook() public {
        Currency c = Currency.wrap(address(0));
        uint mmBefore = mm.balance;
        uint hookBefore = address(hyfi).balance;
        uint beneficiaryBefore = beneficiary.balance;
        uint hookUsdgBefore = usdg.balanceOf(address(hyfi));
        Invariants memory inv = _snapInvariants();

        vm.prank(mm);
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.Deposit(mm, beneficiary, c, 2 ether);
        hyfi.deposit{value: 2 ether}(c, 2 ether, beneficiary);

        // changed
        assertEq(mmBefore - mm.balance, 2 ether, "depositor debited");
        assertEq(address(hyfi).balance - hookBefore, 2 ether, "hook custodies the ETH");
        // unchanged
        assertEq(beneficiary.balance, beneficiaryBefore, "beneficiary is attribution-only, receives nothing");
        assertEq(usdg.balanceOf(address(hyfi)), hookUsdgBefore, "unrelated currency untouched");
        _assertInvariantsUnchanged(inv);
    }

    function test_deposit_permissionless_anyoneCanDeposit() public {
        Currency c = Currency.wrap(address(toka));
        toka.mint(trader, 5e6);
        uint traderBefore = toka.balanceOf(trader);
        uint hookBefore = toka.balanceOf(address(hyfi));
        Invariants memory inv = _snapInvariants();

        vm.startPrank(trader);
        toka.approve(address(hyfi), 5e6);
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.Deposit(trader, trader, c, 5e6);
        hyfi.deposit(c, 5e6, trader);
        vm.stopPrank();

        // changed
        assertEq(traderBefore - toka.balanceOf(trader), 5e6, "non-role depositor debited");
        assertEq(toka.balanceOf(address(hyfi)) - hookBefore, 5e6, "non-role deposit accepted");
        // unchanged
        _assertInvariantsUnchanged(inv);
    }

    function test_deposit_doesNotTouchBooksConfigOrRoles() public {
        Invariants memory inv = _snapInvariants();
        vm.startPrank(mm);
        usdg.approve(address(hyfi), 1e6);
        hyfi.deposit(Currency.wrap(address(usdg)), 1e6, mm);
        vm.stopPrank();
        _assertInvariantsUnchanged(inv);
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
