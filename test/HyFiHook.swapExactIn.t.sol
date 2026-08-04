// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestToken} from "./mocks/TestToken.sol";

/// @dev The direct swap path: `swapExactInDirect` pulls the input from the caller and pays the output
/// to `recipient` with no PoolManager involvement (and no Uniswap protocol fee). Pricing is
/// identical to the Uniswap path, so the shared `_assertTrade` invariants apply when the caller
/// and recipient are the same trader. The Trade event's `sender` is the direct caller.
contract HyFiHookSwapExactInTest is HyFiSetup {
    function _tokens(Pair memory p, bool sellingBase) internal pure returns (address tIn, address tOut) {
        (tIn, tOut) = sellingBase
            ? (Currency.unwrap(p.base), Currency.unwrap(p.quote))
            : (Currency.unwrap(p.quote), Currency.unwrap(p.base));
    }

    // ------------------------------------------------------------------
    // NVDA/USDG
    // ------------------------------------------------------------------

    function test_swapExactIn_sellBase_walksMultipleTicks() public {
        (address tIn, address tOut) = _tokens(nvdaPair, true);
        TradeSnap memory s = _snapTrade(nvdaPair, true);

        vm.startPrank(trader);
        IERC20(tIn).approve(address(hyfi), 0.35e18);
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.Trade(nvdaPair.id, trader, _bookId(nvdaPair.id), true, true, 0.35e18, 62_998_500, 0);
        (uint amountIn, uint amountOut) = hyfi.swapExactInDirect(tIn, tOut, 0.35e18, trader);
        vm.stopPrank();

        assertEq(amountIn, 0.35e18, "returned amountIn");
        assertEq(amountOut, 62_998_500, "returned amountOut");
        _assertTrade(nvdaPair, s, 0.35e18, 62_998_500, 1, 1.5e17);
    }

    function test_swapExactIn_buyBase_walksAskSide() public {
        (address tIn, address tOut) = _tokens(nvdaPair, false);
        uint expectedOut = 0.5e18 + 0.055501860800977614e18;
        TradeSnap memory s = _snapTrade(nvdaPair, false);
        swapExactInDirectAs(hyfi, trader, tIn, tOut, 100e6, trader);
        _assertTrade(nvdaPair, s, 100e6, expectedOut, 2, 1e17 - 0.055501860800977614e18);
    }

    function test_swapExactIn_recipientReceivesOutput() public {
        address recipient = makeAddr("recipient");
        (address tIn, address tOut) = _tokens(nvdaPair, true);
        uint traderInBefore = nvda.balanceOf(trader);

        swapExactInDirectAs(hyfi, trader, tIn, tOut, 0.2e18, recipient);

        assertEq(traderInBefore - nvda.balanceOf(trader), 0.2e18, "caller paid the input");
        assertEq(usdg.balanceOf(recipient), 36_000_000, "recipient received the output");
        assertEq(usdg.balanceOf(trader), 1_000_000e6, "caller received nothing");
    }

    // ------------------------------------------------------------------
    // TOKA(6 dec base)/TOKB(18 dec)
    // ------------------------------------------------------------------

    function test_swapExactIn_sellBase_tokPair() public {
        (address tIn, address tOut) = _tokens(tokPair, true);
        TradeSnap memory s = _snapTrade(tokPair, true);
        swapExactInDirectAs(hyfi, trader, tIn, tOut, 25e6, trader);
        _assertTrade(tokPair, s, 25e6, 1_249.95e18, 1, 25e6);
    }

    function test_swapExactIn_buyBase_tokPair() public {
        (address tIn, address tOut) = _tokens(tokPair, false);
        TradeSnap memory s = _snapTrade(tokPair, false);
        swapExactInDirectAs(hyfi, trader, tIn, tOut, 2_000e18, trader);
        _assertTrade(tokPair, s, 2_000e18, 39.988004e6, 1, 10.011996e6);
    }

    // ------------------------------------------------------------------
    // Native ETH/USDG
    // ------------------------------------------------------------------

    function test_swapExactIn_sellNativeBase() public {
        (address tIn, address tOut) = _tokens(ethPair, true); // tIn = address(0)
        TradeSnap memory s = _snapTrade(ethPair, true);
        swapExactInDirectAs(hyfi, trader, tIn, tOut, 0.2e18, trader);
        _assertTrade(ethPair, s, 0.2e18, 600e6, 1, 0);
    }

    function test_swapExactIn_buyNativeBase() public {
        (address tIn, address tOut) = _tokens(ethPair, false); // tOut = address(0)
        uint expectedOut = 0.099999666667777774e18;
        TradeSnap memory s = _snapTrade(ethPair, false);
        swapExactInDirectAs(hyfi, trader, tIn, tOut, 300e6, trader);
        _assertTrade(ethPair, s, 300e6, expectedOut, 0, 2e17 - 0.099999666667777774e18);
    }

    // ------------------------------------------------------------------
    // Staleness fee
    // ------------------------------------------------------------------

    function test_swapExactIn_chargesStalenessFeeOnOutput() public {
        vm.warp(block.timestamp + 10); // 0.1%
        (address tIn, address tOut) = _tokens(nvdaPair, true);
        TradeSnap memory s = _snapTrade(nvdaPair, true);
        vm.startPrank(trader);
        IERC20(tIn).approve(address(hyfi), 0.2e18);
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.Trade(nvdaPair.id, trader, _bookId(nvdaPair.id), true, true, 0.2e18, 35.964e6, 36e3);
        hyfi.swapExactInDirect(tIn, tOut, 0.2e18, trader);
        vm.stopPrank();
        _assertTrade(nvdaPair, s, 0.2e18, 35_964_000, 1, 0);
    }

    // ------------------------------------------------------------------
    // Reverts
    // ------------------------------------------------------------------

    function test_swapExactIn_RevertWhen_pairNotConfigured() public {
        TestToken a = new TestToken("A", "A", 18);
        TestToken b = new TestToken("B", "B", 18);
        a.mint(trader, 1e18);
        vm.startPrank(trader);
        a.approve(address(hyfi), 1e18);
        vm.expectRevert(HyFi.PairNotConfigured.selector);
        hyfi.swapExactInDirect(address(a), address(b), 1e18, trader);
        vm.stopPrank();
    }

    function test_swapExactIn_RevertWhen_insufficientLiquidity() public {
        (address tIn, address tOut) = _tokens(nvdaPair, true);
        vm.startPrank(trader);
        nvda.approve(address(hyfi), 0.7e18);
        vm.expectRevert(HyFi.InsufficientLiquidity.selector);
        hyfi.swapExactInDirect(tIn, tOut, 0.7e18, trader); // book holds 0.6 NVDA
        vm.stopPrank();
    }

    function test_swapExactIn_RevertWhen_valueSentWithErc20() public {
        (address tIn, address tOut) = _tokens(nvdaPair, true);
        vm.deal(trader, 1 ether);
        vm.startPrank(trader);
        nvda.approve(address(hyfi), 0.2e18);
        vm.expectRevert(HyFi.InvalidMsgValue.selector);
        hyfi.swapExactInDirect{value: 1 wei}(tIn, tOut, 0.2e18, trader);
        vm.stopPrank();
    }

    function test_swapExactIn_RevertWhen_nativeValueTooLow() public {
        (address tIn, address tOut) = _tokens(ethPair, true); // native base
        vm.prank(trader);
        vm.expectRevert(HyFi.InvalidMsgValue.selector);
        hyfi.swapExactInDirect{value: 0.1e18}(tIn, tOut, 0.2e18, trader);
    }
}
