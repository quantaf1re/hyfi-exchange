pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Utils} from "../../../test/Utils.sol";
import {Addrs} from "../../Addrs.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {HyFi} from "../../../src/HyFi.sol";


contract AddLiquidityUniV4Pool is Script, Utils {

    using StateLibrary for IPoolManager;

    uint public senderPrivateKey = vm.envUint("PRIVATE_KEY_HYFI_DEPLOYER");
    address public sender = vm.addr(senderPrivateKey);


    // ----------------------
    HyFi public hyfi = getHyFi(block.chainid);
    IPoolManager public poolManager = getPm(block.chainid);
    IPositionManager public positionManager = getPositionManager(block.chainid);

    PoolKey public poolKey = PoolKey({
        currency0: getCurrency(block.chainid, "USDG"),
        currency1: getCurrency(block.chainid, "NVDA"),
        fee: 0,
        tickSpacing: 1,
        hooks: IHooks(address(hyfi))
    });
    uint public am0 = 550e6;
    uint public am1 = 0;
    int24 public tickLowerFromTickCur = 1000;
    int24 public tickUpperFromTickCur = 1001;
    // ----------------------


    function run() public {
        require(address(positionManager) != ADDR_ZERO, "positionManager not deployed on this chain; set it explicitly");

        vm.startBroadcast(senderPrivateKey);

        IERC20Metadata token1 = IERC20Metadata(Currency.unwrap(poolKey.currency1));

        (int24 tickLower, int24 tickUpper, uint128 liquidity, uint am0Max, uint am1Max) = _computeMintAmounts(token1);
        (bytes memory actions, bytes[] memory mintParams) = _mintLiquidityParams(poolKey, tickLower, tickUpper, liquidity, am0Max, am1Max, sender, new bytes(0));
        // multicall parameters
        bytes[] memory params = new bytes[](1);
        // Mint Liquidity
        params[0] = abi.encodeWithSelector(positionManager.modifyLiquidities.selector, abi.encode(actions, mintParams), block.timestamp + 60);

        tokensApprovals(sender, positionManager, IERC20Metadata(Currency.unwrap(poolKey.currency0)), IERC20Metadata(Currency.unwrap(poolKey.currency1)));
        console2.log("Minting position...");
        
        // Record logs to capture the Transfer event
        vm.recordLogs();
        positionManager.multicall{value: poolKey.currency0.isAddressZero() ? am0Max : 0}(params);
        
        // Get the minted NFT token ID from Transfer event
        uint tokenId = getTokenIdFromTransferEvent(vm.getRecordedLogs(), sender);
        console2.log("Position created with NFT token ID: ", tokenId);
        console2.log("Done!");
    }

    /// @dev Builds the MINT_POSITION + SETTLE_PAIR action/params pair for a single-pool mint via
    /// PositionManager.modifyLiquidities.
    function _mintLiquidityParams(
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint am0Max,
        uint am1Max,
        address recipient,
        bytes memory hookData
    ) internal pure returns (bytes memory actions, bytes[] memory params) {
        actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        params = new bytes[](2);
        params[0] = abi.encode(key, tickLower, tickUpper, liquidity, uint128(am0Max), uint128(am1Max), recipient, hookData);
        params[1] = abi.encode(key.currency0, key.currency1);
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
}
