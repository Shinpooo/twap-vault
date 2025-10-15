// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

contract MockOracleTest is Test {
    MockOracle oracle;

    function setUp() public {
        // Base price 1.0, variance 1% (±100 bps)
        oracle = new MockOracle(1e18, 100);
    }

    function test_NoVarianceReturnsBasePrice() public {
        oracle.setVarianceBps(0);
        // Move time/blocks to ensure any dependency wouldn't matter
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1);
        uint256 p = oracle.getPrice(address(0xA), address(0xB));
        assertEq(p, 1e18, "price should equal base when variance=0");
    }

    function test_VarianceWithinBoundsAndNonDegenerate() public {
        uint256 base = 1e18;
        uint16 vb = 100; // ±1%
        oracle.setBasePrice(base);
        oracle.setVarianceBps(vb);

        uint256 lower = (base * (10_000 - vb)) / 10_000;
        uint256 upper = (base * (10_000 + vb)) / 10_000;

        bool seenBelow = false;
        bool seenAbove = false;

        address tokenIn = address(0xA11CE);
        address tokenOut = address(0xB0B);

        // Sample across multiple blocks/timestamps to exercise randomness
        for (uint256 i = 0; i < 64; i++) {
            vm.roll(block.number + 1);
            vm.warp(block.timestamp + 1);
            uint256 p = oracle.getPrice(tokenIn, tokenOut);
            assertGe(p, lower, "price below lower bound");
            assertLe(p, upper, "price above upper bound");
            if (p < base) seenBelow = true;
            if (p > base) seenAbove = true;
        }

        // With enough samples, expect to have seen both sides of base
        assertTrue(seenBelow, "expected at least one sample below base");
        assertTrue(seenAbove, "expected at least one sample above base");
    }
}

