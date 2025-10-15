// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Twap} from "../src/Twap.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockDexAdapter} from "../src/mocks/MockDexAdapter.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

contract TwapTest is Test {
    Twap vault;
    ERC20Mock tokenIn;
    ERC20Mock tokenOut;
    MockDexAdapter adapter;
    MockOracle oracle;

    address owner = address(0xA11CE);
    address agent = address(this); // test contract acts as agent

    function setUp() public {
        vm.startPrank(owner);
        vault = new Twap(owner);

        tokenIn = new ERC20Mock();
        tokenOut = new ERC20Mock();
        adapter = new MockDexAdapter();
        oracle = new MockOracle(1e18, 0); // 1:1 price, no jitter for deterministic tests

        // Fund vault with tokenIn
        tokenIn.mint(address(vault), 100 ether);

        // Configure roles
        vault.setAgent(agent);

        // Must be paused to configure strategy
        vault.pause();

        Twap.Strategy memory s = Twap.Strategy({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            adapter: address(adapter),
            priceOracle: address(oracle),
            totalAmountIn: 10 ether,
            sliceAmountIn: 3 ether,
            startTime: uint64(block.timestamp + 10),
            endTime: uint64(block.timestamp + 10 + 4 hours),
            maxSlippageBps: 100, // 1%
            maxPriceDeviationBps: 250 // 2.5%
        });

        vault.configureStrategy(s);
        vault.unpause();
        vm.stopPrank();
    }

    function test_cannotConfigureUnpaused() public {
        vm.startPrank(owner);
        Twap.Strategy memory s = Twap.Strategy({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            adapter: address(adapter),
            priceOracle: address(oracle),
            totalAmountIn: 1 ether,
            sliceAmountIn: 1 ether,
            startTime: uint64(block.timestamp + 1000),
            endTime: uint64(block.timestamp + 2000),
            maxSlippageBps: 100,
            maxPriceDeviationBps: 250
        });
        vm.expectRevert();
        vault.configureStrategy(s); // whenPaused enforced
        vm.stopPrank();
    }

    function test_rejectSameTokenConfig() public {
        vm.startPrank(owner);
        // Pause before reconfiguration as required
        if (!vault.paused()) {
            vault.pause();
        }
        // Attempt to configure with tokenIn == tokenOut
        Twap.Strategy memory bad = Twap.Strategy({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenIn), // same as tokenIn
            adapter: address(adapter),
            priceOracle: address(oracle),
            totalAmountIn: 1 ether,
            sliceAmountIn: 1 ether,
            startTime: uint64(block.timestamp + 1000),
            endTime: uint64(block.timestamp + 2000),
            maxSlippageBps: 100,
            maxPriceDeviationBps: 250
        });
        vm.expectRevert(bytes("SAME_TOKEN"));
        vault.configureStrategy(bad);
        vm.stopPrank();
    }

    function test_executeSlices_progressAndFill() public {
        // Move time to start
        vm.warp(block.timestamp + 11);

        // Execute slice 0
        vault.executeSlice(0);
        assertEq(vault.filledAmountIn(), 3 ether);
        assertEq(vault.receivedAmountOut(), (3 ether * 9900) / 10000); // adapter returns minOut exactly

        // Cannot double execute
        vm.expectRevert(bytes("SLICE_DONE"));
        vault.executeSlice(0);

        // Try slice 1 too early
        vm.expectRevert(bytes("TOO_EARLY"));
        vault.executeSlice(1);

        // Warp to allow slice 1
        (
            , , , ,
            uint256 totalAmt,
            uint256 sliceAmt,
            uint256 startTime,
            uint256 endTime,
            ,
            
        ) = vault.strategy();
        uint256 N = _ceilDiv(totalAmt, sliceAmt);
        uint256 interval = (endTime - startTime) / N;
        vm.warp(startTime + interval * 1);
        vault.executeSlice(1);

        // Warp and execute slices 2 and 3
        vm.warp(startTime + interval * 2);
        vault.executeSlice(2);

        vm.warp(startTime + interval * 3);
        vault.executeSlice(3); // last slice uses remaining 1 ether

        // Filled
        assertEq(uint8(vault.status()), uint8(Twap.Status.Filled));
        assertEq(vault.filledAmountIn(), 10 ether);
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    function test_priceDeviationGuard() public {
        // Move to start time
        vm.warp(block.timestamp + 11);

        // Raise oracle price beyond deviation
        oracle.setBasePrice((1e18 * 20000) / 10000); // +100%, devBps=10000 > 250
        vm.expectRevert(bytes("PRICE_DEVIATION"));
        vault.executeSlice(0);
    }

    function test_cancelPreventsExecution() public {
        vm.prank(owner);
        vault.cancel();

        vm.warp(block.timestamp + 11);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.executeSlice(0);
    }

    function test_sweepERC20() public {
        // Mint some stray tokenOut to vault
        tokenOut.mint(address(vault), 5 ether);

        uint256 before = tokenOut.balanceOf(owner);
        vm.prank(owner);
        vault.sweep(address(tokenOut), owner);
        uint256 afterBal = tokenOut.balanceOf(owner);
        assertEq(afterBal - before, 5 ether);
    }

    function test_sweepAfterCancel_tokenIn() public {
        // Cancel the strategy
        vm.prank(owner);
        vault.cancel();

        // Sweep remaining tokenIn to owner
        uint256 ownerBefore = tokenIn.balanceOf(owner);
        uint256 vaultBal = tokenIn.balanceOf(address(vault));
        vm.prank(owner);
        vault.sweep(address(tokenIn), owner);
        uint256 ownerAfter = tokenIn.balanceOf(owner);

        assertEq(ownerAfter - ownerBefore, vaultBal, "owner should receive all tokenIn from vault");
        assertEq(tokenIn.balanceOf(address(vault)), 0, "vault tokenIn should be zero after sweep");
    }

    function test_slippageGuard() public {
        // Make adapter return slightly less than minOut
        adapter.setOutBps(9999); // 0.01% less than minOut

        vm.warp(block.timestamp + 11);
        vm.expectRevert(bytes("SLIPPAGE"));
        vault.executeSlice(0);
    }

    function test_doubleExecutionSameSlice() public {
        // Move time to allow first slice
        vm.warp(block.timestamp + 11);
        vault.executeSlice(0);

        // Attempt to execute the same slice again should revert
        vm.expectRevert(bytes("SLICE_DONE"));
        vault.executeSlice(0);
    }
}
