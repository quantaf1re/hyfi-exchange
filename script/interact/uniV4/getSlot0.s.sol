pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Utils} from "../../../test/Utils.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract GetSlot0Simple is Script, Utils {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public pm = IPoolManager(AddressConstants.getPoolManagerAddress(block.chainid));
    IERC20Metadata public t1 = IERC20Metadata(0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359); // USDC

    function run() public view {
        console2.log("=== Slot0 Information ===");
        
        // Create pool key
        PoolKey memory poolKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO, // POL
            currency1: Currency.wrap(address(t1)),   // USDC
            fee: 1999,
            tickSpacing: 1,
            hooks: IHooks(ADDR_ZERO)
        });

        PoolId poolId = poolKey.toId();
        console2.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));

        // Get slot0 data using StateLibrary
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = pm.getSlot0(poolId);
        
        console2.log("SqrtPriceX96:", sqrtPriceX96);
        console2.log("Current Tick:", tick);
        console2.log("Protocol Fee:", protocolFee);
        console2.log("LP Fee:", lpFee);
        
        if (sqrtPriceX96 > 0) {
            uint price = getPriceFromSqrtPriceX96(sqrtPriceX96, false, 18, t1.decimals());
            console2.log("Current Price (POL/USDC): %e", price);
        } else {
            console2.log("Pool not initialized or no liquidity");
        }
    }
}
