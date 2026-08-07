// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {HyFi} from "../../../src/HyFi.sol";
import {Utils} from "../../../test/Utils.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Reads HyFi's real token balances (plain ERC20 custody - no PoolManager 6909 claims,
/// no Currency wrapping) for two tokens and logs each as a nominal amount + symbol (e.g. "2.5
/// NVDA"). Read-only - no broadcast needed.
contract GetBalances is Script, Utils {
    using CurrencyLibrary for Currency;

    // ------------------------------------------------------------------
    // Inputs - edit these before running
    // ------------------------------------------------------------------

    string public tokenASymbol = "NVDA";
    string public tokenBSymbol = "USDG";

    // ------------------------------------------------------------------

    function run() external view {
        uint chainId = block.chainid;
        HyFi hyfi = getHyFi(chainId);

        Currency currencyA = getCurrency(chainId, tokenASymbol);
        Currency currencyB = getCurrency(chainId, tokenBSymbol);

        uint balanceA = currencyA.balanceOf(address(hyfi));
        uint balanceB = currencyB.balanceOf(address(hyfi));

        console2.log("=== HyFi Token Balances ===");
        console2.log("chainId:", chainId);
        console2.log("hook:", address(hyfi));
        logTokenAmount("Hook bal", currencyA, balanceA);
        logTokenAmount("Hook bal", currencyB, balanceB);
    }
}
