pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Utils} from "../../../test/Utils.sol";
import {HyFi} from "../../../src/HyFi.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";

/// @notice Checks whether protocol fees are enabled for a given Uniswap v4 pool.
/// Displays both the 0->1 and 1->0 protocol fees in pips (hundredths of a basis point).
/// Read-only - no broadcast needed.
contract CheckProtocolFee is Script, Utils {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using ProtocolFeeLibrary for uint24;

    HyFi public hyfi = getHyFi(block.chainid);
    IPoolManager public pm = getPm(block.chainid);

    PoolKey public poolKey = PoolKey({
        currency0: getCurrency(block.chainid, "USDG"),
        currency1: getCurrency(block.chainid, "NVDA"),
        fee: 0,
        tickSpacing: 1,
        hooks: IHooks(address(hyfi))
    });

    function run() public view {
        PoolId poolId = poolKey.toId();
        
        console2.log("=== Protocol Fee Status ===");
        console2.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));
        console2.log("Currency 0:", Currency.unwrap(poolKey.currency0));
        console2.log("Currency 1:", Currency.unwrap(poolKey.currency1));

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = pm.getSlot0(poolId);

        // Extract individual protocol fees using ProtocolFeeLibrary
        uint16 fee0To1 = protocolFee.getZeroForOneFee();
        uint16 fee1To0 = protocolFee.getOneForZeroFee();

        console2.log("\n=== Current Status ===");
        console2.log("Protocol Fee (packed):", protocolFee);
        console2.log("  0->1 fee (pips):", fee0To1);
        console2.log("  1->0 fee (pips):", fee1To0);
        console2.log("LP Fee (bps):", lpFee);

        bool isEnabled = protocolFee != 0;
        console2.log("\nProtocol Fee Enabled:", isEnabled);
        
        if (isEnabled) {
            console2.log("Status: ACTIVE");
            if (fee0To1 == 0) {
                console2.log("  Note: Only 1->0 direction has a protocol fee");
            }
            if (fee1To0 == 0) {
                console2.log("  Note: Only 0->1 direction has a protocol fee");
            }
        } else {
            console2.log("Status: INACTIVE - Anyone can call setProtocolFee on the PoolManager to enable");
        }
    }
}
