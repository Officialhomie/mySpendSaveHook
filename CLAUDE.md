# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SpendSave is a DeFi protocol built on Uniswap V4 that enables automatic savings, dollar-cost averaging (DCA), and yield generation during token swaps. The protocol uses a modular architecture with gas-optimized hook integration targeting <50k gas for `afterSwap` operations.

## Development Commands

```bash
# Build
forge build

# Run all tests
forge test

# Run a specific test file
forge test --match-path "test/IntegrationTest.t.sol" -vvv

# Run a specific test function
forge test --match-test "testSavingsWithDCA" -vvv

# Run with gas report
forge test --gas-report

# Run tests by category using profiles
FOUNDRY_PROFILE=core forge test --match-path "*core*" -vv
FOUNDRY_PROFILE=savings forge test --match-path "*Savings*" -vv
FOUNDRY_PROFILE=dca forge test --match-path "*DCA*" -vv
FOUNDRY_PROFILE=security forge test --match-path "*{Reentrancy,Security,Batch}*" -vv
FOUNDRY_PROFILE=analytics forge test --match-path "*{Analytics,Quoter,Multicall,Liquidity}*" -vv

# Run invariant tests
FOUNDRY_PROFILE=invariant forge test --match-path "test/invariant/*"

# Run fuzz tests
forge test --match-path "test/fuzz/*"

# Coverage (disables via_ir for compatibility)
FOUNDRY_PROFILE=coverage forge coverage

# Format
forge fmt

# Gas snapshots
forge snapshot
```

## Deployment

```bash
# Deploy to Base Sepolia
forge script script/DeploySpendSave.s.sol:DeploySpendSave --rpc-url base_sepolia --private-key $PRIVATE_KEY --broadcast

# Deploy swap router only
forge script script/DeploySwapRouter.s.sol --rpc-url base_sepolia --private-key $PRIVATE_KEY --broadcast

# Deploy cross-chain modules
forge script script/DeployCrossChainModules.s.sol --rpc-url base_sepolia --private-key $PRIVATE_KEY --broadcast

# Initialize a pool with the hook
forge script script/InitializePoolWithHook.s.sol --rpc-url base_sepolia --private-key $PRIVATE_KEY --broadcast
```

## Architecture Overview

### Contract Roles

| Contract | Role |
|----------|------|
| `SpendSaveHook` | Uniswap V4 hook entry point — intercepts `beforeSwap`/`afterSwap` |
| `SpendSaveStorage` | Centralized state store (ERC6909 base) — single source of truth |
| `SpendSaveModuleRegistry` | Upgradeable module management with versioning |
| `SavingStrategy` | Savings percentage, auto-increment, and DCA configuration per user |
| `Savings` | Token deposit/withdrawal logic and ERC6909 minting |
| `DCA` | Dollar-cost averaging queue and execution logic |
| `Token` | ERC6909 token representation of savings positions |
| `SlippageControl` | Slippage limit management and enforcement |
| `DailySavings` | Automated recurring savings execution (keeper-triggered) |
| `SpendSaveDCARouter` | DCA order routing to Uniswap V4 |
| `SpendSaveLiquidityManager` | Liquidity position management for yield |
| `SpendSaveMulticall` | Batched user operations in a single transaction |
| `SpendSaveQuoter` | Off-chain savings and DCA amount estimation |
| `SpendSaveAnalytics` | On-chain analytics and savings history |
| `SpendSaveSlippageEnhanced` | Extended slippage protection strategies |
| `CrossChainSavingsModule` | L2-to-L2 savings transfers via `IL2ToL2CrossDomainMessenger` |
| `CrossChainDCAModule` | Cross-chain DCA execution |

### Data Flow: Swap with Savings

1. User initiates a swap through the Uniswap V4 `PoolManager`
2. **`beforeSwap`**: Hook reads `PackedUserConfig` (single SLOAD) → calculates save amount in memory → stores context in transient storage (`PackedSwapContext`) → takes input tokens from `PoolManager` for INPUT-type savings
3. **`afterSwap`**: Hook reads transient context → transfers saved tokens to `SpendSaveStorage` → calls `Savings.processSavings()` → mints ERC6909 tokens to user → clears transient storage

### Storage Optimization Patterns

- **`PackedUserConfig`** (256 bits): `percentage(16) | autoIncrement(16) | maxPercentage(16) | roundUpSavings(8) | enableDCA(8) | savingsTokenType(8) | reserved(184)` — one SLOAD for all user settings
- **`PackedSwapContext`**: Transient storage (EIP-1153, requires Cancun EVM) for zero-cost `beforeSwap`→`afterSwap` communication
- Module addresses retrieved via `storage_.getModule(keccak256("MODULE_NAME"))` — module registry constants defined as `bytes32` in `SpendSaveHook`

### Module Registry Keys

Modules are registered by `keccak256` identifier:
- `keccak256("STRATEGY")` → `SavingStrategy`
- `keccak256("SAVINGS")` → `Savings`
- `keccak256("DCA")` → `DCA`
- `keccak256("SLIPPAGE")` → `SlippageControl`
- `keccak256("TOKEN")` → `Token`
- `keccak256("DAILY")` → `DailySavings`
- `keccak256("CROSSCHAIN")` → `CrossChainSavingsModule`

### Savings Token Types

- `0` = INPUT: Save from the swap's input token (intercepted in `beforeSwap`)
- `1` = OUTPUT: Save from the swap's output token (calculated in `afterSwap` from `BalanceDelta`)
- `2` = SPECIFIC: Convert savings to a user-specified target token via DCA queue

### Hook Permissions

Enabled flags: `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, `afterSwapReturnDelta`. The hook address must be mined to encode these flags — `validateHookAddress` is overridden to be a no-op, enabling HookMiner deployment.

### Cross-Chain Architecture

Cross-chain transfers use Optimism's `IL2ToL2CrossDomainMessenger` (deployed at `0x4200000000000000000000000000000000000023`). Peer module addresses are registered per destination chain ID using `trustedPeerModules`. Both savings and DCA operations have dedicated cross-chain modules in `src/modules/`.

## Deployment Sequence

The deployment script must follow this exact order:
1. Deploy `SpendSaveStorage`
2. Deploy all module contracts
3. Mine hook address and deploy `SpendSaveHook` (address flags must encode hook permissions)
4. Call `storage_.setHook(hookAddress)` and `storage_.setOwner()`
5. Register each module via `storage_.registerModule(keccak256(name), moduleAddress)`
6. Call `hook.initializeModules(...)` — initializes each module with storage reference and sets cross-module references

## Network Configuration

- **Base Mainnet** (8453): PoolManager `0x498581fF718922c3f8e6A244956aF099B2652b2b`
- **Base Sepolia** (84532): PoolManager `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`

## Test Organization

```
test/
├── *.t.sol              # Unit and integration tests per module
├── invariant/           # Foundry invariant tests (512 runs, depth 64)
├── fuzz/                # Fuzz tests for core logic
└── crosschain/          # Cross-chain module tests
```

Key test files: `IntegrationTest.t.sol` (full swap flow), `PackedStorageIntegrityTest.t.sol` (storage layout), `HookGasOptimizationTest.t.sol` (gas benchmarks), `ERC6909ComplianceTest.t.sol` (token standard).

## Adding New Modules

1. Implement module logic in `src/`
2. Add interface in `src/interfaces/`
3. Extend `ISpendSaveModule` base interface (has `initialize` and `setModuleReferences`)
4. Add `bytes32` key constant in `SpendSaveHook`
5. Register in `SpendSaveStorage` via `registerModule`
6. Add initialization call in `SpendSaveHook.initializeModules`
7. Add cross-module reference wiring in `_initializeModuleReferences`

## Important Constraints

- EVM version is `cancun` (required for transient storage EIP-1153)
- `via_ir = true` for production builds; disabled in coverage profile
- `optimizer_runs = 1` (optimize for deployment cost, not runtime — contract is large)
- All currency operations during swaps must go through the PoolManager unlock/callback pattern — direct ERC20 calls outside this pattern violate V4 compliance
- Daily savings processing is keeper-triggered via `processDailySavings(user)` — not in the swap path
