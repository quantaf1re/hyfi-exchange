// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {HyFi} from "../../../src/HyFi.sol";
import {Utils} from "../../../test/Utils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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

        IERC20Metadata tokenA = IERC20Metadata(address(getERC20(chainId, tokenASymbol)));
        IERC20Metadata tokenB = IERC20Metadata(address(getERC20(chainId, tokenBSymbol)));

        uint balanceA = claims(pm, address(hyfi), Currency.wrap(address(tokenA)));
        uint balanceB = claims(pm, address(hyfi), Currency.wrap(address(tokenB)));

        console2.log("=== HyFi ERC-6909 Claim Balances ===");
        console2.log("chainId:", chainId);
        console2.log("hook:", address(hyfi));
        logTokenAmount("Hook 6909 bal", tokenA.symbol(), balanceA, tokenA.decimals());
        logTokenAmount("Hook 6909 bal", tokenB.symbol(), balanceB, tokenB.decimals());
    }
}
