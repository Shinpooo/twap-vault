// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Price Oracle Interface
/// @notice Minimal oracle returning a price quote used for slippage and deviation checks.
interface IOracle {
    /// @notice Return the price of tokenIn denominated in tokenOut.
    /// @dev Vault assumes 18‑decimals fixed point (1e18) for price scaling.
    /// @param tokenIn The base token (numerator amount).
    /// @param tokenOut The quote token (denominator amount).
    /// @return price The price as tokenOut per 1 tokenIn, scaled by 1e18.
    function getPrice(address tokenIn, address tokenOut) external returns (uint256 price);
}

