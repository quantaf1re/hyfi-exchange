// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Script, console2} from "forge-std/Script.sol";
import {StdConstants} from "forge-std/StdConstants.sol";
import {HyFi} from "../../src/HyFi.sol";
import {Utils} from "../../test/Utils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";


contract Deploy is Script, Utils {

    uint public deployerPrivateKey = vm.envUint("PRIVATE_KEY_HYFI_DEPLOYER");
    address public deployer = vm.addr(deployerPrivateKey);

    address owner = deployer;
    address updater = 0x6f51c775547Dd7E1F1612e461754d3f24483684F;
    address withdrawer = deployer;

    function run() external returns (HyFi hyfi) {
        IPoolManager poolManager = getPm(block.chainid);

        bytes memory creationCode = abi.encodePacked(type(HyFi).creationCode, abi.encode(poolManager, owner, updater, withdrawer));
        // msg.sender of the contract creation is the CREATE2 factory, not msg.origin
        (bytes32 salt, address predicted) = mineHookSalt(StdConstants.CREATE2_FACTORY, creationCode);

        console2.log("=== Deploying HyFi ===");
        console2.log("chainId:", block.chainid);
        console2.log("PoolManager:", address(poolManager));
        console2.log("owner:", owner);
        console2.log("updater:", updater);
        console2.log("withdrawer:", withdrawer);
        console2.log("predicted hook address:", predicted);

        vm.startBroadcast(deployerPrivateKey);
        hyfi = new HyFi{salt: salt}(poolManager, owner, updater, withdrawer);
        vm.stopBroadcast();

        // ------------------------------------------------------------------
        // Verify deployment
        // ------------------------------------------------------------------
        console2.log("\n=== Deployment Verification ===");
        require(address(hyfi) == predicted, "Deploy: deployed address != predicted (wrong CREATE2 deployer?)");
        require((uint160(address(hyfi)) & ALL_HOOK_MASK) == HOOK_FLAGS, "Deploy: hook address flags mismatch");
        require(address(hyfi.poolManager()) == address(poolManager), "Deploy: poolManager not set correctly");
        require(hyfi.owner() == owner, "Deploy: owner not set correctly");
        require(hyfi.updater() == updater, "Deploy: updater not set correctly");
        require(hyfi.withdrawer() == withdrawer, "Deploy: withdrawer not set correctly");
        console2.log("All checks passed");

        // ------------------------------------------------------------------
        // Deployment summary
        // ------------------------------------------------------------------
        console2.log("\n=== Deployment Summary ===");
        console2.log("HyFi:", address(hyfi));
        console2.log("PoolManager:", address(hyfi.poolManager()));
        console2.log("owner:", hyfi.owner());
        console2.log("updater:", hyfi.updater());
        console2.log("withdrawer:", hyfi.withdrawer());
        console2.log("\nDeployment completed successfully!");
    }
}

