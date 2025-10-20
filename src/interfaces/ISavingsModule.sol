// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SpendSaveStorage} from "../SpendSaveStorage.sol";
import {ISpendSaveModule} from "./ISpendSaveModule.sol";

/**
 * @title ISavingsModule
 * @notice Updated interface for optimized savings operations
 * @dev Supports batch operations and packed storage format
 */
interface ISavingsModule is ISpendSaveModule {
    
    // ==================== EVENTS ====================
    
    event SavingsProcessed(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 netAmount,
        uint256 fee
    );
    
    event BatchSavingsProcessed(
        address indexed user,
        uint256 totalAmount,
        uint256 totalFee
    );
    
    event WithdrawalProcessed(
        address indexed user,
        address indexed token,
        uint256 amount
    );
    
    // ==================== CORE FUNCTIONS ====================
    
    /**
     * @notice Process savings from a swap (optimized for hook usage)
     * @dev Should be gas-efficient for use in afterSwap
     * @param user The user address
     * @param token The token being saved
     * @param amount The total amount to save
     * @param context The swap context (for additional processing)
     * @return netAmount The amount saved after fees
     */
    function processSavings(
        address user,
        address token,
        uint256 amount,
        SpendSaveStorage.SwapContext memory context
    ) external returns (uint256 netAmount);
    
    /**
     * @notice Batch process multiple savings operations
     * @dev Gas-efficient batch operation for multiple tokens
     * @param user The user address
     * @param tokens Array of token addresses
     * @param amounts Array of amounts to save
     * @return totalNetAmount Total amount saved after fees
     */
    function batchProcessSavings(
        address user,
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external returns (uint256 totalNetAmount);
    
    /**
     * @notice Process savings with packed configuration
     * @dev Optimized version using packed storage format
     * @param user The user address
     * @param token The token address
     * @param amount The amount to save
     * @param packedConfig The packed user configuration
     * @return netAmount The amount saved after fees
     */
    function processSavingsOptimized(
        address user,
        address token,
        uint256 amount,
        SpendSaveStorage.PackedUserConfig memory packedConfig
    ) external returns (uint256 netAmount);
    
    // ==================== WITHDRAWAL FUNCTIONS ====================
    
    /**
     * @notice Withdraw savings for a user
     * @param user The user address
     * @param token The token to withdraw
     * @param amount The amount to withdraw
     * @param force Force withdrawal (may incur penalties)
     * @return actualAmount The actual amount withdrawn
     */
    function withdraw(
        address user,
        address token,
        uint256 amount,
        bool force
    ) external returns (uint256 actualAmount);
    
    /**
     * @notice Batch withdraw multiple tokens
     * @param user The user address
     * @param tokens Array of tokens to withdraw
     * @param amounts Array of amounts to withdraw
     * @return actualAmounts Array of actual amounts withdrawn
     */
    function batchWithdraw(
        address user,
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external returns (uint256[] memory actualAmounts);
    
    // ==================== CONFIGURATION FUNCTIONS ====================
    
    /**
     * @notice Set withdrawal timelock for a user
     * @param user The user address
     * @param timelock The timelock duration in seconds
     */
    function setWithdrawalTimelock(address user, uint256 timelock) external;
    
    /**
     * @notice Configure auto-compound settings
     * @param user The user address
     * @param token The token address
     * @param enableCompound Whether to enable auto-compounding
     * @param minCompoundAmount Minimum amount to trigger compound
     */
    function configureAutoCompound(
        address user,
        address token,
        bool enableCompound,
        uint256 minCompoundAmount
    ) external;
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Get user's total savings across all tokens
     * @param user The user address
     * @return tokens Array of token addresses
     * @return amounts Array of savings amounts
     */
    function getUserSavings(address user) external view returns (
        address[] memory tokens,
        uint256[] memory amounts
    );
    
    /**
     * @notice Get detailed savings info for a specific token
     * @param user The user address
     * @param token The token address
     * @return balance Current balance
     * @return totalSaved Total amount ever saved
     * @return lastSaveTime Last save timestamp
     * @return isLocked Whether withdrawals are locked
     * @return unlockTime When withdrawals unlock
     */
    function getSavingsDetails(address user, address token) external view returns (
        uint256 balance,
        uint256 totalSaved,
        uint256 lastSaveTime,
        bool isLocked,
        uint256 unlockTime
    );
    
    /**
     * @notice Calculate withdrawal amount after penalties
     * @param user The user address
     * @param token The token address
     * @param requestedAmount The amount user wants to withdraw
     * @return actualAmount Amount after penalties
     * @return penalty Penalty amount
     */
    function calculateWithdrawalAmount(
        address user,
        address token,
        uint256 requestedAmount
    ) external view returns (uint256 actualAmount, uint256 penalty);
    
    // ==================== INTEGRATION FUNCTIONS ====================
    
    /**
     * @notice Process savings from output token
     * @dev Called by hook after output amount is determined
     * @param user The user address
     * @param outputToken The output token from swap
     * @param outputAmount The total output amount
     * @param context The swap context
     * @return savedAmount Amount actually saved
     */
    function processSavingsFromOutput(
        address user,
        address outputToken,
        uint256 outputAmount,
        SpendSaveStorage.SwapContext memory context
    ) external returns (uint256 savedAmount);
    
    /**
     * @notice Process DCA queue addition during savings
     * @param user The user address
     * @param fromToken The token being saved
     * @param amount The amount to queue for DCA
     * @param targetToken The target token for DCA
     */
    function queueForDCA(
        address user,
        address fromToken,
        uint256 amount,
        address targetToken
    ) external;
    
    // ==================== EMERGENCY FUNCTIONS ====================
    
    /**
     * @notice Emergency withdrawal (owner only)
     * @param user The user address
     * @param token The token address
     * @param amount The amount to withdraw
     * @param recipient Where to send the funds
     */
    function emergencyWithdraw(
        address user,
        address token,
        uint256 amount,
        address recipient
    ) external;
    
    /**
     * @notice Pause all savings operations
     */
    function pauseSavings() external;
    
    /**
     * @notice Resume savings operations
     */
    function resumeSavings() external;
}