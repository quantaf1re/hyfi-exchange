// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {HyFi} from "../../../src/HyFi.sol";
import {Utils} from "../../../test/Utils.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Reads HyFi's real token balances (plain ERC20 custody - no PoolManager 6909 claims,
/// no Currency wrapping) for two tokens and logs each as a nominal amount + symbol (e.g. "2.5
/// NVDA"). Read-only - no broadcast needed.
contract GetBalances is Script, Utils {
    // ------------------------------------------------------------------
    // Inputs - edit these before running
    // ------------------------------------------------------------------

    string public tokenASymbol = "NVDA";
    string public tokenBSymbol = "USDG";

    // ------------------------------------------------------------------

    function run() external view {
        uint chainId = block.chainid;
        HyFi hyfi = getHyFi(chainId);

        IERC20Metadata tokenA = IERC20Metadata(address(getERC20(chainId, tokenASymbol)));
        IERC20Metadata tokenB = IERC20Metadata(address(getERC20(chainId, tokenBSymbol)));

        uint balanceA = tokenA.balanceOf(address(hyfi));
        uint balanceB = tokenB.balanceOf(address(hyfi));

        console2.log("=== HyFi Token Balances ===");
        console2.log("chainId:", chainId);
        console2.log("hook:", address(hyfi));
        logTokenAmount("Hook bal", tokenA.symbol(), balanceA, tokenA.decimals());
        logTokenAmount("Hook bal", tokenB.symbol(), balanceB, tokenB.decimals());
    }
}
