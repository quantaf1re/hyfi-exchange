pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Utils} from "../../../test/Utils.sol";
import {Addrs} from "../../Addrs.sol";
import {HyFi} from "../../../src/HyFi.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

contract GetSlot0 is Script, Utils {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    HyFi public hyfi = getHyFi(block.chainid);
    IPoolManager public pm = getPm(block.chainid);

    PoolKey public poolKey = PoolKey({
        currency0: Currency.wrap(Addrs.get(block.chainid, "USDG")),
        currency1: Currency.wrap(Addrs.get(block.chainid, "NVDA")),
        fee: 0,
        tickSpacing: 1,
        hooks: IHooks(address(hyfi))
    });

    function run() public view {
        IERC20Metadata token0 = IERC20Metadata(Currency.unwrap(poolKey.currency0));
        IERC20Metadata token1 = IERC20Metadata(Currency.unwrap(poolKey.currency1));

        PoolId poolId = poolKey.toId();
        console2.log("=== Slot0 Information ===");
        console2.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = pm.getSlot0(poolId);
        console2.log("SqrtPriceX96:", sqrtPriceX96);
        console2.log("Current Tick:", tick);
        console2.log("Protocol Fee:", protocolFee);
        console2.log("LP Fee:", lpFee);

        if (sqrtPriceX96 > 0) {
            uint price = getPriceFromSqrtPriceX96(sqrtPriceX96, false, token0.decimals(), token1.decimals());
            console2.log("Current Price (token1/token0), 1e18:", price);
        } else {
            console2.log("Pool not initialized or no liquidity");
        }
    }
}
