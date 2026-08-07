// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {HyFi} from "../../../src/HyFi.sol";
import {Utils} from "../../../test/Utils.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Withdraws `amount` of a token (or native currency) from the HyFi hook to `recipient`.
/// Only the permissioned withdrawer can call this after the offchain MM CEX removes liquidity
/// and the book is updated. Verifies the recipient receives the withdrawn amount.
contract Withdraw is Script, Utils {
    using CurrencyLibrary for Currency;

    // ------------------------------------------------------------------
    // Inputs - edit these before running
    // ------------------------------------------------------------------

    string public tokenName = "NVDA";
    uint public amount = 0.8592458815541429e18;
    /// @dev Recipient address for the withdrawn tokens. address(0) = the withdrawer itself
    address public recipient = address(0);

    // ------------------------------------------------------------------

    function run() external {
        uint chainId = block.chainid;
        HyFi hyfi = getHyFi(chainId);

        uint privateKey = vm.envUint("PRIVATE_KEY_HYFI_WITHDRAWER");
        address sender = vm.addr(privateKey);
        address to = recipient == address(0) ? sender : recipient;

        Currency currency = getCurrency(chainId, tokenName);
        
        uint recipientBalanceBefore = currency.balanceOf(to);

        console2.log("=== Withdrawing from HyFi ===");
        console2.log("chainId:", chainId);
        console2.log("hook:", address(hyfi));
        console2.log("withdrawer:", sender);
        console2.log("recipient:", to);
        console2.log("currency:", Currency.unwrap(currency));
        console2.log("amount:", amount);

        vm.startBroadcast(privateKey);
        hyfi.withdraw(currency, amount, to);
        vm.stopBroadcast();

        // ------------------------------------------------------------------
        // Verify
        // ------------------------------------------------------------------
        console2.log("\n=== Verification ===");
        uint recipientBalanceAfter = currency.balanceOf(to);

        require(recipientBalanceAfter == recipientBalanceBefore + amount, "Withdraw: recipient balance did not increase by amount");

        console2.log("Recipient balance increased by:", amount);
        console2.log("Withdrawal completed successfully!");
    }
}
