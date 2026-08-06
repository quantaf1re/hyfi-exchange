pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {Utils} from "../../../test/Utils.sol";
import {Addrs} from "../../Addrs.sol";
import {HyFi} from "../../../src/HyFi.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";


contract InitializeUniV4Pool is Script, Utils {

    using StateLibrary for IPoolManager;

    uint public senderPrivateKey = vm.envUint("PRIVATE_KEY_HYFI_DEPLOYER");
    address public sender = vm.addr(senderPrivateKey);

    HyFi public hyfi = getHyFi(block.chainid);
    IPoolManager public pm = getPm(block.chainid);

    PoolKey public poolKey = PoolKey({
        currency0: Currency.wrap(Addrs.get(block.chainid, "USDG")),
        currency1: Currency.wrap(Addrs.get(block.chainid, "NVDA")),
        fee: 0,
        tickSpacing: 1,
        hooks: IHooks(address(hyfi))
    });

    function run() public {
        vm.startBroadcast(senderPrivateKey);
        pm.initialize(poolKey, SQRT_PRICE_1_1);
        vm.stopBroadcast();

        (uint160 sqrtPriceX96, int24 tick, , ) = pm.getSlot0(poolKey.toId());
        console2.log("sqrtPriceX96:", sqrtPriceX96);
        console2.log("tick:", tick);
        console2.log("Done!");
    }
}
