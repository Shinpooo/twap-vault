// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {IOracle} from "../interfaces/IOracle.sol";

contract MockOracle is IOracle {
    // Base mid price around which jitter is applied
    uint256 public basePrice;
    // Max absolute jitter in bps
    uint16 public varianceBps;

    constructor(uint256 _basePrice, uint16 _varianceBps) {
        basePrice = _basePrice;
        varianceBps = _varianceBps;
    }

    function setBasePrice(uint256 _price) external {
        basePrice = _price;
    }

    function setVarianceBps(uint16 _bps) external {
        varianceBps = _bps;
    }

    function getPrice(address tokenIn, address tokenOut) external view override returns (uint256) {
        uint16 vb = varianceBps;
        if (vb == 0) return basePrice;
        // Pseudo-random jitter in [-vb, +vb] bps
        uint256 span = uint256(vb) * 2 + 1;
        uint256 r = uint256(keccak256(abi.encodePacked(block.number, block.timestamp, tokenIn, tokenOut))) % span;
        int256 deltaBps = int256(uint256(vb)) - int256(r); // maps r in [0..2vb] to delta in [vb..-vb]
        // Apply jitter: price * (10000 + deltaBps) / 10000
        int256 num = int256(basePrice) * (10000 + deltaBps);
        return uint256(num / 10000);
    }
}
