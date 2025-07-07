// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../SpendSaveStorage.sol";
import "./ISpendSaveModule.sol";

interface IDailySavingsModule is ISpendSaveModule {
    function configureDailySavings(
        address user,
        address token,
        uint256 dailyAmount,
        uint256 goalAmount,
        uint256 penaltyBps,
        uint256 endTime
    ) external;
    
    function disableDailySavings(address user, address token) external;
    
    function executeDailySavings(address user) external returns (uint256);
    
    function executeDailySavingsForToken(address user, address token) external returns (uint256);
    
    function withdrawDailySavings(address user, address token, uint256 amount) external returns (uint256);
    
    function setDailySavingsYieldStrategy(address user, address token, SpendSaveStorage.YieldStrategy strategy) external;
    
    function hasPendingDailySavings(address user) external view returns (bool);
    
    function getDailyExecutionStatus(address user, address token) external view returns (
        bool canExecute,
        uint256 daysPassed,
        uint256 amountToSave
    );
    
    function getDailySavingsStatus(address user, address token) external view returns (
        bool enabled,
        uint256 dailyAmount,
        uint256 goalAmount,
        uint256 currentAmount,
        uint256 remainingAmount,
        uint256 penaltyAmount,
        uint256 estimatedCompletionDate
    );

    /**
    * @notice Execute token savings for a specific user and token
    * @param user The user address
    * @param token The token address
    * @return amount The amount saved
    */
    function executeTokenSavings(address user, address token) external returns (uint256 amount);
}