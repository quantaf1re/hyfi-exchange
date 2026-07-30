// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import {Test} from "forge-std/Test.sol";
import {HyFi} from "../src/HyFi.sol";
import {Utils, IUniversalRouterMinimal, IPermit2Minimal} from "./Utils.sol";
import {TestToken} from "./mocks/TestToken.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Shared fork-test fixture. Deploys the hook at a mined address, configures three pairs
/// with very different decimals/orderings, initializes their pools, funds an MM + trader, seeds
/// deposits and pushes an initial book for each pair.
///
/// Run with: forge test --fork-url robin --fork-block-number 19910000
abstract contract HyFiSetup is Test, Utils {
    struct Pair {
        PoolKey key;
        PoolId id;
        Currency base;
        Currency quote;
        bool baseIsCurrency0;
        uint128 tickWidth;
        uint88 baseLiqUnit;
        uint24 feePerSecond;
        uint40 bidTip;
        uint40 askTip;
    }

    HyFi internal hyfi;
    IPoolManager internal pm = getPm(block.chainid);
    IUniversalRouterMinimal internal router = getRouter(block.chainid);
    IPermit2Minimal internal permit2 = getPermit2(block.chainid);

    address internal owner = makeAddr("owner");
    address internal updater = makeAddr("updater");
    address internal withdrawer = makeAddr("withdrawer");
    address internal mm = makeAddr("mm");
    address internal trader = makeAddr("trader");

    // Pair 1: NVDA (18 dec) / USDG (6 dec), base is currency1 (USDG address < NVDA address)
    Pair internal nvdaPair;
    // Pair 2: TOKA (6 dec) / TOKB (18 dec), base forced to currency0 - big inverse decimal gap
    Pair internal tokPair;
    // Pair 3: native ETH / USDG, base is currency0 (native = address(0))
    Pair internal ethPair;

    IERC20 internal usdg = getERC20(block.chainid, "USDG");
    IERC20 internal nvda = getERC20(block.chainid, "NVDA");
    TestToken internal toka;
    TestToken internal tokb;

    uint40 internal bookIdCounter;
    mapping(PoolId => uint40) internal lastBookId;
    uint8[] internal DEFAULT_TICKS = ticksArr(2, 3, 1);

    function setUp() public virtual {
        vm.label(address(pm), "PoolManager");
        vm.label(address(router), "UniversalRouter");
        vm.label(address(usdg), "USDG");
        vm.label(address(nvda), "NVDA");

        // Deploy the hook at a mined address carrying exactly the required flag bits
        bytes memory creation = abi.encodePacked(type(HyFi).creationCode, abi.encode(pm, owner, updater, withdrawer));
        (bytes32 salt,) = mineHookSalt(address(this), creation);
        hyfi = new HyFi{salt: salt}(pm, owner, updater, withdrawer);
        vm.label(address(hyfi), "HyFi");

        // TOKA (6 dec base) forced to a lower address than TOKB (18 dec quote) => baseIsCurrency0
        toka = new TestToken("Token A", "TOKA", 6);
        tokb = _deployTokbAbove(address(toka));

        // --- pair configs ---------------------------------------------------
        // NVDA/USDG: $0.01 ticks, 0.1 NVDA per liquidity unit, ~$180
        nvdaPair = _configurePair(
            Currency.wrap(address(nvda)),
            Currency.wrap(address(usdg)),
            calcTickWidth(10 ** 4, 18), // $0.01 in USDG wei per whole NVDA => 1e10
            uint88(1e17), // 0.1 NVDA
            100, // 100 pips/second staleness fee
            18000, // bid tip $180.00
            18001 // ask tip $180.01
        );
        // TOKA/TOKB: $0.01 ticks (in 18-dec TOKB), 10 TOKA per unit, ~$50
        tokPair = _configurePair(
            Currency.wrap(address(toka)),
            Currency.wrap(address(tokb)),
            calcTickWidth(10 ** 16, 6), // 0.01 TOKB per whole TOKA => 1e34
            uint88(10 * 1e6), // 10 TOKA
            100,
            5000, // bid tip $50.00
            5001 // ask tip $50.01
        );
        // ETH/USDG: $0.01 ticks, 0.1 ETH per unit, ~$3000
        ethPair = _configurePair(
            Currency.wrap(address(0)),
            Currency.wrap(address(usdg)),
            calcTickWidth(10 ** 4, 18), // 1e10
            uint88(1e17), // 0.1 ETH
            100,
            300000, // bid tip $3000.00
            300001 // ask tip $3000.01
        );

        // --- fund MM and deposit hook liquidity ------------------------------
        deal(address(usdg), mm, 10_000_000e6);
        deal(address(nvda), mm, 100_000e18);
        toka.mint(mm, 10_000_000e6);
        tokb.mint(mm, 10_000_000e18);
        vm.deal(mm, 10_000 ether);

        depositAs(hyfi, mm, Currency.wrap(address(usdg)), 5_000_000e6);
        depositAs(hyfi, mm, Currency.wrap(address(nvda)), 50_000e18);
        depositAs(hyfi, mm, Currency.wrap(address(toka)), 5_000_000e6);
        depositAs(hyfi, mm, Currency.wrap(address(tokb)), 5_000_000e18);
        depositAs(hyfi, mm, Currency.wrap(address(0)), 5_000 ether);

        // --- fund trader and set router approvals ----------------------------
        deal(address(usdg), trader, 1_000_000e6);
        deal(address(nvda), trader, 10_000e18);
        toka.mint(trader, 1_000_000e6);
        tokb.mint(trader, 1_000_000e18);
        vm.deal(trader, 1_000 ether);
        approveRouterAs(permit2, address(router), trader, address(usdg));
        approveRouterAs(permit2, address(router), trader, address(nvda));
        approveRouterAs(permit2, address(router), trader, address(toka));
        approveRouterAs(permit2, address(router), trader, address(tokb));

        // --- initial books ----------------------------------------------------
        _updateBookAt(nvdaPair, nvdaPair.bidTip, nvdaPair.askTip, DEFAULT_TICKS, DEFAULT_TICKS, uint32(block.timestamp));
        _updateBookAt(tokPair, tokPair.bidTip, tokPair.askTip, DEFAULT_TICKS, DEFAULT_TICKS, uint32(block.timestamp));
        _updateBookAt(ethPair, ethPair.bidTip, ethPair.askTip, DEFAULT_TICKS, DEFAULT_TICKS, uint32(block.timestamp));
    }

    // ------------------------------------------------------------------
    // Fixture helpers
    // ------------------------------------------------------------------

    /// @dev Deploys TOKB at an address strictly greater than `below` so TOKA is currency0
    function _deployTokbAbove(address below) internal returns (TestToken t) {
        for (uint i;; ++i) {
            bytes32 salt = keccak256(abi.encode("TOKB", i));
            address predicted = vm.computeCreate2Address(
                salt, keccak256(abi.encodePacked(type(TestToken).creationCode, abi.encode("Token B", "TOKB", uint8(18))))
            );
            if (predicted > below) {
                t = new TestToken{salt: salt}("Token B", "TOKB", 18);
                return t;
            }
        }
    }

    function _configurePair(
        Currency base,
        Currency quote,
        uint128 tickWidth,
        uint88 baseLiqUnit,
        uint24 feePerSecond,
        uint40 bidTip,
        uint40 askTip
    ) internal returns (Pair memory p) {
        (PoolKey memory key, bool baseIsCurrency0) = poolKeyFor(Currency.unwrap(base), Currency.unwrap(quote), address(hyfi));
        p = Pair({
            key: key,
            id: key.toId(),
            base: base,
            quote: quote,
            baseIsCurrency0: baseIsCurrency0,
            tickWidth: tickWidth,
            baseLiqUnit: baseLiqUnit,
            feePerSecond: feePerSecond,
            bidTip: bidTip,
            askTip: askTip
        });
        vm.prank(owner);
        hyfi.setPairConfig(key, tickWidth, baseLiqUnit, feePerSecond, baseIsCurrency0);
        pm.initialize(key, SQRT_PRICE_1_1);
    }

    /// @dev Pushes a book for `p`, tracking a fresh strictly-increasing bookId per pair
    function _updateBookAt(
        Pair memory p,
        uint40 bidTip,
        uint40 askTip,
        uint8[] memory bidTicks,
        uint8[] memory askTicks,
        uint32 ts
    ) internal returns (uint40 bookId) {
        bookId = ++bookIdCounter;
        updateBookAs(hyfi, updater, p.id, bookId, bidTip, askTip, bidTicks, askTicks, ts);
        lastBookId[p.id] = bookId;
    }

    /// @dev The bookId most recently pushed for a pair by the fixture helpers
    function _bookId(PoolId id) internal view returns (uint40) {
        return lastBookId[id];
    }
}
