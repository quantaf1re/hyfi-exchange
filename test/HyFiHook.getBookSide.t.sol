// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract HyFiHookGetBookSideTest is HyFiSetup {
    function test_getBookSide_decodesAllFieldsExactly() public {
        uint8[] memory bidTicks = ticksFill(40, 0);
        for (uint i; i < 40; ++i) {
            bidTicks[i] = uint8(i + 1); // distinct values across head, wordA and wordB regions
        }
        uint40 bookId = _updateBookAt(nvdaPair, 19000, 19001, bidTicks, ticksArr(7), uint32(block.timestamp));

        (uint40 tip, uint32 ts, uint40 id, uint8 cur, uint8 end, uint96 left, uint8[68] memory ticks) =
            hyfi.getBookSide(nvdaPair.id, true);
        
        assertEq(tip, 19000, "tip");
        assertEq(ts, uint32(block.timestamp), "timestamp");
        assertEq(id, bookId, "bookId");
        assertEq(cur, 0, "cur");
        assertEq(end, 39, "end");
        assertEq(left, 0, "amountLeft");
        for (uint i; i < 40; ++i) {
            assertEq(ticks[i], uint8(i + 1), "tick value");
        }
        for (uint i = 40; i < 68; ++i) {
            assertEq(ticks[i], 0, "past-end ticks (never written) read zero");
        }
    }

    function test_getBookSide_sidesAreIndependent() public view {
        (uint40 bidTip,,,,,,) = hyfi.getBookSide(nvdaPair.id, true);
        (uint40 askTip,,,,,,) = hyfi.getBookSide(nvdaPair.id, false);

        assertEq(bidTip, nvdaPair.bidTip, "bid side");
        assertEq(askTip, nvdaPair.askTip, "ask side");
    }

    function test_getBookSide_reflectsPointerAfterSwap() public {
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.35e18, 0);
        (uint40 tip,,, uint8 cur, uint8 end, uint96 left, uint8[68] memory ticks) =
            hyfi.getBookSide(nvdaPair.id, true);

        assertEq(cur, 1, "cur updated");
        assertEq(left, 1.5e17, "amountLeft updated");
        // unchanged by the swap: tip, endTick and the tick values themselves
        assertEq(tip, nvdaPair.bidTip, "tip unchanged");
        assertEq(end, 2, "end unchanged");
        assertEq(ticks[0], 2, "consumed tick value not zeroed");
        assertEq(ticks[1], 3, "partially consumed tick value not zeroed");
    }

    function test_getBookSide_unknownPoolReturnsZeroes() public view {
        (uint40 tip, uint32 ts, uint40 id, uint8 cur, uint8 end, uint96 left,) =
            hyfi.getBookSide(PoolId.wrap(bytes32(uint(999))), true); // never configured or updated
        assertEq(tip, 0, "tip");
        assertEq(ts, 0, "timestamp");
        assertEq(id, 0, "bookId");
        assertEq(cur, 0, "cur");
        assertEq(end, 0, "end");
        assertEq(left, 0, "amountLeft");
    }
}
