// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {Twap} from "../src/Twap.sol";

contract Configure is Script {
    /// Re-configure an already deployed TWAP to:
    /// - start ~30 seconds from now
    /// - end ~2 minutes after start
    /// - use 4 slices (sliceAmountIn = ceil(totalAmountIn / 4))
    ///
    /// Requires OWNER_PK and VAULT_ADDRESS in env.
    ///
    /// Usage:
    /// forge script script/Configure.s.sol:Configure --sig "run()" --rpc-url http://127.0.0.1:8545 --broadcast -vvv
    function run() external {
        uint256 ownerKey = uint256(vm.envBytes32("OWNER_PK"));
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        vm.startBroadcast(ownerKey);

        Twap vault = Twap(vaultAddr);
        (
            address tokenIn,
            address tokenOut,
            address adapter,
            address priceOracle,
            uint256 totalAmountIn,
            uint16 maxSlippageBps,
            uint16 maxPriceDeviationBps
        ) = vault.getStrategyParams();

        // Force 4 slices
        uint256 sliceAmountIn = totalAmountIn == 0 ? 0 : (totalAmountIn + 4 - 1) / 4;

        // New time window
        uint256 start = block.timestamp + 30 seconds;
        uint256 end = start + 2 minutes;

        vault.pause();
        Twap.Strategy memory s = Twap.Strategy({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            adapter: adapter,
            priceOracle: priceOracle,
            totalAmountIn: totalAmountIn,
            sliceAmountIn: sliceAmountIn,
            startTime: start,
            endTime: end,
            maxSlippageBps: maxSlippageBps,
            maxPriceDeviationBps: maxPriceDeviationBps
        });
        vault.configureStrategy(s);
        vault.unpause();

        vm.stopBroadcast();
    }
}
