// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";

contract HyFiHookUpdateBooksTest is HyFiSetup {
    function test_updateBooks_writesExactSlot0AndLeavesUntouchedWordsAlone() public {
        uint8[] memory bidTicks = ticksArr(5, 6, 7);
        uint8[] memory askTicks = ticksArr(8, 9);
        uint40 bookId = _updateBookAt(nvdaPair, 18010, 18011, bidTicks, askTicks, uint32(block.timestamp));

        (uint32 headBid,,) = packTicks(bidTicks);
        (uint slot0, uint wordA, uint wordB) = hyfi.getBookSideRaw(nvdaPair.id, true);
        assertEq(slot0, packSlot0(18010, uint32(block.timestamp), bookId, 0, 2, 0, headBid), "bid slot0 exact");
        assertEq(wordA, 0, "bid wordA never written (end < 4)");
        assertEq(wordB, 0, "bid wordB never written");

        (uint32 headAsk,,) = packTicks(askTicks);
        (uint askSlot0,,) = hyfi.getBookSideRaw(nvdaPair.id, false);
        assertEq(askSlot0, packSlot0(18011, uint32(block.timestamp), bookId, 0, 1, 0, headAsk), "ask slot0 exact");
    }

    function test_updateBooks_fullBook_writesBothWordsExactly() public {
        uint8[] memory full = ticksFill(68, 7);
        uint40 bookId = _updateBookAt(nvdaPair, 18000, 18001, full, full, uint32(block.timestamp));

        (uint32 head, uint expectedA, uint expectedB) = packTicks(full);
        (uint slot0, uint wordA, uint wordB) = hyfi.getBookSideRaw(nvdaPair.id, true);
        assertEq(slot0, packSlot0(18000, uint32(block.timestamp), bookId, 0, 67, 0, head), "slot0 exact");
        assertEq(wordA, expectedA, "wordA exact");
        assertEq(wordB, expectedB, "wordB exact");
    }

    function test_updateBooks_shortBook_leavesStaleWordsDirty() public {
        uint8[] memory long = ticksFill(40, 9); // end = 39: writes wordA and wordB
        _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, long, long, uint32(block.timestamp));
        (, uint wordAAfterLong, uint wordBAfterLong) = hyfi.getBookSideRaw(nvdaPair.id, true);
        (, uint expectedA, uint expectedB) = packTicks(long);
        assertEq(wordAAfterLong, expectedA, "precondition: wordA written");
        assertEq(wordBAfterLong, expectedB, "precondition: wordB written");

        uint8[] memory short = ticksArr(1, 2, 3); // end = 2: writes only slot0
        uint40 bookId = _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, short, short, uint32(block.timestamp));

        (uint32 head,,) = packTicks(short);
        (uint slot0, uint wordA, uint wordB) = hyfi.getBookSideRaw(nvdaPair.id, true);
        assertEq(slot0, packSlot0(nvdaPair.bidTip, uint32(block.timestamp), bookId, 0, 2, 0, head), "slot0 replaced");
        assertEq(wordA, expectedA, "stale wordA left dirty (unreachable past endTick)");
        assertEq(wordB, expectedB, "stale wordB left dirty");
    }

    function test_updateBooks_midBook_overwritesWordAOnly() public {
        uint8[] memory long = ticksFill(40, 9);
        _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, long, long, uint32(block.timestamp));
        (,, uint wordBLong) = hyfi.getBookSideRaw(nvdaPair.id, true);

        uint8[] memory mid = ticksFill(10, 4); // end = 9: writes slot0 + wordA, not wordB
        _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, mid, mid, uint32(block.timestamp));

        (, uint expectedA,) = packTicks(mid);
        (, uint wordA, uint wordB) = hyfi.getBookSideRaw(nvdaPair.id, true);
        assertEq(wordA, expectedA, "wordA overwritten");
        assertEq(wordB, wordBLong, "wordB left dirty");
    }

    function test_updateBooks_resetsPointerAfterTrade() public {
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.35e18, 0); // leaves cur = 1, amountLeft = 1.5e17
        (,,, uint8 cur,, uint96 left,) = hyfi.getBookSide(nvdaPair.id, true);
        assertEq(cur, 1, "precondition cur");
        assertEq(left, 1.5e17, "precondition amountLeft");

        _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, DEFAULT_TICKS, DEFAULT_TICKS, uint32(block.timestamp));
        (,,, cur,, left,) = hyfi.getBookSide(nvdaPair.id, true);
        assertEq(cur, 0, "cur reset");
        assertEq(left, 0, "amountLeft reset");
    }

    function test_updateBooks_batch_updatesMultiplePairsAtOnce() public {
        HyFi.PairUpdate[] memory updates = new HyFi.PairUpdate[](2);
        uint40 bookId = ++bookIdCounter;
        updates[0] = HyFi.PairUpdate(nvdaPair.id, bookId, sideUpdate(18100, ticksArr(1)), sideUpdate(18101, ticksArr(1)));
        updates[1] = HyFi.PairUpdate(tokPair.id, bookId, sideUpdate(5100, ticksArr(2)), sideUpdate(5101, ticksArr(2)));
        vm.prank(updater);
        hyfi.updateBooks(updates, uint32(block.timestamp));

        (uint40 nvdaTip,, uint40 nvdaBookId,,,,) = hyfi.getBookSide(nvdaPair.id, true);
        (uint40 tokTip,, uint40 tokBookId,,,,) = hyfi.getBookSide(tokPair.id, true);
        assertEq(nvdaTip, 18100, "pair 1 updated");
        assertEq(tokTip, 5100, "pair 2 updated");
        assertEq(nvdaBookId, bookId, "pair 1 bookId");
        assertEq(tokBookId, bookId, "pair 2 bookId");

        // unchanged: pair not in the batch
        (uint40 ethTip,,,,,,) = hyfi.getBookSide(ethPair.id, true);
        assertEq(ethTip, ethPair.bidTip, "unrelated pair untouched");
    }

    function test_updateBooks_sameTimestampReplacementAllowed() public {
        // two updates in the same second: allowed, provided bookId increases
        _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, ticksArr(1), ticksArr(1), uint32(block.timestamp));
        uint40 second = _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, ticksArr(9), ticksArr(9), uint32(block.timestamp));
        (,, uint40 bookId,,,, uint8[68] memory ticks) = hyfi.getBookSide(nvdaPair.id, true);
        assertEq(bookId, second, "replacement applied");
        assertEq(ticks[0], 9, "replacement ticks live");
    }

    function test_updateBooks_RevertWhen_notUpdater() public {
        HyFi.PairUpdate[] memory updates =
            pairUpdate(nvdaPair.id, ++bookIdCounter, sideUpdate(18000, ticksArr(1)), sideUpdate(18001, ticksArr(1)));
        vm.prank(owner); // even the owner is not the updater
        vm.expectRevert(HyFi.NotUpdater.selector);
        hyfi.updateBooks(updates, uint32(block.timestamp));
    }

    function test_updateBooks_RevertWhen_futureTimestamp() public {
        HyFi.PairUpdate[] memory updates =
            pairUpdate(nvdaPair.id, ++bookIdCounter, sideUpdate(18000, ticksArr(1)), sideUpdate(18001, ticksArr(1)));
        vm.prank(updater);
        vm.expectRevert(HyFi.FutureTimestamp.selector);
        hyfi.updateBooks(updates, uint32(block.timestamp + 1));
    }

    function test_updateBooks_RevertWhen_timestampOlderThanStored() public {
        HyFi.PairUpdate[] memory updates =
            pairUpdate(nvdaPair.id, ++bookIdCounter, sideUpdate(18000, ticksArr(1)), sideUpdate(18001, ticksArr(1)));
        vm.prank(updater);
        vm.expectRevert(HyFi.StaleUpdate.selector);
        hyfi.updateBooks(updates, uint32(block.timestamp - 1));
    }

    function test_updateBooks_RevertWhen_bookIdNotIncreasing() public {
        uint40 current = _bookId(nvdaPair.id); // stored bookId for nvdaPair after setUp
        HyFi.PairUpdate[] memory updates = pairUpdate(nvdaPair.id, current, sideUpdate(18000, ticksArr(1)), sideUpdate(18001, ticksArr(1)));
        vm.prank(updater);
        vm.expectRevert(HyFi.StaleBookId.selector);
        hyfi.updateBooks(updates, uint32(block.timestamp));
    }

    function test_updateBooks_RevertWhen_endTickPastCapacity() public {
        HyFi.SideUpdate memory bad = sideUpdate(18000, ticksArr(1));
        bad.endTick = 68; // capacity is 0..67
        HyFi.PairUpdate[] memory updates = pairUpdate(nvdaPair.id, ++bookIdCounter, bad, sideUpdate(18001, ticksArr(1)));
        vm.prank(updater);
        vm.expectRevert(HyFi.InvalidEndTick.selector);
        hyfi.updateBooks(updates, uint32(block.timestamp));
    }

    function test_updateBooks_RevertWhen_bidTipNotAboveEndTick() public {
        // 3 ticks => endTick 2; a bid tip of 2 would price the last tick at zero
        HyFi.PairUpdate[] memory updates = pairUpdate(nvdaPair.id, ++bookIdCounter, sideUpdate(2, ticksArr(1, 1, 1)), sideUpdate(18001, ticksArr(1)));
        vm.prank(updater);
        vm.expectRevert(HyFi.InvalidTipPrice.selector);
        hyfi.updateBooks(updates, uint32(block.timestamp));
    }

    function test_updateBooks_RevertWhen_askTipZero() public {
        HyFi.PairUpdate[] memory updates = pairUpdate(nvdaPair.id, ++bookIdCounter, sideUpdate(18000, ticksArr(1)), sideUpdate(0, ticksArr(1)));
        vm.prank(updater);
        vm.expectRevert(HyFi.InvalidTipPrice.selector);
        hyfi.updateBooks(updates, uint32(block.timestamp));
    }
}
