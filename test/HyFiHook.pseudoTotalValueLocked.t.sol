// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {HyFiSetup} from "./HyFiSetup.sol";
import {HyFi} from "../src/HyFi.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @dev pseudoTotalValueLocked reports the liquidity currently posted in the book for a single
/// pair: the ask side's remaining base capacity, and the bid side's remaining capacity valued in
/// the quote token, ordered as (amount0, amount1). It is derived from the book, not the hook's
/// (shared) token balances.
contract HyFiHookPseudoTVLTest is HyFiSetup {
    /// @dev Independent oracle mirroring the contract: reads the live book via getBookSide and
    /// re-derives (amount0, amount1) from remaining ticks (honoring the walk pointer/amountLeft).
    /// Split per side to keep each stack frame small.
    function _remBase(PoolId id, uint liqUnit) internal view returns (uint baseWei) {
        (,,, uint8 cur, uint8 end, uint96 left, uint8[68] memory ticks) = hyfi.getBookSide(id, false); // ask
        for (uint i = cur; i <= end; ++i) {
            baseWei += (i == cur && left != 0) ? left : uint(ticks[i]) * liqUnit;
        }
    }

    function _remQuote(Pair memory p) internal view returns (uint quoteWei) {
        (uint40 tip,,, uint8 cur, uint8 end, uint96 left, uint8[68] memory ticks) = hyfi.getBookSide(p.id, true); // bid
        for (uint i = cur; i <= end; ++i) {
            uint avail = (i == cur && left != 0) ? left : uint(ticks[i]) * p.baseLiqUnit;
            if (avail != 0) quoteWei += baseToQuote(avail, tickPrice(tip, i, true, p.tickWidth), false);
        }
    }

    function _tvlFromChain(Pair memory p) internal view returns (uint amount0, uint amount1) {
        uint baseAmt = _remBase(p.id, p.baseLiqUnit);
        uint quoteAmt = _remQuote(p);
        (amount0, amount1) = p.baseIsCurrency0 ? (baseAmt, quoteAmt) : (quoteAmt, baseAmt);
    }

    function _assertTVL(Pair memory p) internal view {
        (uint a0, uint a1) = hyfi.pseudoTotalValueLocked(p.id);
        (uint e0, uint e1) = _tvlFromChain(p);
        assertEq(a0, e0, "amount0 matches book");
        assertEq(a1, e1, "amount1 matches book");
    }

    function test_pseudoTVL_freshBook_nvdaPair() public view {
        // base = NVDA (currency1). ask base = 6 x 0.1 NVDA = 0.6 NVDA. bid value =
        // 36 + 53.997 + 17.998 = 107.995 USDG. baseIsCurrency0 = false => (quote, base).
        (uint a0, uint a1) = hyfi.pseudoTotalValueLocked(nvdaPair.id);
        assertEq(a0, 107_995_000, "amount0 = USDG bid value");
        assertEq(a1, 0.6e18, "amount1 = NVDA ask capacity");
        _assertTVL(nvdaPair);
    }

    function test_pseudoTVL_freshBook_tokPair() public view {
        // base = TOKA (currency0). ask base = 6 x 10 TOKA = 60 TOKA. bid value =
        // 1000 + 1499.7 + 499.8 = 2999.5 TOKB. baseIsCurrency0 = true => (base, quote).
        (uint a0, uint a1) = hyfi.pseudoTotalValueLocked(tokPair.id);
        assertEq(a0, 60e6, "amount0 = TOKA ask capacity");
        assertEq(a1, 2_999.5e18, "amount1 = TOKB bid value");
        _assertTVL(tokPair);
    }

    function test_pseudoTVL_freshBook_ethPair() public view {
        // base = native (currency0). ask base = 0.6 ETH. bid value =
        // 600 + 899.997 + 299.998 = 1799.995 USDG.
        (uint a0, uint a1) = hyfi.pseudoTotalValueLocked(ethPair.id);
        assertEq(a0, 0.6e18, "amount0 = ETH ask capacity");
        assertEq(a1, 1_799_995_000, "amount1 = USDG bid value");
        _assertTVL(ethPair);
    }

    function test_pseudoTVL_shrinksAfterBidSideConsumed() public {
        (uint a0Before, uint a1Before) = hyfi.pseudoTotalValueLocked(nvdaPair.id);

        // sell 0.2 NVDA: drains bid tick0 (36 USDG of value) exactly
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.2e18, 0);

        (uint a0After, uint a1After) = hyfi.pseudoTotalValueLocked(nvdaPair.id);
        assertEq(a0Before - a0After, 36_000_000, "bid value dropped by consumed tick");
        // ask side (amount1) unchanged by a bid-side trade
        assertEq(a1After, a1Before, "ask capacity unchanged");
        _assertTVL(nvdaPair);
    }

    function test_pseudoTVL_partialTick_honorsAmountLeft() public {
        // sell 0.35 NVDA: leaves bid tick 1 partially filled (0.15 of 0.3 NVDA remaining)
        swapExactInAs(router, nvdaPair.key, nvdaPair.baseIsCurrency0, trader, true, 0.35e18, 0);
        // the oracle reproduces the amountLeft branch exactly
        _assertTVL(nvdaPair);
    }

    function test_pseudoTVL_deepBook_spansAllWords() public {
        // 40 ticks per side reach past the slot0 head (ticks 0-3) through wordA (4-35) into
        // wordB (36-39), exercising every tick-word read.
        uint8[] memory deep = ticksFill(40, 1); // 40 x 0.1 NVDA
        _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, deep, deep, uint32(block.timestamp));
        (, uint a1) = hyfi.pseudoTotalValueLocked(nvdaPair.id);
        assertEq(a1, 4e18, "ask capacity = 40 x 0.1 NVDA");
        _assertTVL(nvdaPair);
    }

    function test_pseudoTVL_unconfiguredPair_returnsZero() public view {
        (uint a0, uint a1) = hyfi.pseudoTotalValueLocked(PoolId.wrap(bytes32(uint(1))));
        assertEq(a0, 0, "amount0 zero");
        assertEq(a1, 0, "amount1 zero");
    }
}
