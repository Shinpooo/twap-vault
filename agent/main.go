package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math/big"
	"os"
	"strings"
	"time"

	"github.com/ethereum/go-ethereum"
	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/accounts/abi/bind"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/ethclient"
)

type Strategy struct {
	TokenIn              common.Address
	TokenOut             common.Address
	Adapter              common.Address
	PriceOracle          common.Address
	TotalAmountIn        *big.Int
	SliceAmountIn        *big.Int
	StartTime            *big.Int
	EndTime              *big.Int
	MaxSlippageBps       uint16
	MaxPriceDeviationBps uint16
}

func main() {
	var (
		rpcURL      string
		contractHex string
		privHex     string
		chainID     uint64
		abiPath     string
		mode        string
	)

	// args & env
	flag.StringVar(&rpcURL, "rpc", os.Getenv("RPC_URL"), "WebSocket RPC URL (ws:// or wss://)")
	flag.StringVar(&contractHex, "contract", "", "Twap contract address")
	defaultAgentPK := os.Getenv("AGENT_PK")
	flag.StringVar(&privHex, "private-key", defaultAgentPK, "Agent private key hex (env AGENT_PK)")
	flag.Uint64Var(&chainID, "chain-id", 0, "Chain ID")
	flag.StringVar(&abiPath, "abi", "out/Twap.sol/Twap.json", "Path to Twap.json artifact")
	flag.StringVar(&mode, "mode", "preflight", "Mode: preflight|bot")
	flag.Parse()

	if rpcURL == "" || contractHex == "" {
		log.Fatal("rpc and contract are required")
	}

	ctx := context.Background()
	client, err := ethclient.DialContext(ctx, rpcURL)
	if err != nil {
		log.Fatalf("dial rpc: %v", err)
	}
	defer client.Close()

	abiJSON, err := os.ReadFile(abiPath)
	if err != nil {
		log.Fatalf("read abi: %v", err)
	}
	var artifact struct{ ABI any }
	if err := json.Unmarshal(abiJSON, &artifact); err != nil {
		log.Fatalf("unmarshal abi artifact: %v", err)
	}
	abiBytes, err := json.Marshal(artifact.ABI)
	if err != nil {
		log.Fatalf("marshal abi: %v", err)
	}
	cABI, err := abi.JSON(strings.NewReader(string(abiBytes)))
	if err != nil {
		log.Fatalf("parse abi: %v", err)
	}

	addr := common.HexToAddress(contractHex)
	bound := bind.NewBoundContract(addr, cABI, client, client, client)

	// Read chain ID if not provided
	// if chainID == 0 {
	// 	id, err := client.ChainID(ctx)
	// 	if err != nil {
	// 		log.Fatalf("chain id: %v", err)
	// 	}
	// 	chainID = id.Uint64()
	// }

	var runErr error
	switch mode {
	case "preflight":
		runErr = preflight(ctx, addr, cABI, client)
	case "bot":
		runErr = bot(ctx, addr, cABI, bound, client, privHex, chainID)
	default:
		runErr = fmt.Errorf("unknown mode: %s", mode)
	}
	if runErr != nil {
		log.Fatal(runErr)
	}
}

// callView packs, executes a static call and unpacks outputs.
func callView(ctx context.Context, addr common.Address, cABI abi.ABI, client *ethclient.Client, method string, args ...interface{}) ([]interface{}, error) {
	data, err := cABI.Pack(method, args...)
	if err != nil {
		return nil, fmt.Errorf("pack %s: %w", method, err)
	}
	res, err := client.CallContract(ctx, ethereum.CallMsg{To: &addr, Data: data}, nil)
	if err != nil {
		return nil, fmt.Errorf("call %s: %w", method, err)
	}
	outs, err := cABI.Unpack(method, res)
	if err != nil {
		return nil, fmt.Errorf("unpack %s: %w", method, err)
	}
	return outs, nil
}

func readStrategy(ctx context.Context, addr common.Address, cABI abi.ABI, client *ethclient.Client) (Strategy, error) {
	outs, err := callView(ctx, addr, cABI, client, "strategy")
	if err != nil {
		return Strategy{}, err
	}
	if len(outs) != 10 {
		return Strategy{}, fmt.Errorf("unexpected strategy() outputs: got %d", len(outs))
	}
	return Strategy{
		TokenIn:              outs[0].(common.Address),
		TokenOut:             outs[1].(common.Address),
		Adapter:              outs[2].(common.Address),
		PriceOracle:          outs[3].(common.Address),
		TotalAmountIn:        outs[4].(*big.Int),
		SliceAmountIn:        outs[5].(*big.Int),
		StartTime:            outs[6].(*big.Int),
		EndTime:              outs[7].(*big.Int),
		MaxSlippageBps:       outs[8].(uint16),
		MaxPriceDeviationBps: outs[9].(uint16),
	}, nil
}

func readFilled(ctx context.Context, addr common.Address, cABI abi.ABI, client *ethclient.Client) (*big.Int, error) {
	outs, err := callView(ctx, addr, cABI, client, "filledAmountIn")
	if err != nil {
		return nil, err
	}
	return outs[0].(*big.Int), nil
}

func readTotalSlices(ctx context.Context, addr common.Address, cABI abi.ABI, client *ethclient.Client) (*big.Int, error) {
	outs, err := callView(ctx, addr, cABI, client, "totalSlices")
	if err != nil {
		return nil, err
	}
	return outs[0].(*big.Int), nil
}

func readSliceDone(ctx context.Context, addr common.Address, cABI abi.ABI, client *ethclient.Client, i *big.Int) (bool, error) {
	outs, err := callView(ctx, addr, cABI, client, "sliceDone", i)
	if err != nil {
		return false, err
	}
	return outs[0].(bool), nil
}

func preflight(ctx context.Context, addr common.Address, cABI abi.ABI, client *ethclient.Client) error {
	// Get on-chain data and print
	s, err := readStrategy(ctx, addr, cABI, client)
	if err != nil {
		return fmt.Errorf("read strategy: %w", err)
	}
	filled, err := readFilled(ctx, addr, cABI, client)
	if err != nil {
		return fmt.Errorf("read filled: %w", err)
	}
	totalSlices, err := readTotalSlices(ctx, addr, cABI, client)
	if err != nil {
		return fmt.Errorf("read totalSlices: %w", err)
	}

	header, err := client.HeaderByNumber(ctx, nil)
	if err != nil {
		return fmt.Errorf("header: %w", err)
	}
	now := new(big.Int).SetUint64(header.Time)

	N := new(big.Int).Set(totalSlices)
	var next int64 = -1
	if N.Sign() > 0 {
		interval := new(big.Int).Div(new(big.Int).Sub(s.EndTime, s.StartTime), N)
		for i := int64(0); i < N.Int64(); i++ {
			done, err := readSliceDone(ctx, addr, cABI, client, big.NewInt(i))
			if err != nil {
				return fmt.Errorf("sliceDone(%d): %w", i, err)
			}
			if done {
				continue
			}
			scheduled := new(big.Int).Add(s.StartTime, new(big.Int).Mul(interval, big.NewInt(i)))
			if now.Cmp(scheduled) >= 0 {
				next = i
				break
			}
		}
	}

	fmt.Printf("Preflight:\n")
	fmt.Printf("- blockTime: %s (%s)\n", now, time.Unix(int64(now.Uint64()), 0).UTC().Format(time.RFC3339))
	fmt.Printf("- totalAmountIn: %s\n", s.TotalAmountIn)
	fmt.Printf("- sliceAmountIn: %s\n", s.SliceAmountIn)
	fmt.Printf("- window: %s -> %s\n", s.StartTime, s.EndTime)
	fmt.Printf("- filledAmountIn: %s\n", filled)
	fmt.Printf("- totalSlices: %s\n", N)
	if next >= 0 {
		fmt.Printf("- nextEligibleSlice: %d\n", next)
	} else {
		fmt.Printf("- nextEligibleSlice: none (by schedule or all done)\n")
	}
	return nil
}

func execute(ctx context.Context, bound *bind.BoundContract, client *ethclient.Client, privHex string, chainID uint64, sliceId int64) {
	if privHex == "" {
		log.Fatal("private key is required for bot mode")
	}
	privHex = strings.TrimPrefix(privHex, "0x")
	key, err := crypto.HexToECDSA(privHex)
	if err != nil {
		log.Fatalf("parse key: %v", err)
	}

	// Prepare transactor
	if chainID == 0 {
		id, err := client.ChainID(ctx)
		if err != nil {
			log.Fatalf("chain id: %v", err)
		}
		chainID = id.Uint64()
	}
	auth, err := bind.NewKeyedTransactorWithChainID(key, new(big.Int).SetUint64(chainID))
	if err != nil {
		log.Fatalf("transactor: %v", err)
	}
	auth.Context = ctx

	// Determine nonce and gas settings ahead of submission, and print them.
	nonce, err := client.PendingNonceAt(ctx, auth.From)
	if err != nil {
		log.Printf("pending nonce error (will let sender handle): %v", err)
	} else {
		auth.Nonce = new(big.Int).SetUint64(nonce)
	}

	// Legacy gas pricing only (force type-0 transactions)
	gp, err := client.SuggestGasPrice(ctx)
	if err != nil {
		log.Printf("suggest gas price error: %v", err)
	} else {
		auth.GasPrice = new(big.Int).Set(gp)
	}
	if auth.Nonce != nil && auth.GasPrice != nil {
		fmt.Printf("Planning tx: nonce=%d, gasPrice=%s wei\n", auth.Nonce.Uint64(), auth.GasPrice.String())
	} else if auth.GasPrice != nil {
		fmt.Printf("Planning tx: gasPrice=%s wei\n", auth.GasPrice.String())
	}

	// Submit
	tx, err := bound.Transact(auth, "executeSlice", big.NewInt(sliceId))
	if err != nil {
		log.Printf("executeSlice(%d) error: %v", sliceId, err)
		return
	}
	fmt.Printf("Submitted tx %s for slice %d\n", tx.Hash().Hex(), sliceId)

	// Wait for mining
	receipt, err := bind.WaitMined(ctx, client, tx)
	if err != nil {
		log.Printf("wait mined error: %v", err)
		return
	}
	if receipt.Status != types.ReceiptStatusSuccessful {
		log.Printf("tx failed: %s", tx.Hash().Hex())
		return
	}
	fmt.Printf("Mined in block %d\n", receipt.BlockNumber.Uint64())
}

func readStatus(ctx context.Context, addr common.Address, cABI abi.ABI, client *ethclient.Client) (uint8, error) {
	outs, err := callView(ctx, addr, cABI, client, "status")
	if err != nil {
		return 0, err
	}
	return outs[0].(uint8), nil
}

func bot(ctx context.Context, addr common.Address, cABI abi.ABI, bound *bind.BoundContract, client *ethclient.Client, privHex string, chainID uint64) error {
	if privHex == "" {
		return fmt.Errorf("private key is required for bot mode")
	}

	// Event subscription (WS only)
	logsCh := make(chan types.Log, 128)
	sub, err := client.SubscribeFilterLogs(ctx, ethereum.FilterQuery{Addresses: []common.Address{addr}}, logsCh)
	if err != nil {
		return fmt.Errorf("log subscribe failed: %w", err)
	}
	log.Printf("subscribed to contract logs")

	// Header subscription (WS only)
	heads := make(chan *types.Header, 32)
	headSub, err := client.SubscribeNewHead(ctx, heads)
	if err != nil {
		return fmt.Errorf("header subscribe failed: %w", err)
	}
	log.Printf("subscribed to new heads")

	terminalLogged := false
	for {
		select {
		case err := <-headSub.Err():
			return fmt.Errorf("header sub error: %w", err)
		case err := <-sub.Err():
			return fmt.Errorf("log sub error: %w", err)
		case h := <-heads:
			handleBlock(ctx, addr, cABI, bound, client, privHex, chainID, h.Number)
		case lg := <-logsCh:
			if len(lg.Topics) == 0 {
				continue
			}
			ev, err := cABI.EventByID(lg.Topics[0])
			if err != nil {
				continue
			}
			switch ev.Name {
			case "Fill":
				var out struct{ SliceId, AmountIn, AmountOut, Fee *big.Int }
				if err := cABI.UnpackIntoInterface(&out, "Fill", lg.Data); err == nil {
					fmt.Printf("[Event] Fill: slice=%s in=%s out=%s fee=%s\n", out.SliceId, out.AmountIn, out.AmountOut, out.Fee)
				}
			case "OrderStatus":
				var out struct {
					FilledAmountIn, ReceivedAmountOut, Fee *big.Int
					Status                                 uint8
				}
				if err := cABI.UnpackIntoInterface(&out, "OrderStatus", lg.Data); err == nil {
					fmt.Printf("[Event] OrderStatus: filled=%s received=%s fee=%s status=%d\n", out.FilledAmountIn, out.ReceivedAmountOut, out.Fee, out.Status)
					if out.Status == 2 && !terminalLogged { // Filled
						s, _ := readStrategy(ctx, addr, cABI, client)
						fmt.Printf("TWAP Summary: filled=%s/%s, received=%s, fee=%s, status=%d\n", out.FilledAmountIn, s.TotalAmountIn, out.ReceivedAmountOut, out.Fee, out.Status)
						fmt.Println("Continuing to watch events...")
						terminalLogged = true
					}
				}
			}
		}
	}
}

func handleBlock(ctx context.Context, addr common.Address, cABI abi.ABI, bound *bind.BoundContract, client *ethclient.Client, privHex string, chainID uint64, number *big.Int) {
	hdr, err := client.HeaderByNumber(ctx, number)
	if err == nil {
		fmt.Printf("New block %d time=%d\n", hdr.Number.Uint64(), hdr.Time)
	}
	// Skip execution attempts if order is filled or canceled
	if st, err := readStatus(ctx, addr, cABI, client); err == nil {
		if st == 2 || st == 3 { // Filled or Canceleled
			return
		}
	}
	// Attempt execute if eligible
	s, err := readStrategy(ctx, addr, cABI, client)
	if err != nil {
		return
	}
	N, err := readTotalSlices(ctx, addr, cABI, client)
	if err != nil {
		return
	}
	now := new(big.Int).SetUint64(hdr.Time)
	// Determine the first (unrelaized) slice regardless of schedule
	var firstUndone int64 = -1
	for i := int64(0); i < N.Int64(); i++ {
		done, _ := readSliceDone(ctx, addr, cABI, client, big.NewInt(i))
		if !done {
			firstUndone = i
			break
		}
	}
	if firstUndone >= 0 {
		// Compute schedule info
		interval := new(big.Int).Div(new(big.Int).Sub(s.EndTime, s.StartTime), N)
		scheduled := new(big.Int).Add(s.StartTime, new(big.Int).Mul(interval, big.NewInt(firstUndone)))
		execNow := now.Cmp(scheduled) >= 0
		if execNow {
			fmt.Printf("Eligible slice %d at block %d\n", firstUndone, hdr.Number.Uint64())
			execute(ctx, bound, client, privHex, chainID, firstUndone)
		} else {
			// Log when it will be executable
			diff := new(big.Int).Sub(scheduled, now)
			fmt.Printf("Next slice %d scheduled at %d (in ~%ds)\n", firstUndone, scheduled.Uint64(), diff.Uint64())
		}
	}
}

// printLog handling moved inline in bot() to allow summary trigger only via Filled event
