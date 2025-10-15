# Take‑Home: TWAP Executor Vault (Trading-Focused)

Time-sliced execution of a large order across DEXs with oracle-guarded slippage and strict two-tier permissions.

---

## Overview

You will implement:

1. **Smart contract**: A vault that executes a TWAP (time-weighted average price) sell strategy of `tokenIn` → `tokenOut`.
2. **Off-chain agent** (non-admin): A CLI that schedules and submits execution slices to the vault.
3. **(For local testing)**: A minimal DEX adapter and a mock oracle.

**Permissions**
- **Owner (admin)**: configure strategy & params, pause/unpause, cancel, sweep.
- **Agent (hot wallet)**: execute non-admin actions — execute slices and finalize when done.

Target stack: Solidity ^0.8.20, Foundry and Go (go-ethereum) for the agent, OpenZeppelin libraries.

---

## Part 1 — Smart Contract

### Roles & Permissions

- **Owner-only**
  - `setAgent(address)`
  - `configureStrategy(Strategy calldata s)` (only when paused)
  - `pause()` / `unpause()`
  - `cancel()` (halts strategy; leftover funds can be swept)
  - `sweep(address token, address to)` (recover tokens/ETH, or fees if enabled)

- **Agent-only (non-admin)**
  - `executeSlice(uint256 sliceId)` — runs one TWAP sliceID `0..N-1 where N = ceil(total/slice)`

- **Public (view)**
  - Getters for strategy, status, accounting, and slice completion bitmap/map.

### Strategy & Execution Structures

```solidity
struct Strategy {
  address tokenIn;
  address tokenOut;
  address adapter;          
  address priceOracle;      
  uint256 totalAmountIn;    // total to sell (tokenIn)
  uint256 sliceAmountIn;    // per-slice input
  uint256 startTime;
  uint256 endTime;
  uint16  maxSlippageBps;       // e.g., ≤ 150
  uint16  maxPriceDeviationBps; // vs. oracle mid, e.g., ≤ 250
}
```

### Interfaces

```solidity
interface IDexAdapter {
  function swap(address tokenIn, address tokenOut,
    uint256 amountIn, uint256 minOut
  ) external returns (uint256 filledAmountIn, uint256 receivedAmountOut, uint256 fee);
}

interface IOracle {
  function getPrice(address tokenIn, address tokenOut) external returns (uint256 price);
}
```

### Events

```solidity

event Fill(
  uint256 sliceId,
  uint256 amountIn,
  uint256 amountOut,
  uint256 fee
);

event OrderStatus(
  uint256 filledAmountIn,
  uint256 receivedAmountOut,
  uint256 fee,
  uint8 status // 0=Open, 1=PartialFilled, 2=Filled, 3=Cancelled
);
```


### Execution Rules

- **Token Decimals**: All tokens are 18 decimals.
- **Schedule guard**: Each slice can only be executed after its scheduled time.
  - Define interval = `(endTime - startTime) / N`; require each `sliceId` executes at or after `startTime + sliceId * interval`.
- **SliceID**
  - Must be in `0..N-1` where `N = ceil(totalAmountIn / sliceAmountIn)`.
  - Each slice transfers up to `sliceAmountIn`, except the last, which may use the remaining balance.
- **No double-exec**: Each slice can only be executed once. A slice that has been executed must be marked complete, and repeated attempts must revert.
- **Oracle**:
  - Require `quotedMinOut >= amountIn * P_oracle * (1 - maxSlippageBps)/1e4`.
  - Require price deviation vs a reference not exceeding `maxPriceDeviationBps`.
- **Accounting**:
  - Call adapter.swap; on success update `filledAmountIn`, `receivedAmountOut`, mark slice done.
  - Record the Fill and emit Fill Event with the fill details.
  - On each fill emit Order Status Event with the order details.
  - If the total TWAP amount has been filled, set the order status to Filled.


---

## Part 2 — Off-Chain Agent (CLI)

**Language**: Go (go-ethereum)

**Responsibilities**
1. **Pre-flight**
   - Read on-chain `strategy`, `filledAmountIn`, `sliceDone` map/bitmap.
   - Determine `N = ceil(totalAmountIn / sliceAmountIn)` and next eligible `sliceId` by schedule.
2. **Submit**
   - Send `executeSlice({ sliceId })` from AGENT key.
   - Nonce management and gas estimation.
3. **Monitoring**
   - Watch `Fill`/`OrderStatus` events.
4. **Finalize**
   - Check for TWAP completion and log a TWAP Summary to console.
---

## Part 3 — DEX and Oracle Adapter (for Local Testing)

Implement a minimal adapter for the DEX and the Oracle interface.
- Dex adapter can fill full amount each time and have a fixed fee (e.g., 0.3%).
- Oracle can return a pseudo random price that centers around a fixed price.

---

## Deliverables
- Smart Contract Repository with Foundry and tests.
- Simple off-chain agent CLI.
- README with short summary of implementation, how to run, and any assumptions/limitations.
