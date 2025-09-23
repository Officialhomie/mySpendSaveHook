# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SpendSave is a DeFi protocol built on Uniswap V4 that enables automatic savings, dollar-cost averaging (DCA), and yield generation during token swaps. The protocol uses a modular architecture with gas-optimized hook integration.

## Development Commands

### Build and Compilation
```bash
forge build
```

### Testing
```bash
forge test                    # Run all tests
forge test -vvv              # Run with verbose output
forge test --gas-report      # Run with gas usage report
```

### Deployment
```bash
# Deploy to Base Sepolia testnet
forge script script/DeploySpendSave.s.sol:DeploySpendSave --rpc-url base_sepolia --private-key $PRIVATE_KEY --broadcast

# Deploy to Base mainnet  
forge script script/DeploySpendSave.s.sol:DeploySpendSave --rpc-url base --private-key $PRIVATE_KEY --broadcast
```

### Development Tools
```bash
forge fmt                    # Format code
forge snapshot               # Generate gas snapshots
anvil                       # Start local development chain
```

## Architecture Overview

### Core Contracts
- **SpendSaveHook**: Main Uniswap V4 hook that intercepts swap transactions
- **SpendSaveStorage**: Centralized storage contract using packed storage for gas efficiency

### Modular System
The protocol uses a modular architecture with specialized modules:
- **SavingStrategy**: Manages savings percentages and rules
- **Savings**: Handles deposits and withdrawals  
- **DCA**: Dollar-cost averaging execution logic
- **Token**: ERC6909 token representation of savings
- **SlippageControl**: Slippage management and protection
- **DailySavings**: Regular automated savings functionality

### Gas Optimization Features
- Packed storage structures for single-slot reads
- Transient storage for swap context (EIP-1153 compatible)
- Batch operations for storage updates
- Target: <50k gas for afterSwap operations

## Key Architecture Patterns

### Hook Integration
The protocol integrates with Uniswap V4 using:
- `beforeSwap`: Prepares savings calculations and modifies input delta
- `afterSwap`: Processes actual savings with optimized gas usage
- Hook address mining to ensure proper flag compliance

### Storage Optimization
- `PackedUserConfig`: Single storage slot for user configuration (256 bits)
- `PackedSwapContext`: Transient storage for swap communication
- Module registry system for efficient address lookup

### Module Communication
Modules interact through the centralized storage contract using:
- Module registry with keccak256 identifiers
- Authorized module access control
- Cross-module reference system for complex operations

## Network Configuration

### Supported Networks
- **Base Mainnet** (Chain ID: 8453)
  - PoolManager: `0x498581fF718922c3f8e6A244956aF099B2652b2b`
- **Base Sepolia** (Chain ID: 84532)  
  - PoolManager: `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`

## Development Workflow

### Adding New Features
1. Implement logic in appropriate module contract
2. Update storage contract if new state variables needed
3. Add module interactions through storage contract
4. Update hook if swap-time logic changes
5. Write comprehensive tests
6. Run gas optimization checks

### Testing Strategy
- Unit tests for individual modules
- Integration tests for hook functionality
- Gas usage verification for target <50k afterSwap
- Fork testing against live Uniswap V4 pools

### Deployment Sequence
The deployment script follows a specific order:
1. Deploy SpendSaveStorage
2. Deploy all modules
3. Deploy SpendSaveHook with address mining
4. Initialize storage with hook reference
5. Initialize modules with storage references
6. Register modules in storage registry
7. Set cross-module references

## Important Implementation Details

### Hook Requirements
- Must have proper address flags for Uniswap V4 compliance
- Requires beforeSwap, afterSwap, and delta return permissions
- Address mining ensures flag compliance during deployment

### Gas Efficiency Targets
- afterSwap execution: <50,000 gas
- Single storage reads for user configuration
- Batch operations for multiple updates
- Minimal external calls during swap execution

### Security Considerations
- Reentrancy protection on all external functions
- Module authorization system
- Owner-only administrative functions
- Input validation for all user-facing functions