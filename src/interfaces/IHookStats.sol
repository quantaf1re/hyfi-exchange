// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.36;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @notice URC-3: TVL and effective-liquidity reporting for Uniswap v4 hooks.
/// @dev https://github.com/Uniswap/URCs/blob/main/URCs/urc-3.md
interface IHookStats is IERC165 {
    /// @notice Total reserves managed by the hook for the given pool.
    /// @dev Should include all assets under management that correspond to token0/token1.
    ///      For invalid pool keys, should revert with a descriptive error.
    function getReserves(PoolKey calldata key) external view returns (uint256 token0, uint256 token1);

    /// @notice Liquidity available for immediate swapping.
    /// @dev Should be less than or equal to getReserves() for each token.
    ///      For invalid pool keys, should revert with a descriptive error.
    function getEffectiveLiquidity(PoolKey calldata key) external view returns (uint256 token0, uint256 token1);

    /// @notice The hook whose stats this contract reports.
    /// @dev Returns the contract's own address when the hook implements the interface directly.
    function hook() external view returns (address);
}
