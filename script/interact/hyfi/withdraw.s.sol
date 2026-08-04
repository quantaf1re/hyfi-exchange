// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {HyFi} from "../../../src/HyFi.sol";
import {Utils} from "../../../test/Utils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Withdraws `amount` of a token (or native currency) from the HyFi hook to `recipient`.
/// Only the permissioned withdrawer can call this after the offchain MM CEX removes liquidity
/// and the book is updated. The amount is transferred from the hook's PoolManager ERC-6909 claims.
contract Withdraw is Script, Utils {
    // ------------------------------------------------------------------
    // Inputs - edit these before running
    // ------------------------------------------------------------------

    bool public isNative = false;
    string public tokenName = "NVDA";
    uint public amount = 0.8592458815541429e18;
    /// @dev Recipient address for the withdrawn tokens. address(0) = the withdrawer itself
    address public recipient = address(0);

    // ------------------------------------------------------------------

    function run() external {
        uint chainId = block.chainid;
        HyFi hyfi = getHyFi(chainId);
        IPoolManager pm = getPm(chainId);

        uint privateKey = vm.envUint("PRIVATE_KEY_HYFI_WITHDRAWER");
        address sender = vm.addr(privateKey);
        address to = recipient == address(0) ? sender : recipient;

        Currency currency = isNative ? Currency.wrap(address(0)) : Currency.wrap(address(getERC20(chainId, tokenName)));
        
        uint claimsBefore = claims(pm, address(hyfi), currency);
        uint recipientBalanceBefore = isNative ? to.balance : IERC20(Currency.unwrap(currency)).balanceOf(to);

        console2.log("=== Withdrawing from HyFi ===");
        console2.log("chainId:", chainId);
        console2.log("hook:", address(hyfi));
        console2.log("withdrawer:", sender);
        console2.log("recipient:", to);
        console2.log("currency:", Currency.unwrap(currency));
        console2.log("amount:", amount);
        console2.log("hook claims before:", claimsBefore);

        vm.startBroadcast(privateKey);
        hyfi.withdraw(currency, amount, to);
        vm.stopBroadcast();

        // ------------------------------------------------------------------
        // Verify
        // ------------------------------------------------------------------
        console2.log("\n=== Verification ===");
        uint claimsAfter = claims(pm, address(hyfi), currency);
        uint recipientBalanceAfter = isNative ? to.balance : IERC20(Currency.unwrap(currency)).balanceOf(to);

        require(claimsAfter == claimsBefore - amount, "Withdraw: hook 6909 claims did not decrease by amount");
        require(recipientBalanceAfter == recipientBalanceBefore + amount, "Withdraw: recipient token balance did not increase by amount");

        console2.log("Hook claims decreased by:", amount);
        console2.log("Recipient token balance increased by:", amount);
        console2.log("Withdrawal completed successfully!");
    }
}
