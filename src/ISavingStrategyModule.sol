// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import "./SpendSaveStorage.sol";
import "./ISpendSaveModule.sol";

// Strategy Module Interface
interface ISavingStrategyModule is ISpendSaveModule {
    function setSavingStrategy(
        address user,
        uint256 percentage,
        uint256 autoIncrement,
        uint256 maxPercentage,
        bool roundUpSavings,
        SpendSaveStorage.SavingsTokenType savingsTokenType,
        address specificSavingsToken
    ) external;
    
    function setSavingsGoal(address user, address token, uint256 amount) external;
    
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) external;
    
    function updateSavingStrategy(address sender, SpendSaveStorage.SwapContext memory context) external;
    
    function calculateSavingsAmount(
        uint256 amount,
        uint256 percentage,
        bool roundUp
    ) external pure returns (uint256);
}