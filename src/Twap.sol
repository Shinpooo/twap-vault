// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IDexAdapter} from "./interfaces/IDexAdapter.sol";
import {IOracle} from "./interfaces/IOracle.sol";


/// @title TWAP Excutor Vault
contract Twap is Ownable, Pausable {
    using SafeERC20 for IERC20;
    /// @notice Address authorized to execute twap slices.
    address public agent;

    modifier onlyAgent() {
        require(msg.sender == agent, "AGENT");
        _;
    }

    /// @notice Strategy parameters defining a TWAP schdule config.
    struct Strategy {
        /// @notice ERC20 to sell.
        address tokenIn;
        /// @notice ERC20 to buy.
        address tokenOut;
        /// @notice DEX adapter used to execute swaps.
        address adapter;
        /// @notice Oracle used for price and deviation guards.
        address priceOracle;
        /// @notice Total input amount to sell over the whole TWAP (18 decimals).
        uint256 totalAmountIn;
        /// @notice Per‑slice nominal input amount (18 decimals). The last slice may be smaller.
        uint256 sliceAmountIn;
        /// @notice Start timestamp of the TWAP window.
        uint256 startTime;
        /// @notice End timestamp of the TWAP window.
        uint256 endTime;
        /// @notice Max allowed slippage applied to the oracle quote.
        uint16 maxSlippageBps;
        /// @notice Max deviation allowed vs the initial reference oracle price.
        uint16 maxPriceDeviationBps;
    }

    /// @notice Current configured strategy.
    Strategy public strategy;

    // Status
    /// @notice High‑level order status lifecycle.
    enum Status {
        Open,
        PartialFilled,
        Filled,
        Cancelled
    }
    /// @notice Current order status.
    Status public status;

    // Accounting (18 decimals tokens assumed)
    /// @notice Cumulative input filled across all executed slices.
    uint256 public filledAmountIn;
    /// @notice Cumulative output received across all executed slices.
    uint256 public receivedAmountOut;
    /// @notice Cumulative fees reported by the adapter across all fills.
    uint256 public accruedFee;
    /// @notice Oracle reference price captured upon configuration, used for deviation checks.
    uint256 public referencePrice;

    // Slice tracking: sliceId => done
    /// @notice Per‑slice completion map (sliceId => executed?).
    mapping(uint256 => bool) public sliceDone;

    // Events
    /// @notice Emitted for each successful slice execution.
    /// @param sliceId The executed slice index.
    /// @param amountIn Input token amount consumed by the adapter.
    /// @param amountOut Output token amount received by the vault.
    /// @param fee Any dex fee reported by the adapter for this fill.
    event Fill(uint256 sliceId, uint256 amountIn, uint256 amountOut, uint256 fee);

    /// @notice Emitted after each fill and after configuration/cancellation to summarize order state.
    /// @param filledAmountIn Cumulative input filled.
    /// @param receivedAmountOut Cumulative output received.
    /// @param fee Cumulative fees accrued.
    /// @param status Encoded order status: 0=Open, 1=PartialFilled, 2=Filled, 3=Cancelled.
    event OrderStatus(uint256 filledAmountIn, uint256 receivedAmountOut, uint256 fee, uint8 status);

    /// @notice Initialize the vault with an owner.
    /// @param initialOwner The admin address with full control over configuration and sweeping.
    constructor(address initialOwner) Ownable(initialOwner) {}

    // Admin controls
    /// @notice Set the non‑admin agent authorized to execute slices.
    /// @dev For safety, the agent must not equal the configured adapter to avoid any possibility of
    /// reentrancy attack.
    /// @param newAgent The new agent address.
    function setAgent(address newAgent) external onlyOwner {
        require(newAgent != address(0), "AGENT_ZERO");
        require(newAgent != strategy.adapter, "AGENT_EQ_ADAPTER");
        agent = newAgent;
    }

    /// @notice Pause non‑admin actions (e.g., slice execution).
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause non‑admin actions.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Configre or reconfigure the TWAP strategy while paused.
    /// @dev Resets accounting and slice tracking; captures a reference oracle price.
    /// @param s Strategy parameters to set. Must satisfy guards on addresses, timing and bps.
    function configureStrategy(Strategy calldata s) external onlyOwner whenPaused {
        require(s.tokenIn != address(0) && s.tokenOut != address(0), "INVALID_TOKENS");
        require(s.tokenIn != s.tokenOut, "SAME_TOKEN");
        require(s.adapter != address(0) && s.priceOracle != address(0), "INVALID_ADDRESSES");
        require(s.totalAmountIn > 0 && s.sliceAmountIn > 0, "INVALID_AMOUNTS");
        require(s.endTime > s.startTime && s.startTime > block.timestamp, "INVALID_TIME_WINDOW");
        require(s.maxSlippageBps <= 1500 && s.maxPriceDeviationBps <= 2500, "INVALID_BPS");
        // Agent must never equal adapter to avoid any reentrancy vector through adapter.swap.
        require(s.adapter != agent, "ADAPTER_EQ_AGENT");

        // Clear previous slice state if any. Could be improved via bitmap
        if (strategy.sliceAmountIn > 0 && strategy.totalAmountIn > 0) {
            uint256 prevN = Math.ceilDiv(strategy.totalAmountIn, strategy.sliceAmountIn);
            for (uint256 i = 0; i < prevN; i++) {
                if (sliceDone[i]) delete sliceDone[i];
            }
        }

        // Set new strategy
        strategy = s;

        // Reset accounting & status
        status = Status.Open;
        filledAmountIn = 0;
        receivedAmountOut = 0;
        accruedFee = 0;

        // Capture reference price from oracle
        referencePrice = IOracle(s.priceOracle).getPrice(s.tokenIn, s.tokenOut);
        require(referencePrice > 0, "NO_REFERENCE_PRICE");

        // Emit initial order status
        emit OrderStatus(filledAmountIn, receivedAmountOut, accruedFee, uint8(status));
    }

    /// @notice Cancel the current strategy and pause further execution.
    /// @dev Emits an OrderStatus event with Cancelled status.
    function cancel() external onlyOwner {
        // Halt strategy and prevent further execution
        require(status != Status.Cancelled && status != Status.Filled, "ORDER_TERMINATED");
        status = Status.Cancelled;
        _pause();
        emit OrderStatus(filledAmountIn, receivedAmountOut, accruedFee, uint8(status));
    }

    // Sewep any ERC20 token or native ETH (token == address(0))
    /// @notice Recover ERC20 or native ETH held by the vault to a recipient.
    /// @param token The token to sweep (use address(0) for native ETH).
    /// @param to The recipient of the swept funds.
    function sweep(address token, address to) external onlyOwner {
        require(to != address(0), "INVALID_TO");
        if (token == address(0)) {
            uint256 bal = address(this).balance;
            (bool ok, ) = to.call{value: bal}("");
            require(ok, "ETH");
        } else {
            uint256 bal = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransfer(to, bal);
        }
    }

    // Agent-only execution of a single slice
    /// @notice Execute a single TWAP slice by the authorized agent.
    /// @param sliceId The slice index to execute (0..N-1).
    /// Emits Fill and OrderStatus on success.
    function executeSlice(uint256 sliceId) external onlyAgent whenNotPaused {
        require(status != Status.Cancelled && status != Status.Filled, "ORDER_TERMINATED");
        uint256 N = Math.ceilDiv(strategy.totalAmountIn, strategy.sliceAmountIn);
        require(sliceId < N, "INVALID_SLICE_ID");
        require(!sliceDone[sliceId], "SLICE_DONE");

        // Schedule guard
        uint256 interval = (strategy.endTime - strategy.startTime) / N; // integer division
        uint256 scheduled = strategy.startTime + (interval * sliceId);
        require(block.timestamp >= scheduled, "TOO_EARLY");

        // Determine amountIn for this slice (last slice may be smaller)
        uint256 remainingIn = strategy.totalAmountIn - filledAmountIn;
        uint256 amountIn = remainingIn < strategy.sliceAmountIn ? remainingIn : strategy.sliceAmountIn;
        require(amountIn > 0, "NOTHING_REMAINING");

        uint256 minOut;
        // Oracle check and compute minOut (assume price 1e18 units)
        uint256 p = IOracle(strategy.priceOracle).getPrice(strategy.tokenIn, strategy.tokenOut);
        require(p > 0, "INVALID_PRICE");

        // Price deviation vs reference (inline to minimize locals)
        require(
            ((p > referencePrice ? p - referencePrice : referencePrice - p) * 10_000) / referencePrice
                <= strategy.maxPriceDeviationBps,
            "PRICE_DEVIATION"
        );
        // Min out = amountIn * p / 1e18 * (1 - slippage)
        uint256 slippageFactor = 10_000 - strategy.maxSlippageBps;
        minOut = Math.mulDiv(amountIn, p * slippageFactor, 1e22);
        require(minOut > 0, "MIN_OUT_ZERO");

        // Approve adapter to pull tokenIn (USDT-safe)
        IERC20(strategy.tokenIn).forceApprove(strategy.adapter, amountIn);

        // Execute swap on adapter.
        (uint256 _filledIn, uint256 _receivedOut, uint256 _fee) = IDexAdapter(strategy.adapter).swap(
            strategy.tokenIn,
            strategy.tokenOut,
            amountIn,
            minOut
        );

        require(_filledIn > 0 && _filledIn <= amountIn, "INVALID_FILL");
        require(_receivedOut >= minOut, "SLIPPAGE");

        // Update accounting
        filledAmountIn += _filledIn;
        receivedAmountOut += _receivedOut;
        accruedFee += _fee;

        // Mark slice done
        sliceDone[sliceId] = true;

        emit Fill(sliceId, _filledIn, _receivedOut, _fee);

        // Update status and emit order status
        if (filledAmountIn >= strategy.totalAmountIn) {
            status = Status.Filled;
        } else if (filledAmountIn > 0) {
            status = Status.PartialFilled;
        } else {
            status = Status.Open;
        }
        emit OrderStatus(filledAmountIn, receivedAmountOut, accruedFee, uint8(status));
    }

    // Views
    /// @notice Compute the scheduled timestamp for a given slice ID under the current strategy.
    /// @param sliceId The slice index.
    /// @return timestamp The scheduled time when the slice becomes eligible.
    function nextIntervalTimestamp(uint256 sliceId) external view returns (uint256) {
        uint256 N = Math.ceilDiv(strategy.totalAmountIn, strategy.sliceAmountIn);
        if (sliceId >= N) return type(uint256).max;
        uint256 interval = (strategy.endTime - strategy.startTime) / N;
        return strategy.startTime + (interval * sliceId);
    }

    /// @notice Number of slices implied by the current strategy.
    /// @return count The total slice count N = ceil(totalAmountIn / sliceAmountIn).
    function totalSlices() external view returns (uint256) {
        if (strategy.sliceAmountIn == 0) return 0;
        return Math.ceilDiv(strategy.totalAmountIn, strategy.sliceAmountIn);
    }

    /// @notice Convenience getter for a subset of strategy parameters commonly used off‑chain.
    /// @return tokenIn The input token.
    /// @return tokenOut The output token.
    /// @return adapter The DEX adapter.
    /// @return priceOracle The price oracle.
    /// @return totalAmountIn The total input amount configured.
    /// @return maxSlippageBps Max slippage guard in bps.
    /// @return maxPriceDeviationBps Max deviation guard in bps.
    function getStrategyParams() external view returns (
        address tokenIn,
        address tokenOut,
        address adapter,
        address priceOracle,
        uint256 totalAmountIn,
        uint16 maxSlippageBps,
        uint16 maxPriceDeviationBps
    ) {
        Strategy memory s = strategy;
        return (s.tokenIn, s.tokenOut, s.adapter, s.priceOracle, s.totalAmountIn, s.maxSlippageBps, s.maxPriceDeviationBps);
    }
}
