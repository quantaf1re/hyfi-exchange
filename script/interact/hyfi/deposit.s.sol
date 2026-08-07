// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {HyFi} from "../../../src/HyFi.sol";
import {Utils} from "../../../test/Utils.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Deposits `amount` of a token (or native currency) into the HyFi hook, credited to
/// `beneficiary` for offchain MM attribution. `deposit` has no access control - any funded key
/// works as the broadcaster. For ERC20 currencies, only approves the hook if the current
/// allowance is insufficient, skipping the extra tx otherwise.
contract Deposit is Script, Utils {
    using CurrencyLibrary for Currency;

    // ------------------------------------------------------------------
    // Inputs - edit these before running
    // ------------------------------------------------------------------

    string public tokenName = "NVDA";
    // uint public amount = 100e6;
    uint public amount = 0.5e18;
    /// @dev Who the deposit is attributed to offchain. address(0) = the depositing key itself
    address public beneficiary = address(0);

    // ------------------------------------------------------------------

    function run() external {
        uint chainId = block.chainid;
        HyFi hyfi = getHyFi(chainId);

        uint privateKey = vm.envUint("PRIVATE_KEY_HYFI_DEPLOYER");
        address sender = vm.addr(privateKey);
        address recipient = beneficiary == address(0) ? sender : beneficiary;

        Currency currency = getCurrency(chainId, tokenName);
        bool isNative = currency.isAddressZero();
        bool needsApproval;
        uint allowanceBefore;
        if (!isNative) {
            allowanceBefore = IERC20Metadata(Currency.unwrap(currency)).allowance(sender, address(hyfi));
            needsApproval = allowanceBefore < amount;
        }
        // HyFi custodies deposits directly as real ERC20/native balances (no PoolManager 6909 claims)
        uint hookBalanceBefore = currency.balanceOf(address(hyfi));

        console2.log("=== Depositing to HyFi ===");
        console2.log("chainId:", chainId);
        console2.log("hook:", address(hyfi));
        console2.log("depositor:", sender);
        console2.log("beneficiary:", recipient);
        console2.log("currency:", Currency.unwrap(currency));
        console2.log("amount:", amount);
        console2.log(isNative ? "Approval not needed, native currency" : "Approval needed, will approve");

        vm.startBroadcast(privateKey);
        if (needsApproval) {
            IERC20Metadata(Currency.unwrap(currency)).approve(address(hyfi), amount);
        }
        hyfi.deposit{value: isNative ? amount : 0}(currency, amount, recipient);
        vm.stopBroadcast();

        // ------------------------------------------------------------------
        // Verify
        // ------------------------------------------------------------------
        console2.log("\n=== Verification ===");
        uint hookBalanceAfter = currency.balanceOf(address(hyfi));
        require(hookBalanceAfter == hookBalanceBefore + amount, "Deposit: hook balance did not increase by amount");
        console2.log("Hook balance increased by", amount);
        console2.log("Deposit completed successfully!");
    }
}
