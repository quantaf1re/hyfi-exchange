// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract HyFiHookSetPairConfigTest is HyFiSetup {
    function test_setPairConfig_storesExactConfigAndEmits() public {
        (PoolKey memory key,) = poolKeyFor(address(nvda), address(usdg), address(hyfi));
        vm.expectEmit(true, true, true, true, address(hyfi));
        emit HyFi.PairConfigSet(key.toId(), 2e10, 2e17, 55, false);
        vm.prank(owner);
        hyfi.setPairConfig(key, 2e10, 2e17, 55, false);

        (uint128 tickWidth, uint88 baseLiqUnit, uint24 feePerSecond, bool baseIsCurrency0) = hyfi.pairConfig(nvdaPair.id);
        assertEq(tickWidth, 2e10, "tickWidth");
        assertEq(baseLiqUnit, 2e17, "baseLiqUnit");
        assertEq(feePerSecond, 55, "feePerSecond");
        assertEq(baseIsCurrency0, false, "baseIsCurrency0");

        // unchanged: other pairs' configs
        (uint128 tokTickWidth,,,) = hyfi.pairConfig(tokPair.id);
        assertEq(tokTickWidth, tokPair.tickWidth, "other pair untouched");
    }

    function test_setPairConfig_clearsBookButKeepsTimestampAndBookId() public {
        // consume part of the book so cur/amountLeft are non-zero
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.35e18, 0);
        (,, uint40 bookIdBefore, uint8 curBefore,,,) = hyfi.getBookSide(nvdaPair.id, true);
        assertEq(curBefore, 1, "precondition: pointer advanced");
        (, uint wordABefore, uint wordBBefore) = hyfi.getBookSideRaw(nvdaPair.id, true);

        vm.prank(owner);
        hyfi.setPairConfig(nvdaPair.key, nvdaPair.tickWidth, nvdaPair.baseLiqUnit, nvdaPair.feePerSecond, false);

        // tip/cur/end/amountLeft/head ticks cleared, ts + bookId retained
        (uint40 tip, uint32 ts, uint40 bookId, uint8 cur, uint8 end, uint96 left, uint8[68] memory ticks) = hyfi.getBookSide(nvdaPair.id, true);
        assertEq(tip, 0, "tip cleared");
        assertEq(cur, 0, "cur cleared");
        assertEq(end, 0, "end cleared");
        assertEq(left, 0, "amountLeft cleared");
        assertEq(ticks[0], 0, "head tick cleared");
        assertEq(ts, uint32(block.timestamp), "timestamp retained");
        assertEq(bookId, bookIdBefore, "bookId retained");

        // dirty word slots are untouched (unreachable but non-zero)
        (, uint wordA, uint wordB) = hyfi.getBookSideRaw(nvdaPair.id, true);
        assertEq(wordA, wordABefore, "wordA left dirty");
        assertEq(wordB, wordBBefore, "wordB left dirty");
    }

    function test_setPairConfig_tradesRevertUntilNextUpdate() public {
        vm.prank(owner);
        hyfi.setPairConfig(nvdaPair.key, nvdaPair.tickWidth, nvdaPair.baseLiqUnit, nvdaPair.feePerSecond, false);

        vm.expectRevert(hookRevert(address(hyfi), IHooks.beforeSwap.selector, HyFi.InsufficientLiquidity.selector));
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.1e18, 0);

        // next update (with a still-increasing bookId) restores trading
        _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, DEFAULT_TICKS, DEFAULT_TICKS, uint32(block.timestamp));
        uint before = usdg.balanceOf(trader);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.2e18, 0);
        assertEq(usdg.balanceOf(trader) - before, 36_000_000, "0.2 NVDA @ $180.00 = 36 USDG");
    }

    function test_setPairConfig_RevertWhen_notOwner() public {
        vm.prank(updater);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, updater));
        hyfi.setPairConfig(nvdaPair.key, 1, 1, 0, false);
    }

    function test_setPairConfig_RevertWhen_hookNotSelf() public {
        PoolKey memory key = nvdaPair.key;
        key.hooks = IHooks(address(0xdead));
        vm.prank(owner);
        vm.expectRevert(HyFi.InvalidPoolKey.selector);
        hyfi.setPairConfig(key, 1, 1, 0, false);
    }

    function test_setPairConfig_RevertWhen_zeroTickWidth() public {
        vm.prank(owner);
        vm.expectRevert(HyFi.InvalidConfig.selector);
        hyfi.setPairConfig(nvdaPair.key, 0, 1, 0, false);
    }

    function test_setPairConfig_RevertWhen_zeroBaseLiqUnit() public {
        vm.prank(owner);
        vm.expectRevert(HyFi.InvalidConfig.selector);
        hyfi.setPairConfig(nvdaPair.key, 1, 0, 0, false);
    }
}
