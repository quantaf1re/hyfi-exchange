pragma solidity ^0.8.30;


import {Script, console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
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


contract AddLiquidityUniV4Pool is Script, Utils {

    using StateLibrary for IPoolManager;

    uint public senderPrivateKey = vm.envUint("PRIVATE_KEY_HYFIHOOK_DEPLOYER");
    address public sender = vm.addr(senderPrivateKey);


    // ----------------------
    IPoolManager public poolManager = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951); // Robinhood PoolManager
    IPositionManager public positionManager = IPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7); // Robinhood PositionManager

    PoolKey public poolKey = PoolKey({
        currency0: Currency.wrap(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168), // USDG on Robin
        currency1: Currency.wrap(0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC), // NVDA on Robin
        fee: 0,
        tickSpacing: 1,
        hooks: IHooks(0x83432ccbf6A058856E90698EcB47561e25f08a88)
    });
    uint public am0 = 500e6;
    uint public am1 = 0;
    int24 public tickLowerFromTickCur = 1000;
    int24 public tickUpperFromTickCur = 1001;
    // ----------------------


    function run() public {
        require(address(positionManager) != ADDR_ZERO, "positionManager not deployed on this chain; set it explicitly");

        vm.startBroadcast(senderPrivateKey);

        IERC20Metadata token0 = IERC20Metadata(Currency.unwrap(poolKey.currency0));
        IERC20Metadata token1 = IERC20Metadata(Currency.unwrap(poolKey.currency1));

        (int24 tickLower, int24 tickUpper, uint128 liquidity, uint am0Max, uint am1Max) = _computeMintAmounts(token1);
        (bytes memory actions, bytes[] memory mintParams) = _mintLiquidityParams(poolKey, tickLower, tickUpper, liquidity, am0Max, am1Max, sender, new bytes(0));
        // multicall parameters
        bytes[] memory params = new bytes[](1);
        // Mint Liquidity
        params[0] = abi.encodeWithSelector(positionManager.modifyLiquidities.selector, abi.encode(actions, mintParams), block.timestamp + 60);

        tokensApprovals(sender, positionManager, token0, token1);
        console2.log("Minting position...");
        
        // Record logs to capture the Transfer event
        vm.recordLogs();
        positionManager.multicall{value: poolKey.currency0.isAddressZero() ? am0Max : 0}(params);
        
        // Get the minted NFT token ID from Transfer event
        uint tokenId = getTokenIdFromTransferEvent(vm.getRecordedLogs(), sender);
        console2.log("Position created with NFT token ID: ", tokenId);
        console2.log("Done!");
    }

    /// @dev Reads current pool state, derives the tick range from `tickCur`, and computes the
    ///      liquidity + slippage-buffered max amounts for the mint. Split out from `run()` to
    ///      avoid a stack-too-deep error.
    function _computeMintAmounts(IERC20Metadata token1)
        internal
        view
        returns (int24 tickLower, int24 tickUpper, uint128 liquidity, uint am0Max, uint am1Max)
    {
        (uint160 sqrtPriceX96, int24 tickCur, uint24 protocolFee, uint24 lpFee) = poolManager.getSlot0(poolKey.toId());
        console2.log("poolId: ", vm.toString(PoolId.unwrap(poolKey.toId())));
        console2.log("sqrtPriceX96: ", sqrtPriceX96);
        console2.log("tickCur: ", tickCur);
        console2.log("protocolFee: ", protocolFee);
        console2.log("lpFee: ", lpFee);
        console2.log("price: %e", getPriceFromSqrtPriceX96(sqrtPriceX96, false, 18, token1.decimals()));

        tickLower = tickCur + tickLowerFromTickCur;
        tickUpper = tickCur + tickUpperFromTickCur;
        console2.log("tickLower: ", tickLower);
        console2.log("tickUpper: ", tickUpper);
        console2.log("TickMath.getSqrtPriceAtTick(tickCur): ", TickMath.getSqrtPriceAtTick(tickCur));
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            am0,
            am1
        );
        console2.log("liquidity: ", liquidity);

        (uint am0In, uint am1In) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidity
        );
        console2.log("am0In: %e", am0In);
        console2.log("am1In: %e", am1In);

        am0Max = am0 + 1;
        am1Max = am1 + 1;
    }

    /// @notice Extract the NFT token ID from Transfer event logs
    /// @param logs Array of logs from the transaction
    /// @param recipient The address that received the NFT (minted to)
    /// @return tokenId The token ID of the minted NFT position
    function getTokenIdFromTransferEvent(Vm.Log[] memory logs, address recipient) internal view returns (uint tokenId) {
        // ERC721 Transfer event signature: Transfer(address indexed from, address indexed to, uint indexed tokenId)
        // Note: the canonical ABI type is uint256 (not the `uint` alias), which is what the event's topic0 hashes.
        bytes32 transferEventSignature = keccak256("Transfer(address,address,uint256)");
        
        for (uint i = 0; i < logs.length; i++) {
            Vm.Log memory log = logs[i];
            
            // Check if this is a Transfer event from the PositionManager contract
            if (log.emitter == address(positionManager) && log.topics[0] == transferEventSignature) {
                address from = address(uint160(uint(log.topics[1])));
                address to = address(uint160(uint(log.topics[2])));
                uint extractedTokenId = uint(log.topics[3]);
                
                // Check if this is a mint (from = address(0)) to our recipient
                if (from == address(0) && to == recipient) {
                    console2.log("Found Transfer event: from=0x0, to=", to, "tokenId=", extractedTokenId);
                    return extractedTokenId;
                }
            }
        }
        
        revert("NFT Transfer event not found - position may not have been minted");
    }
}
