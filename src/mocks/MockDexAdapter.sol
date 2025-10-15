// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IDexAdapter} from "../interfaces/IDexAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract MockDexAdapter is IDexAdapter {
    uint256 public feeBps = 30; // 0.3% as in univ2
    uint256 public outBps = 10000; // relative to minOut passed in

    function setFeeBps(uint256 bps) external { feeBps = bps; }
    function setOutBps(uint256 bps) external { outBps = bps; }

    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut
    ) external override returns (uint256 filledAmountIn, uint256 receivedAmountOut, uint256 fee) {
        // Pull tokenIn from caller (vault)
        require(IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn), "PULL");

        // Compute outputs relative to minOut to be deterministic for tests
        filledAmountIn = amountIn;
        // We consider execution is done at worst price (minOut) for simplicity (receivedAmountOut=minOut)
        receivedAmountOut = (minOut * outBps) / 10_000;
        fee = (amountIn * feeBps) / 10_000;

        // Mint tokenOut to caller vault
        ERC20Mock(tokenOut).mint(msg.sender, receivedAmountOut);
    }
}
