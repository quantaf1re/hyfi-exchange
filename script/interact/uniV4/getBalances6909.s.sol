// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {HyFi} from "../../../src/HyFi.sol";
import {Utils} from "../../../test/Utils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Reads HyFi's ERC-6909 claim balances on the PoolManager for two tokens and logs
/// each as a nominal amount + symbol (e.g. "2.5 NVDA"). Read-only - no broadcast needed.
contract GetBalances6909 is Script, Utils {
    // ------------------------------------------------------------------
    // Inputs - edit these before running
    // ------------------------------------------------------------------

    string public tokenASymbol = "NVDA";
    string public tokenBSymbol = "USDG";

    // ------------------------------------------------------------------

    function run() external view {
        uint chainId = block.chainid;
        HyFi hyfi = getHyFi(chainId);
        IPoolManager pm = getPm(chainId);

        Currency currencyA = getCurrency(chainId, tokenASymbol);
        Currency currencyB = getCurrency(chainId, tokenBSymbol);

        uint balanceA = claims(pm, address(hyfi), currencyA);
        uint balanceB = claims(pm, address(hyfi), currencyB);

        console2.log("=== HyFi ERC-6909 Claim Balances ===");
        console2.log("chainId:", chainId);
        console2.log("hook:", address(hyfi));
        logTokenAmount("Hook 6909 bal", currencyA, balanceA);
        logTokenAmount("Hook 6909 bal", currencyB, balanceB);
    }
}
