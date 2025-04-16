// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SpendSaveStorage.sol";
import "./ISpendSaveModule.sol";

/**
 * @title ISavingsModule
 * @dev Interface for the savings module functionality
 */
interface ISavingsModule is ISpendSaveModule {
    /**
     * @dev Process savings for a specific token
     * @param user Address of the user
     * @param token Token address
     * @param amount Amount to process
     */
    function processSavings(
        address user,
        address token,
        uint256 amount
    ) external;

    /**
     * @dev Process savings from a swap output
     * @param user Address of the user
     * @param token Token address
     * @param amount Amount to process
     * @param context The swap context
     */
    function processSavingsFromOutput(
        address user, 
        address token, 
        uint256 amount, 
        SpendSaveStorage.SwapContext memory context
    ) external;
    
    /**
     * @dev Process savings to a specific token
     * @param user Address of the user
     * @param outputToken Token address
     * @param outputAmount Amount to process
     * @param context The swap context
     */
    function processSavingsToSpecificToken(
        address user,
        address outputToken,
        uint256 outputAmount,
        SpendSaveStorage.SwapContext memory context
    ) external;
    
    /**
     * @dev Withdraw savings
     * @param user Address of the user
     * @param token Token address
     * @param amount Amount to withdraw
     */
    function withdrawSavings(
        address user,
        address token,
        uint256 amount
    ) external;

    /**
     * @dev Process input savings after swap
     * @param user Address of the user
     * @param token Token address
     * @param amount Amount to process
     */
    function processInputSavingsAfterSwap(
        address user,
        address token,
        uint256 amount
    ) external;
    
    /**
     * @dev Deposit savings
     * @param user Address of the user
     * @param token Token address
     * @param amount Amount to deposit
     */
    function depositSavings(
        address user,
        address token,
        uint256 amount
    ) external;
    
    /**
     * @dev Set withdrawal timelock
     * @param user Address of the user
     * @param timelock Timelock period
     */
    function setWithdrawalTimelock(address user, uint256 timelock) external;
}