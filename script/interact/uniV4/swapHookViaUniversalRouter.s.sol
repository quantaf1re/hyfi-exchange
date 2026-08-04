pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Utils, IUniversalRouterMinimal, IPermit2Minimal} from "../../../test/Utils.sol";
import {Addrs} from "../../Addrs.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {HyFi} from "../../../src/HyFi.sol";

contract SwapHookViaUniversalRouter is Script, Utils {
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    uint public senderPrivateKey = vm.envUint("PRIVATE_KEY_HYFI_DEPLOYER");
    address public sender = vm.addr(senderPrivateKey);

    // ----------- Pool configuration -----------
    HyFi public hyfi = getHyFi(block.chainid);
    IPoolManager public pm = getPm(block.chainid);
    IUniversalRouterMinimal public universalRouter = getRouter(block.chainid);
    IPermit2Minimal public permit2 = getPermit2(block.chainid);

    Currency public currency0 = Currency.wrap(Addrs.get(block.chainid, "USDG"));
    Currency public currency1 = Currency.wrap(Addrs.get(block.chainid, "NVDA"));
    IERC20Metadata public token1 = IERC20Metadata(Currency.unwrap(currency1));
    PoolKey public poolKey = PoolKey({
        currency0: currency0,
        currency1: currency1,
        fee: 0,
        tickSpacing: 1,
        hooks: IHooks(address(hyfi))
    });

    // Swap config
    bool public swapZeroForOne = true;
    // bool public swapZeroForOne = false;
    uint public amountIn = 10e6;
    // uint public amountIn = 0.2e18;
    uint public slippageBps = 100;
    uint public constant BPS_DENOM = 10_000;
    uint public constant DEADLINE_BUFFER = 5 minutes;
    string public nativeSymbol = "MATIC";
    uint8 public constant NATIVE_DECIMALS = 18;
    bytes1 internal constant V4_SWAP_COMMAND = bytes1(uint8(0x10));

    // ----------- Swap state -----------
    // Set at declaration (rather than as locals in run()) to avoid a stack-too-deep error.
    Currency public inputCurrency = swapZeroForOne ? poolKey.currency0 : poolKey.currency1;
    Currency public outputCurrency = swapZeroForOne ? poolKey.currency1 : poolKey.currency0;
    string public inSymbol = inputCurrency.isAddressZero() ? nativeSymbol : IERC20Metadata(Currency.unwrap(inputCurrency)).symbol();
    uint8 public inDecimals = inputCurrency.isAddressZero() ? NATIVE_DECIMALS : IERC20Metadata(Currency.unwrap(inputCurrency)).decimals();
    string public outSymbol = outputCurrency.isAddressZero() ? nativeSymbol : IERC20Metadata(Currency.unwrap(outputCurrency)).symbol();
    uint8 public outDecimals = outputCurrency.isAddressZero() ? NATIVE_DECIMALS : IERC20Metadata(Currency.unwrap(outputCurrency)).decimals();

    function run() external {
        require(address(universalRouter) != ADDR_ZERO, "set UNIVERSAL_ROUTER_ADDRESS");
        require(address(pm) != ADDR_ZERO, "pm not deployed on this chain");

        // --- read-only: pool state + quote --------------------------------
        // Deliberately BEFORE vm.startBroadcast: `hyfi.quote` (the routed, fee-inclusive quote)
        // isn't declared `view` (it may cache the protocol-fee token jar on first use), so calling
        // it here keeps it a local simulation instead of a real broadcast transaction.
        (uint160 sqrtPriceX96, int24 tick, , uint24 lpFee) = pm.getSlot0(poolKey.toId());
        require(sqrtPriceX96 != 0, "pool not initialized");
        uint priceT0ToT1 = getPriceFromSqrtPriceX96(sqrtPriceX96, false, 18, token1.decimals());
        _logPoolState(sqrtPriceX96, tick, lpFee, priceT0ToT1);

        bool inputIsNative = inputCurrency.isAddressZero();
        uint minAmountOut = _computeMinAmountOut();
        console2.log("Min amount out (buffered): %e", minAmountOut);

        vm.startBroadcast(senderPrivateKey);

        _prepareInput();
        uint balInBefore = inputCurrency.balanceOf(sender);
        uint balOutBefore = outputCurrency.balanceOf(sender);

        uint swapAmount = amountIn;
        if (!inputIsNative) {
            if (swapAmount == 0 || swapAmount > balInBefore) {
                swapAmount = balInBefore;
            }
        } else {
            require(swapAmount > 0, "amountIn required");
        }
        require(swapAmount > 0, "no input to swap");

        _logBalances("before");

        require(swapAmount <= type(uint128).max, "amountIn too large");
        require(minAmountOut <= type(uint128).max, "minOut too large");

        console2.log("Time now: ", block.timestamp);

        uint valueToSend = inputIsNative ? swapAmount : 0;
        {
            bytes memory actions = abi.encodePacked(
                bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
                bytes1(uint8(Actions.SETTLE_ALL)),
                bytes1(uint8(Actions.TAKE_ALL))
            );

            bytes[] memory params = new bytes[](3);
            params[0] = abi.encode(
                IV4Router.ExactInputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: swapZeroForOne,
                    amountIn: uint128(swapAmount),
                    amountOutMinimum: uint128(minAmountOut),
                    minHopPriceX36: 0,
                    hookData: bytes("")
                })
            );
            params[1] = abi.encode(inputCurrency, type(uint).max);
            params[2] = abi.encode(outputCurrency, uint(0));

            bytes[] memory inputs = new bytes[](1);
            inputs[0] = abi.encode(actions, params);
            bytes memory commands = abi.encodePacked(V4_SWAP_COMMAND);
            universalRouter.execute{value: valueToSend}(commands, inputs, block.timestamp + DEADLINE_BUFFER);
        }

        console2.log("=== Swap submitted via Universal Router ===");
        _logBalances("after");
        uint balInAfter = inputCurrency.balanceOf(sender);
        uint balOutAfter = outputCurrency.balanceOf(sender);
        uint spent = inputIsNative ? valueToSend : (balInBefore > balInAfter ? balInBefore - balInAfter : 0);
        uint received = balOutAfter > balOutBefore ? balOutAfter - balOutBefore : 0;
        logTokenAmount("Actual input used", inSymbol, spent, inDecimals);
        logTokenAmount("Output received", outSymbol, received, outDecimals);

        vm.stopBroadcast();
    }

    /// @dev Quotes the swap through the routed (fee-inclusive) entrypoint - the same accounting
    ///      `beforeSwap` applies: HyFi's book price, plus any live Uniswap protocol fee on top.
    ///      Logs the implied forward and reverse prices (both 1e18-scaled) and applies a slippage
    ///      buffer on top of the quoted output for price movement between quoting and execution.
    ///      Must be called before `vm.startBroadcast` - see the note in `run()`.
    function _computeMinAmountOut() internal returns (uint) {
        uint expectedOut = hyfi.quote(swapZeroForOne, -int256(amountIn), poolKey.toId());

        uint impliedPriceForward = priceFromQuote(amountIn, expectedOut, inDecimals, outDecimals);
        uint impliedPriceReverse = priceFromQuote(expectedOut, amountIn, outDecimals, inDecimals);
        console2.log("=== Hook Quote (net of protocol fee) ===");
        logTokenAmount("Hook quote implied price (output per input)", "1e18", impliedPriceForward, 18);
        logTokenAmount("Hook quote implied price (input per output)", "1e18", impliedPriceReverse, 18);

        if (expectedOut == 0) {
            return 0;
        }

        uint buffer = Math.mulDiv(expectedOut, slippageBps, BPS_DENOM);
        return expectedOut > buffer ? expectedOut - buffer : 0;
    }

    function _prepareInput() internal {
        if (inputCurrency.isAddressZero()) {
            console2.log("Using native currency for input; sending value with transaction");
            return;
        }

        IERC20Metadata tokenIn = IERC20Metadata(Currency.unwrap(inputCurrency));
        address permit2Address = address(permit2);

        uint allowance = tokenIn.allowance(sender, permit2Address);
        if (allowance < amountIn) {
            console2.log("Approving Permit2 to pull input token allowance");
            tokenIn.approve(permit2Address, type(uint).max);
        }

        (uint160 permitAllowance, uint48 expiration,) = permit2.allowance(sender, address(tokenIn), address(universalRouter));
        if (permitAllowance < amountIn || expiration < block.timestamp) {
            console2.log("Setting Permit2 allowance for the Universal Router");
            permit2.approve(address(tokenIn), address(universalRouter), type(uint160).max, type(uint48).max);
        }
    }

    function _logPoolState(uint160 sqrtPriceX96, int24 tick, uint24 lpFee, uint price) internal pure {
        console2.log("=== Pool State ===");
        console2.log("sqrtPriceX96:", sqrtPriceX96);
        console2.log("tick:", tick);
        console2.log("lpFee (in bps*1e2):", lpFee);
        console2.log("price: %e", price);
    }

    function _logBalances(string memory prefix) internal view {
        uint balIn = inputCurrency.balanceOf(sender);
        uint balOut = outputCurrency.balanceOf(sender);
        console2.log(string.concat("=== Balances ", prefix, " ==="));
        logTokenAmount("Input token balance", inSymbol, balIn, inDecimals);
        logTokenAmount("Output token balance", outSymbol, balOut, outDecimals);
    }

    receive() external payable {}
}
