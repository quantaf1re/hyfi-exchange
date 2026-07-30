// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract HyFiHookGetBookSideRawTest is HyFiSetup {
    function test_getBookSideRaw_returnsExactPackedWords() public {
        uint8[] memory ticks = ticksFill(68, 3);
        uint40 bookId = _updateBookAt(nvdaPair, 18500, 18501, ticks, ticks, uint32(block.timestamp));

        (uint32 head, uint expectedA, uint expectedB) = packTicks(ticks);
        (uint slot0, uint wordA, uint wordB) = hyfi.getBookSideRaw(nvdaPair.id, true);
        assertEq(slot0, packSlot0(18500, uint32(block.timestamp), bookId, 0, 67, 0, head), "bid slot0");
        assertEq(wordA, expectedA, "bid wordA");
        assertEq(wordB, expectedB, "bid wordB");

        (uint askSlot0,,) = hyfi.getBookSideRaw(nvdaPair.id, false);
        assertEq(askSlot0, packSlot0(18501, uint32(block.timestamp), bookId, 0, 67, 0, head), "ask slot0");
    }

    function test_getBookSideRaw_swapOnlyChangesCurAndAmountLeftBits() public {
        (uint slot0Before, uint wordABefore, uint wordBBefore) = hyfi.getBookSideRaw(nvdaPair.id, true);
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.35e18, 0);
        (uint slot0After, uint wordAAfter, uint wordBAfter) = hyfi.getBookSideRaw(nvdaPair.id, true);

        // reconstruct: same slot0 with cur = 1 and amountLeft = 1.5e17 spliced in
        uint expected = (slot0Before & ~((uint(0xFF) << 112) | (uint(type(uint96).max) << 128)))
            | (uint(1) << 112) | (uint(1.5e17) << 128);
        assertEq(slot0After, expected, "only cur/amountLeft bits changed");
        assertEq(wordAAfter, wordABefore, "wordA untouched by swap");
        assertEq(wordBAfter, wordBBefore, "wordB untouched by swap");
    }

    function test_getBookSideRaw_unknownPoolIsZero() public view {
        (uint slot0, uint wordA, uint wordB) = hyfi.getBookSideRaw(PoolId.wrap(bytes32(uint(123))), true);
        assertEq(slot0, 0, "slot0 zero");
        assertEq(wordA, 0, "wordA zero");
        assertEq(wordB, 0, "wordB zero");
    }
}
