// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title DEX Adapter Interface
/// @notice Minimal adapter used by the TWAP vault to execute swaps on a DEX/venue.
interface IDexAdapter {
    /// @notice Execute a swap from tokenIn to tokenOut, honoring a minimum output amount.
    /// @param tokenIn The ERC20 to sell.
    /// @param tokenOut The ERC20 to buy.
    /// @param amountIn The input amount to attempt to fill (18 decimals assumed by the vault).
    /// @param minOut The minimum acceptable output amount. The adapter MUST respect this guard.
    /// @return filledAmountIn The actual input consumed by the adapter.
    /// @return receivedAmountOut The actual output received by the vault.
    /// @return fee Any venue fee charged for this swap (units are implementation‑defined).
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut
    ) external returns (uint256 filledAmountIn, uint256 receivedAmountOut, uint256 fee);
}

