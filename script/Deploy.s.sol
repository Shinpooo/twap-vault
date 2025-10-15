// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console2 as console} from "forge-std/console2.sol";

import {Twap} from "../src/Twap.sol";
import {MockDexAdapter} from "../src/mocks/MockDexAdapter.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract Deploy is Script {
    /// Env-only deployment: expects OWNER_ADDRESS, OWNER_PK, AGENT_ADDRESS.
    /// Deploys mocks (ERC20Mock in/out, MockDexAdapter, MockOracle), deploys Twap,
    /// funds vault with tokenIn, sets agent, and configures an initial short TWAP
    /// (start ~30s, end ~2m, 4-ish slices per totals).
    function run() external {
        // Env-driven deploy: OWNER_ADDRESS, OWNER_PK, AGENT_ADDRESS
        address ownerAddress = vm.envAddress("OWNER_ADDRESS");
        bytes32 ownerPkRaw = vm.envBytes32("OWNER_PK");
        address agent = vm.envAddress("AGENT_ADDRESS");
        uint256 ownerKey = uint256(ownerPkRaw);

        vm.startBroadcast(ownerKey);

        // Deploy mocks
        ERC20Mock tokenIn = new ERC20Mock();
        ERC20Mock tokenOut = new ERC20Mock();
        MockDexAdapter adapter = new MockDexAdapter();
        MockOracle oracle = new MockOracle(1e18, 50); // 1:1 price with ±0.5% jitter for local realism

        // Deploy TWAP vault
        // Set the owner explicitly to the broadcaster EOA derived from the key
        Twap vault = new Twap(ownerAddress);
        vault.setAgent(agent);

        // Fund vault with tokenIn
        tokenIn.mint(address(vault), 100 ether);

        // Prepare strategy
        Twap.Strategy memory s = Twap.Strategy({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            adapter: address(adapter),
            priceOracle: address(oracle),
            totalAmountIn: 10 ether,
            sliceAmountIn: 3 ether,
            startTime: uint64(block.timestamp + 30 seconds),
            endTime: uint64(block.timestamp + 2 minutes),
            maxSlippageBps: 100, // 1%
            maxPriceDeviationBps: 250 // 2.5%
        });

        // Must be paused to configure
        vault.pause();
        vault.configureStrategy(s);
        vault.unpause();

        vm.stopBroadcast();

        console.log("tokenIn:", address(tokenIn));
        console.log("tokenOut:", address(tokenOut));
        console.log("adapter:", address(adapter));
        console.log("oracle:", address(oracle));
        console.log("vault:", address(vault));
        console.log("agent:", agent);
    }
}
