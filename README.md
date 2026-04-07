# SpendSave Protocol

SpendSave is a DeFi protocol built on Uniswap V4 that enables automatic savings, dollar-cost averaging (DCA), and yield generation during token swaps. By intercepting swap transactions, SpendSave lets users build wealth passively as they interact with DeFi.

## 🌟 Features

- **Automatic Savings**: Save a percentage of tokens every time you swap
- **Flexible Strategies**: Configure how much and which tokens to save
- **Dollar-Cost Averaging**: Automatically convert saved tokens to a target token at optimal price points
- **Daily Savings**: Schedule regular savings independent of swaps
- **Yield Generation**: Apply different yield strategies to your saved tokens
- **ERC6909 Representation**: Your savings are represented as tokens in the protocol

## 🎯 Live Deployment & Complete Documentation

**✅ Protocol is LIVE and FULLY OPERATIONAL on Base Sepolia!**

### 📋 **Complete Deployment Report**

For comprehensive protocol information including all addresses, transactions, and end-to-end test results, see:

**👉 [DEPLOYMENT_REPORT.md](./DEPLOYMENT_REPORT.md)** 👈

This report includes:
- ✅ All contract addresses with checksummed EIP-55 format
- ✅ Complete deployment transactions with BaseScan links
- ✅ **End-to-end test results proving savings extraction works**
- ✅ Gas usage analysis (swap with savings: only **46,343 gas**)
- ✅ Frontend integration code snippets
- ✅ Pool configuration details

### 🎉 Latest Test Results (Proven On-Chain)

**Test Date:** October 26, 2024  
**Block:** 32,865,325  
**Status:** ✅ **100% SUCCESSFUL**

**Proof of Savings Extraction:**
- Swapped: 10,000 USDC
- Savings Extracted: **1,000 USDC (exactly 10%)**
- Accuracy: **100% match**
- Gas Used: **46,343 gas**
- Transaction: [`0x89c3cced97ba12076d54d6831583cf2fde9066b63f74b7c708a30d6e6e2e73e6`](https://sepolia.basescan.org/tx/0x89c3cced97ba12076d54d6831583cf2fde9066b63f74b7c708a30d6e6e2e73e6)

### 📍 Core Contract Addresses (Base Sepolia)

| Contract | Address | BaseScan Link |
|----------|---------|---------------|
| **SpendSaveHook** | `0xB149651E7C60E561148AbD5a31a6ad6ba25c40cc` | [View](https://sepolia.basescan.org/address/0xB149651E7C60E561148AbD5a31a6ad6ba25c40cc) |
| **SpendSaveStorage** | `0x12256e69595E5949E05ba48Ab0926032e1e85484` | [View](https://sepolia.basescan.org/address/0x12256e69595E5949E05ba48Ab0926032e1e85484) |
| **SavingStrategy** | `0x023EaC31560eBdD6304d6EB5d3D95994c8256d04` | [View](https://sepolia.basescan.org/address/0x023EaC31560eBdD6304d6EB5d3D95994c8256d04) |
| **Savings** | `0x8339b29c63563E2Da73f3F4238b9C602F9aaE14F` | [View](https://sepolia.basescan.org/address/0x8339b29c63563E2Da73f3F4238b9C602F9aaE14F) |
| **Pool Manager** | `0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408` | [View](https://sepolia.basescan.org/address/0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408) |

> 📖 **For complete list of all modules and enhancement contracts, see [DEPLOYMENT_REPORT.md](./DEPLOYMENT_REPORT.md)**

### 📝 Frontend Integration Quick Start

```typescript
// Core Addresses
const SPENDSAVE_HOOK = "0xB149651E7C60E561148AbD5a31a6ad6ba25c40cc";
const POOL_MANAGER = "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408";
const STORAGE = "0x12256e69595E5949E05ba48Ab0926032e1e85484";
const SAVING_STRATEGY = "0x023EaC31560eBdD6304d6EB5d3D95994c8256d04";

// Tokens (Base Sepolia)
const USDC = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
const WETH = "0x4200000000000000000000000000000000000006";

// Example: Set 10% savings strategy
await savingStrategy.setSavingStrategy(
    userAddress,
    1000, // 10%
    0,
    10000,
    false,
    0, // INPUT token type
    ethers.constants.AddressZero
);

// Execute swap through pool with hook
await swapRouter.swap(poolKey, swapParams, settings, hookData);
```

> 📖 **For complete integration guide with ABIs, see [DEPLOYMENT_REPORT.md](./DEPLOYMENT_REPORT.md)**

## 📐 Protocol Architecture

SpendSave is built with a modular architecture consisting of:

- **SpendSaveHook**: The main entry point that integrates with Uniswap V4 hooks
- **SpendSaveStorage**: Central contract that stores all protocol state
- **Specialized Modules**:
  - **SavingStrategy**: Controls savings preferences and rules
  - **Savings**: Manages deposits and withdrawals
  - **DCA**: Handles dollar-cost averaging execution
  - **Token**: Represents savings as ERC6909 tokens
  - **SlippageControl**: Controls slippage parameters for operations
  - **DailySavings**: Manages regular savings plans
  - **Yield**: Applies yield strategies to saved tokens (coming soon)

## 💡 How It Works

1. **Hook Integration**: SpendSave hooks into Uniswap V4 swap functions
2. **Savings Diversion**: When a user swaps tokens, a portion is diverted to savings based on their preferences
3. **Strategy Application**: The protocol applies the user's configured saving strategy
4. **Optional DCA**: Saved tokens can be automatically converted to a target token
5. **Yield Application**: Tokens can be deployed to yield-generating protocols
6. **Withdrawals**: Users can withdraw their savings at any time (subject to optional timelocks)

## 🎛️ User Configuration Options

- **Savings Percentage**: Set how much to save (0-100%)
- **Auto-Increment**: Gradually increase savings percentage over time
- **Token Selection**: Save input tokens, output tokens, or a specific token
- **DCA Target**: Set a specific token to accumulate
- **Tick Strategies**: Set price conditions for optimal DCA execution
- **Daily Savings**: Configure regular daily contributions
- **Yield Strategies**: Select how to generate returns (Aave, Compound, Uniswap LP, etc.)

## 📊 Use Cases

- **Passive Investing**: Build savings automatically while using DeFi
- **Dollar-Cost Averaging**: Gradually build positions in target tokens
- **Automated Savings Plans**: Set and forget regular savings
- **Yield Optimization**: Earn returns on saved tokens

## 🛠️ Implementation Details

SpendSave leverages Uniswap V4 hooks to intercept transactions without modifying core functionality. The modular architecture allows for easy upgrades and component replacements.

Key technical aspects:
- Uniswap V4 hook integration
- ERC6909 token standard for savings representation
- Gas-optimized execution for Ethereum mainnet
- Comprehensive security measures including reentrancy protection

## 🚀 Getting Started

### Prerequisites

- Uniswap V4 deployment
- Ethereum development environment

### Installation

```shell
# Clone the repository
git clone https://github.com/Officialhomie/mySpendSaveHook.git
cd spend-save-protocol

# Install dependencies
forge install

# Build the project
forge build
```

### Deployment

```shell
# Deploy the protocol
forge script script/DeploySpendSave.s.sol:DeploySpendSaveScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Interacting with the Protocol

```solidity
// Example: Set a saving strategy
savingStrategyModule.setSavingStrategy(
    userAddress,
    1000, // 10% savings
    100,  // 1% auto-increment
    5000, // 50% max savings
    true, // round up savings
    SavingsTokenType.OUTPUT, // save output tokens
    address(0) // no specific token
);

// Example: Configure daily savings
dailySavingsModule.configureDailySavings(
    userAddress,
    tokenAddress,
    100 * 10**18, // 100 tokens per day
    5000 * 10**18, // 5000 tokens goal
    500, // 5% penalty for early withdrawal
    block.timestamp + 365 days // 1 year target
);
```

## 💻 Development

This project uses Foundry for development and testing.

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Local Development

```shell
$ anvil
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the project
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 📬 Contact

Project Link: [https://github.com/Officialhomie/mySpendSaveHook.git]