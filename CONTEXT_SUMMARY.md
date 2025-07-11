# SpendSaveHook Smart Contract Project - Context Summary

## Project Overview

This is a Solidity smart contract project implementing a comprehensive savings and DCA (Dollar Cost Averaging) system using Uniswap V4 hooks. The project consists of multiple modular contracts that work together to provide automated savings functionality.

## Architecture

### Core Components

1. **SpendSaveHook.sol** - Main hook contract that integrates with Uniswap V4
2. **SpendSaveStorage.sol** - Centralized storage contract for all module data
3. **Token.sol** - ERC6909 token wrapper for savings tokens
4. **DCA.sol** - Dollar Cost Averaging module
5. **Savings.sol** - Core savings functionality
6. **SavingStrategy.sol** - Strategy management for savings
7. **SlippageControl.sol** - Slippage protection mechanisms
8. **DailySavings.sol** - Daily automated savings functionality

### Module Reference Pattern

All modules implement a standardized module reference pattern:

```solidity
// Internal module references (with leading underscore to avoid shadowing)
address internal _savingStrategyModule;
address internal _savingsModule;
address internal _dcaModule;
address internal _slippageModule;
address internal _tokenModule;
address internal _dailySavingsModule;

// Setter function
function setModuleReferences(
    address _savingStrategy,
    address _savings,
    address _dca,
    address _slippage,
    address _token,
    address _dailySavings
) external override onlyOwner {
    _savingStrategyModule = _savingStrategy;
    _savingsModule = _savings;
    _dcaModule = _dca;
    _slippageModule = _slippage;
    _tokenModule = _token;
    _dailySavingsModule = _dailySavings;
    
    emit ModuleReferencesSet();
}
```

## Current State

### ✅ Completed Work

1. **Module Reference Standardization**: All modules now implement the standardized `setModuleReferences` pattern
2. **Interface Implementation**: Missing interface functions have been implemented in Token.sol and DCA.sol
3. **Event Fixes**: Fixed event emission argument counts in SpendSaveHook.sol and DCA.sol
4. **Naming Conflicts**: Resolved variable shadowing by using leading underscores for internal module references

### 🔧 Recent Fixes Applied

#### Token.sol
- Implemented missing ERC6909 functions: `approve` and `transferFrom`
- Used correct storage functions for allowances and balances

#### DCA.sol
- Implemented missing interface functions:
  - `getDCAConfig`
  - `getPendingDCA`
  - `shouldExecuteDCA`
  - `calculateOptimalDCAAmount`
  - `processDCAFromSavings`
  - `getDCAHistory`
- Added poolManager reference
- Fixed internal/external function naming conflicts for `queueDCAExecution`

## 🚨 Current Issues to Resolve

### 1. Type Mismatches in PoolKey Construction

**Location**: DCA.sol in `processDCAFromSavings` function
**Issue**: PoolKey construction has type mismatches
**Error**: 
```
TypeError: Invalid type for argument in function call. Invalid implicit conversion from uint24 to uint160 requested.
```

**Code causing issue**:
```solidity
PoolKey memory poolKey = PoolKey({
    currency0: Currency.wrap(token),
    currency1: Currency.wrap(address(0)), // WETH address needed
    fee: 3000,
    hooks: IHooks(address(0)),
    tickSpacing: 60
});
```

**Fix needed**: 
- Replace `address(0)` with actual WETH address
- Ensure proper currency wrapping
- Verify fee and tickSpacing values match Uniswap V4 requirements

### 2. Missing `setDCATickStrategy` Function

**Location**: DCA.sol
**Issue**: Function signature mismatch in interface implementation
**Error**: 
```
TypeError: Function "setDCATickStrategy" is missing implementation.
```

**Required signature**:
```solidity
function setDCATickStrategy(
    address user,
    address token,
    uint24 fee,
    int24 tickLower,
    int24 tickUpper
) external override onlyAuthorized(user) {
    // Implementation needed
}
```

### 3. Missing `getSlot0` Function in IPoolManager

**Location**: DCA.sol
**Issue**: Interface function not found in IPoolManager
**Error**:
```
TypeError: Member "getSlot0" not found or not visible after argument-dependent lookup in type "contract IPoolManager".
```

**Fix needed**: 
- Check if `getSlot0` exists in the IPoolManager interface
- If not, implement alternative method to get pool state
- Consider using `getSlot0` from the pool itself rather than poolManager

### 4. Variable Shadowing Warnings

**Location**: Multiple files
**Issue**: Internal variables shadowing external ones
**Warning**: 
```
Warning: This declaration shadows an existing declaration.
```

**Files affected**:
- DCA.sol: `_poolManager` shadows `poolManager`
- Token.sol: `_storage` shadows `storage_`

**Fix needed**: Rename internal variables to avoid shadowing

## 🔍 Technical Details

### Dependencies
- **Foundry**: Development framework
- **Uniswap V4**: Core DEX integration
- **OpenZeppelin**: Security contracts
- **ERC6909**: Multi-token standard for savings tokens

### Key Interfaces
- `IDCAModule.sol` - DCA functionality interface
- `ITokenModule.sol` - Token management interface
- `IDailySavingsModule.sol` - Daily savings interface
- `ISavingsModule.sol` - Core savings interface

### Storage Pattern
All modules use `SpendSaveStorage.sol` as the centralized storage contract, with module-specific storage functions.

## 🎯 Next Steps

### Immediate Priority (Critical Issues)
1. **Fix PoolKey construction** in DCA.sol
   - Replace `address(0)` with WETH address
   - Verify currency wrapping syntax
   - Check fee and tickSpacing values

2. **Implement `setDCATickStrategy`** in DCA.sol
   - Add proper implementation with storage updates
   - Include validation logic

3. **Resolve `getSlot0` issue**
   - Check IPoolManager interface for correct function name
   - Implement alternative if function doesn't exist

4. **Fix variable shadowing**
   - Rename internal variables in DCA.sol and Token.sol

### Secondary Priority
1. **Test compilation** after fixes
2. **Run test suite** to ensure functionality
3. **Gas optimization** review
4. **Security audit** of recent changes

## 🛠️ Development Environment

### Build Commands
```bash
# Compile contracts
forge build

# Run tests
forge test

# Check for issues
forge build --force
```

### Key Files to Focus On
1. `src/DCA.sol` - Main issues are here
2. `src/Token.sol` - Variable shadowing fix needed
3. `src/interfaces/` - Interface definitions
4. `src/SpendSaveStorage.sol` - Storage contract

## 📋 Code Style Notes

- Use leading underscores for internal module reference variables to avoid shadowing
- Follow the established module reference pattern
- Use proper error handling with custom errors
- Implement reentrancy guards where needed
- Use SafeERC20 for token transfers

## 🔗 Related Resources

- Uniswap V4 documentation for PoolKey structure
- ERC6909 standard for multi-token implementation
- Foundry documentation for testing and deployment

---

**Note**: This project is actively being developed and the issues listed above are blocking successful compilation. Focus on resolving the type mismatches and missing implementations first, then proceed with testing and optimization. 