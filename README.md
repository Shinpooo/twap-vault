## TWAP Executor Vault

Local project to demo a time-sliced execution vault with an agent.

### Demo

[Demo video](assets/demo.mov)

### Build contracts

- `forge build`

### Test contracts

- `forge test`


### Local Run (Anvil)


- In a first terminal window, start Anvil (with 1 block every second)
  - `anvil -p 8545 --block-time 1`

In another terminal window:
- Set owner/agent env (use anvil Account #0 as owner, #1 as agent)
  - `export OWNER_ADDRESS=0x<anvil_account0_addr>`
  - `export OWNER_PK=0x<anvil_account0_priv>`
  - `export AGENT_ADDRESS=0x<anvil_account1_addr>`
  - `export AGENT_PK=0x<anvil_account1_priv>`

- Deploy contracts and initial TWAP
  - `forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:8545 --broadcast -vvv`
  - From the logs, copy the `vault:` address and set:
    - `export VAULT_ADDRESS=0x<printed_vault_addr>`

- Build the agent
  - `cd agent && go build -o twap-agent && cd ..`

- Run the agent bot (WS RPC required for contract event streams)
  - `./agent/twap-agent --rpc ws://127.0.0.1:8545 --contract "$VAULT_ADDRESS" --chain-id 31337 --mode bot`
  - The bot logs each new block, when the next slice is scheduled, executes when eligible, and prints Fill/OrderStatus. It continues running after completion, printing a TWAP summary once last slice has been executed.

- While the TWAP is running, reconfigure the TWAP for a new short window (starts in the next ~30s, ends ~2m, 4 slices). In a new terminal window, run:
  - `forge script script/Configure.s.sol:Configure --sig "run()" --rpc-url http://127.0.0.1:8545 --broadcast -vvv`
  - The previoulsy running agent will pick up the new schedule automatically.

- Use preflight mode to have information on the next slice to execute
- `./agent/twap-agent --rpc ws://127.0.0.1:8545 --contract "$VAULT_ADDRESS" --chain-id 31337 --mode preflight`

### Assumptions and limitations

- Price reference is set as the oracle price at configuration time.
- The adapter respects `minOut` and reports real filled/received amounts and a fee value. The vault grants per‑slice, exact allowances (approve 0 → approve amount). For negative testing, the mock adapter supports tweaking `setOutBps(...)` and `setFeeBps(...)`.
- Slice completion is tracked via a simple `mapping(uint256 => bool)` (sliceId → done) for clarity. A bitmap would be more gas‑efficient but is omitted here for simplicity.
- The agent submits legacy (type‑0) transactions using `gasPrice` (no EIP‑1559).
- If `(end - start) < N`, the per‑slice interval can be zero, making all slices eligible at `startTime`.
- No ReentrancyGuard usage. Reentrancy attack can only happen if agent = adapter. Conditions are set in a way this cannot happen.
- ERC20 ops use IERC20 directly (not SafeERC20). Non‑standard tokens that do not return booleans may be incompatible.
- Reconfiguring clears `sliceDone` in a loop up to N; extremely large N could make `configureStrategy` costly. A future improvement is using a bitmap to avoid clearing.
- The “fee” is informational accounting only; the vault does not collect venue fees separately. Owner can recover balances via `sweep`.
- The agent is WS‑only RPC. Can be extended later to http as a fallback.
- ETH trading is not supported. `tokenIn` and `tokenOut` must be ERC20 addresses (non‑zero). The vault’s `sweep(address(0), to)` exists only to recover accidentally sent ETH.
- Time window behavior — interval is computed as floor division of `(endTime - startTime)` by total slices. If the window is too short relative to the number of slices, multiple slices can become eligible at the same time (interval can be 0). The vault only enforces a per‑slice earliest schedule (≥ scheduled time) and does not enforce an upper bound at `endTime`. Operationally, the execution after `endTime` is still permitted by the contract.
