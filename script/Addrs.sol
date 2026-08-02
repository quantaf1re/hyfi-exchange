// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

/// @notice Maps chainId + contract/token name to its address on that chain, so tests and
/// scripts can resolve addresses from just a name and `block.chainid`. Kept dependency-free;
/// typed wrappers (getPm, getERC20, ...) live in test/Utils.sol where the interfaces are.
library Addrs {
    error UnknownAddress(uint chainId, string name);

    uint internal constant ROBINHOOD = 4663;

    function get(uint chainId, string memory name) internal pure returns (address) {
        bytes32 h = keccak256(bytes(name));
        if (chainId == ROBINHOOD) {
            if (h == keccak256("PoolManager")) return 0x8366a39CC670B4001A1121B8F6A443A643e40951;
            if (h == keccak256("PositionManager")) return 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
            if (h == keccak256("UniversalRouter")) return 0x8876789976dEcBfCbBbe364623C63652db8C0904;
            if (h == keccak256("Permit2")) return 0x000000000022D473030F116dDEE9F6B43aC78BA3;
            if (h == keccak256("USDG")) return 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
            if (h == keccak256("NVDA")) return 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
            if (h == keccak256("HyFi")) return 0xE06495094a44987833219A48B175C5c30D426088;
        }
        revert UnknownAddress(chainId, name);
    }
}
