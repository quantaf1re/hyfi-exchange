// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {HyFi} from "../../../src/HyFi.sol";
import {Utils} from "../../../test/Utils.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Deposits `amount` of a token (or native currency) into the HyFi hook, credited to
/// `beneficiary` for offchain MM attribution. `deposit` has no access control - any funded key
/// works as the broadcaster. For ERC20 currencies, only approves the hook if the current
/// allowance is insufficient, skipping the extra tx otherwise.
contract Deposit is Script, Utils {
    // ------------------------------------------------------------------
    // Inputs - edit these before running
    // ------------------------------------------------------------------

    bool public isNative = false;
    string public tokenName = "USDG";
    uint public amount = 100e6;
    /// @dev Who the deposit is attributed to offchain. address(0) = the depositing key itself
    address public beneficiary = address(0);

    // ------------------------------------------------------------------

    function run() external {
        uint chainId = block.chainid;
        HyFi hyfi = getHyFi(chainId);

        uint privateKey = vm.envUint("PRIVATE_KEY_HYFI_DEPLOYER");
        address sender = vm.addr(privateKey);
        address recipient = beneficiary == address(0) ? sender : beneficiary;

        IERC20 token = isNative ? IERC20(address(0)) : getERC20(chainId, tokenName);
        bool needsApproval;
        uint allowanceBefore;
        if (!isNative) {
            allowanceBefore = token.allowance(sender, address(hyfi));
            needsApproval = allowanceBefore < amount;
        }
        // HyFi custodies deposits directly as real ERC20/native balances (no PoolManager 6909 claims)
        uint hookBalanceBefore = isNative ? address(hyfi).balance : token.balanceOf(address(hyfi));

        console2.log("=== Depositing to HyFi ===");
        console2.log("chainId:", chainId);
        console2.log("hook:", address(hyfi));
        console2.log("depositor:", sender);
        console2.log("beneficiary:", recipient);
        console2.log("currency:", address(token));
        console2.log("amount:", amount);
        console2.log(needsApproval ? "Approval needed, will approve" : "Approval not needed, skipping");

        vm.startBroadcast(privateKey);
        if (needsApproval) {
            token.approve(address(hyfi), amount);
        }
        if (isNative) {
            hyfi.deposit{value: amount}(Currency.wrap(address(0)), amount, recipient);
        } else {
            hyfi.deposit(Currency.wrap(address(token)), amount, recipient);
        }
        vm.stopBroadcast();

        // ------------------------------------------------------------------
        // Verify
        // ------------------------------------------------------------------
        console2.log("\n=== Verification ===");
        uint hookBalanceAfter = isNative ? address(hyfi).balance : token.balanceOf(address(hyfi));
        require(hookBalanceAfter == hookBalanceBefore + amount, "Deposit: hook balance did not increase by amount");
        console2.log("Hook balance increased by", amount);
        console2.log("Deposit completed successfully!");
    }
}
