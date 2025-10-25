# SpendSave Protocol

SpendSave is a DeFi protocol built on Uniswap V4 that enables automatic savings, dollar-cost averaging (DCA), and yield generation during token swaps. By intercepting swap transactions, SpendSave lets users build wealth passively as they interact with DeFi.

## 🌟 Features

- **Automatic Savings**: Save a percentage of tokens every time you swap
- **Flexible Strategies**: Configure how much and which tokens to save
- **Dollar-Cost Averaging**: Automatically convert saved tokens to a target token at optimal price points
- **Daily Savings**: Schedule regular savings independent of swaps
- **Yield Generation**: Apply different yield strategies to your saved tokens
- **ERC6909 Representation**: Your savings are represented as tokens in the protocol

## 🎯 Live Deployment & Transaction Proof

**✅ Protocol is LIVE and PROVEN on Base Sepolia!**

For complete transaction proof with all hashes and on-chain verification, see:
**[NEW-DEPLOYMENT-TRANSACTION-HASHES.md](./NEW-DEPLOYMENT-TRANSACTION-HASHES.md)**

**Key Proof:**
- 🏆 **18 confirmed transactions** on Base Sepolia (Block 32,802,845)
- 💰 **Savings extraction verified**: 0 → 1,000 units (10% exact match!)
- ✅ **100% accuracy**: Expected 1,000, got 1,000
- 🔍 **All transactions verifiable** on BaseScan

**Most Important Transaction (Savings Extraction):**
```
TX: 0x4f19214ca298d8c0af1bb3da729300ec2ca62c48324fa33fb7ddcb64b1a14c8d
View: https://sepolia.basescan.org/tx/0x4f19214ca298d8c0af1bb3da729300ec2ca62c48324fa33fb7ddcb64b1a14c8d
```

**Deployed Contracts:**
- SpendSaveHook: `0xc4ABf9A7bf8300086BBad164b4c47B1Afbbf00Cc`
- SpendSaveStorage: `0xC95A40D1b2914a72319735Db73c14183bC641fA2`
- SavingStrategy: `0x871cF56eFA79EBe9332e49143927b5E91b047253`
- Savings: `0xf5b264234B88e1a1c9FA7fc8D27022b0B7670Ddc`

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