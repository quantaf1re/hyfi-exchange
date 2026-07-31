pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Utils} from "../../../test/Utils.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";


contract InitializeUniV4Pool is Script, Utils {

    using StateLibrary for IPoolManager;

    uint public senderPrivateKey = vm.envUint("PRIVATE_KEY_HYFIHOOK_DEPLOYER");
    address public sender = vm.addr(senderPrivateKey);

    IPoolManager public pm = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

    function run() public {
        vm.startBroadcast(senderPrivateKey);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168), // USDG on Robin
            currency1: Currency.wrap(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC), // NVDA on Robin
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(0x83432ccbf6A058856E90698EcB47561e25f08a88)
        });

        pm.initialize(poolKey, getSqrtPriceX96FromPrice(1 ether, false, 18, 18));

        (uint160 sqrtPriceX96, int24 tick, , ) = pm.getSlot0(poolKey.toId());
        console2.log("sqrtPriceX96:", sqrtPriceX96);
        console2.log("tick:", tick);
        console2.log("Done!");
    }
}
