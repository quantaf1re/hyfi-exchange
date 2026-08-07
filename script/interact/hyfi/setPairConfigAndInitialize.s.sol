// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {HyFi} from "../../../src/HyFi.sol";
import {Utils} from "../../../test/Utils.sol";
import {Addrs} from "../../Addrs.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Configures a pair on the HyFi hook and initializes its Uniswap v4 pool.
/// Must run in this order (and does, below): `setPairConfig` before `PoolManager.initialize`,
/// since HyFi's `beforeInitialize` hook requires the pair to already be configured.
contract SetPairConfigAndInitialize is Script, Utils {
    // ------------------------------------------------------------------
    // Inputs - edit these before running
    // ------------------------------------------------------------------

    /// @dev Token names, resolved through script/Addrs.sol for the current chain
    string public baseTokenName = "NVDA";
    string public quoteTokenName = "USDG";

    /// @dev Price granularity: 1 tick = `tickQuoteWei` quote-wei per whole base token
    uint public tickQuoteWei = 10 ** 4;
    uint8 public baseDecimals = 18;
    /// @dev Base-token wei represented by 1 unit of tick liquidity
    uint88 public baseLiqUnit = 1e17;
    /// @dev Staleness fee in pips (1e-6), charged per second since the book timestamp
    uint24 public feePerSecond = 100;

    // ------------------------------------------------------------------

    function run() external {
        uint chainId = block.chainid;
        HyFi hyfi = getHyFi(chainId);
        IPoolManager pm = getPm(chainId);

        address baseToken = Addrs.get(chainId, baseTokenName);
        address quoteToken = Addrs.get(chainId, quoteTokenName);
        (PoolKey memory key, bool baseIsCurrency0) = poolKeyFor(baseToken, quoteToken, address(hyfi));
        uint128 tickWidth = calcTickWidth(tickQuoteWei, baseDecimals);

        console2.log("=== Configuring pair ===");
        console2.log("chainId:", chainId);
        console2.log("hook:", address(hyfi));
        console2.log("base:", baseTokenName, baseToken);
        console2.log("quote:", quoteTokenName, quoteToken);
        console2.log("baseIsCurrency0:", baseIsCurrency0);
        console2.log("tickWidth:", tickWidth);
        console2.log("baseLiqUnit:", baseLiqUnit);
        console2.log("feePerSecond:", feePerSecond);

        vm.startBroadcast(vm.envUint("PRIVATE_KEY_HYFI_DEPLOYER"));
        hyfi.setPairConfig(key, tickWidth, baseLiqUnit, feePerSecond, baseIsCurrency0);
        pm.initialize(key, SQRT_PRICE_1_1);
        vm.stopBroadcast();

        // ------------------------------------------------------------------
        // Verify
        // ------------------------------------------------------------------
        console2.log("\n=== Verification ===");
        (uint128 setTickWidth, uint88 setBaseLiqUnit, uint24 setFeePerSecond, bool setBaseIsCurrency0) = hyfi.pairConfig(key.toId());
        require(setTickWidth == tickWidth, "SetPairConfigAndInitialize: tickWidth not set correctly");
        require(setBaseLiqUnit == baseLiqUnit, "SetPairConfigAndInitialize: baseLiqUnit not set correctly");
        require(setFeePerSecond == feePerSecond, "SetPairConfigAndInitialize: feePerSecond not set correctly");
        require(setBaseIsCurrency0 == baseIsCurrency0, "SetPairConfigAndInitialize: baseIsCurrency0 not set correctly");
        console2.log("Pair config verified on-chain");

        console2.log("\n=== Summary ===");
        console2.log("poolId:");
        console2.logBytes32(PoolId.unwrap(key.toId()));
        console2.log("Pair configured and pool initialized successfully!");
    }
}
