// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {HyFi} from "../../../src/HyFi.sol";
import {Utils} from "../../../test/Utils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
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
        IPoolManager pm = getPm(chainId);

        uint privateKey = vm.envUint("PRIVATE_KEY_HYFI_DEPLOYER");
        address sender = vm.addr(privateKey);
        address recipient = beneficiary == address(0) ? sender : beneficiary;

        Currency currency = isNative ? Currency.wrap(address(0)) : Currency.wrap(address(getERC20(chainId, tokenName)));
        bool needsApproval;
        uint allowanceBefore;
        if (!currency.isAddressZero()) {
            allowanceBefore = IERC20(Currency.unwrap(currency)).allowance(sender, address(hyfi));
            needsApproval = allowanceBefore < amount;
        }
        uint claimsBefore = claims(pm, address(hyfi), currency);

        console2.log("=== Depositing to HyFi ===");
        console2.log("chainId:", chainId);
        console2.log("hook:", address(hyfi));
        console2.log("depositor:", sender);
        console2.log("beneficiary:", recipient);
        console2.log("currency:", Currency.unwrap(currency));
        console2.log("amount:", amount);
        console2.log(needsApproval ? "Approval needed, will approve" : "Approval not needed, skipping");

        vm.startBroadcast(privateKey);
        if (needsApproval) {
            IERC20(Currency.unwrap(currency)).approve(address(hyfi), amount);
        }
        if (currency.isAddressZero()) {
            hyfi.deposit{value: amount}(currency, amount, recipient);
        } else {
            hyfi.deposit(currency, amount, recipient);
        }
        vm.stopBroadcast();

        // ------------------------------------------------------------------
        // Verify
        // ------------------------------------------------------------------
        console2.log("\n=== Verification ===");
        uint claimsAfter = claims(pm, address(hyfi), currency);
        require(claimsAfter == claimsBefore + amount, "Deposit: hook 6909 claims did not increase by amount");
        console2.log("Hook 6909 claims increased by", amount);
        console2.log("Deposit completed successfully!");
    }
}
