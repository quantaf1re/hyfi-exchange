pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Utils} from "../../../test/Utils.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {PositionInfo, PositionInfoLibrary} from "@uniswap/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

contract RemoveLiquidityUniV4Pool is Script, Utils {

    using StateLibrary for IPoolManager;
    using PositionInfoLibrary for PositionInfo;

    uint public senderPrivateKey = vm.envUint("PRIVATE_KEY_HYFIHOOK_DEPLOYER");
    address public sender = vm.addr(senderPrivateKey);


    // ----------------------
    IPoolManager public poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951); // Robinhood PoolManager
    IPositionManager public positionManager = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7); // Robinhood PositionManager

    uint public tokenId = 274742; // TODO
    // ----------------------


    IERC20Metadata public token0;
    IERC20Metadata public token1;
    uint public bal0Before;
    uint public bal1Before;
    uint public bal0After;
    uint public bal1After;
    uint public withdrawn0;
    uint public withdrawn1;
    
    function run() public {
        require(address(positionManager) != ADDR_ZERO, "positionManager not deployed on this chain; set it explicitly");

        vm.startBroadcast(senderPrivateKey);

        // Verify the position exists and get its info
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        
        console2.log("=== Position Information ===");
        console2.log("Token ID: ", tokenId);
        console2.log("poolId: ", vm.toString(PoolId.unwrap(poolKey.toId())));
        console2.log("Currency0: ", Currency.unwrap(poolKey.currency0));
        console2.log("Currency1: ", Currency.unwrap(poolKey.currency1));
        console2.log("Fee: ", poolKey.fee);
        console2.log("Tick Lower: ", positionInfo.tickLower());
        console2.log("Tick Upper: ", positionInfo.tickUpper());
        
        // Get current liquidity in the position
        uint128 liquidity = positionManager.getPositionLiquidity(tokenId);
        console2.log("Current Liquidity: ", liquidity);
        
        if (liquidity == 0) {
            console2.log("Position has no liquidity to remove");
            return;
        }

        // Get current pool state for calculations
        (uint160 sqrtPriceX96, int24 currentTick, , ) = poolManager.getSlot0(poolKey.toId());
        console2.log("Current Price: %e", getPriceFromSqrtPriceX96(sqrtPriceX96, false, 18, 6)); // Assuming ETH/USDC
        console2.log("Current Tick: ", currentTick);

        // Calculate current token amounts in the position
        (uint amount0, uint amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(positionInfo.tickLower()),
            TickMath.getSqrtPriceAtTick(positionInfo.tickUpper()),
            liquidity
        );

        console2.log("=== Amounts to Remove ===");
        console2.log("Amount0 (wei): ", amount0);
        console2.log("Amount1 (wei): ", amount1);
        console2.log("Amount0 (tokens): %e", amount0);
        console2.log("Amount1 (tokens): %e", amount1);

        // Create the remove liquidity and burn actions
        (bytes memory actions, bytes[] memory params) = _burnLiquidityParams(poolKey, tokenId, 0, 0, sender);

        // Get token contracts for balance checking
        token0 = IERC20Metadata(Currency.unwrap(poolKey.currency0));
        token1 = IERC20Metadata(Currency.unwrap(poolKey.currency1));
        
        // Measure balances before removal (handle native token)
        bal0Before = poolKey.currency0.balanceOf(sender);
        bal1Before = poolKey.currency1.balanceOf(sender);
        
        console2.log("=== Balances Before Removal ===");
        console2.log("Token0 balance before: ", bal0Before);
        console2.log("Token1 balance before: ", bal1Before);

        // Execute the removal
        console2.log("=== Removing Liquidity ===");
        console2.log("Removing all liquidity...");
        
        bytes[] memory multicallParams = new bytes[](1);
        multicallParams[0] = abi.encodeWithSelector(
            positionManager.modifyLiquidities.selector, 
            abi.encode(actions, params), 
            block.timestamp + 60
        );

        positionManager.multicall(multicallParams);
        
        // Measure balances after removal (handle native token)
        bal0After = poolKey.currency0.balanceOf(sender);
        bal1After = poolKey.currency1.balanceOf(sender);
        
        // Calculate actual withdrawn amounts
        withdrawn0 = bal0After - bal0Before;
        withdrawn1 = bal1After - bal1Before;
        
        console2.log("=== Balances After Removal ===");
        console2.log("Token0 balance after: ", bal0After);
        console2.log("Token1 balance after: ", bal1After);
        
        console2.log("=== Actually Withdrawn ===");
        console2.log("Token0 withdrawn (wei): ", withdrawn0);
        console2.log("Token1 withdrawn (wei): ", withdrawn1);
        console2.log("Token0 withdrawn (tokens): %e", withdrawn0);
        console2.log("Token1 withdrawn (tokens): %e", withdrawn1);

        console2.log("=== Position Successfully Removed ===");
        console2.log("All liquidity removed and fees collected");
        console2.log("Tokens returned to: ", sender);

        vm.stopBroadcast();
    }

    /// @notice Set the token ID to remove liquidity from
    /// @param _tokenId The NFT token ID of the position
    function setTokenId(uint _tokenId) public {
        tokenId = _tokenId;
    }
}
