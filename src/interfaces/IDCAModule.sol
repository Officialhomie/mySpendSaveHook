// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SpendSaveStorage} from "../SpendSaveStorage.sol";
import {ISpendSaveModule} from "./ISpendSaveModule.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

/**
 * @title IDCAModule
 * @notice Updated interface for DCA operations with gas optimizations
 * @dev Supports batch operations and efficient queue management
 */
interface IDCAModule is ISpendSaveModule {
    // ==================== EVENTS ====================

    event DCAEnabled(address indexed user, address indexed targetToken);
    event DCAExecuted(address indexed user, address indexed fromToken, address indexed toToken, uint256 amount);
    event DCAQueued(address indexed user, address indexed fromToken, address indexed toToken, uint256 amount);
    event TickStrategySet(address indexed user, int24 lowerTick, int24 upperTick);

    // ==================== STRUCTS ====================

    struct DCAConfig {
        bool enabled;
        address targetToken;
        uint256 minAmount;
        uint256 maxSlippage;
        int24 lowerTick;
        int24 upperTick;
    }

    struct DCAExecution {
        address fromToken;
        address toToken;
        uint256 amount;
        uint256 timestamp;
        uint256 executedPrice;
    }

    // ==================== CORE FUNCTIONS ====================

    /**
     * @notice Enable DCA for a user
     * @param user The user address
     * @param targetToken The target token for DCA
     * @param minAmount Minimum amount to trigger DCA
     * @param maxSlippage Maximum acceptable slippage (in basis points)
     */
    function enableDCA(address user, address targetToken, uint256 minAmount, uint256 maxSlippage) external;

    /**
     * @notice Disable DCA for a user
     * @param user The user address
     */
    function disableDCA(address user) external;

    /**
     * @notice Set tick-based DCA strategy
     * @param user The user address
     * @param lowerTick Lower tick bound for DCA execution
     * @param upperTick Upper tick bound for DCA execution
     */
    function setDCATickStrategy(address user, int24 lowerTick, int24 upperTick) external;

    /**
     * @notice Queue tokens for DCA execution
     * @dev Optimized for gas efficiency in swap path
     * @param user The user address
     * @param fromToken The token to convert from
     * @param toToken The token to convert to
     * @param amount The amount to queue
     */
    function queueDCAExecution(address user, address fromToken, address toToken, uint256 amount) external;

    /**
     * @notice Execute pending DCA for a user
     * @dev Called by keeper or user
     * @param user The user address
     * @return executed Whether any DCA was executed
     * @return totalAmount Total amount converted
     */
    function executeDCA(address user) external returns (bool executed, uint256 totalAmount);

    /**
     * @notice Batch execute DCA for multiple users
     * @dev Gas-efficient batch operation for keepers
     * @param users Array of user addresses
     * @return executions Array of execution results
     */
    function batchExecuteDCA(address[] calldata users) external returns (DCAExecution[] memory executions);

    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Get user's DCA configuration
     * @param user The user address
     * @return config The DCA configuration
     */
    function getDCAConfig(address user) external view returns (DCAConfig memory config);

    /**
     * @notice Get pending DCA queue for a user
     * @param user The user address
     * @return tokens Array of from tokens
     * @return amounts Array of amounts
     * @return targets Array of target tokens
     */
    function getPendingDCA(address user)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts, address[] memory targets);

    /**
     * @notice Check if DCA should execute based on current tick
     * @param user The user address
     * @param poolKey The pool key to check
     * @return shouldExecute Whether DCA should execute
     * @return currentTick The current pool tick
     */
    function shouldExecuteDCA(address user, PoolKey calldata poolKey)
        external
        view
        returns (bool shouldExecute, int24 currentTick);

    /**
     * @notice Calculate optimal DCA execution amount
     * @param user The user address
     * @param fromToken The source token
     * @param toToken The target token
     * @param availableAmount Amount available for DCA
     * @return optimalAmount The optimal amount to execute
     */
    function calculateOptimalDCAAmount(address user, address fromToken, address toToken, uint256 availableAmount)
        external
        view
        returns (uint256 optimalAmount);

    // ==================== INTEGRATION FUNCTIONS ====================

    /**
     * @notice Process DCA after savings
     * @dev Called by savings module when DCA is enabled
     * @param user The user address
     * @param savedToken The token that was saved
     * @param savedAmount The amount that was saved
     * @param context The swap context
     * @return queued Whether tokens were queued for DCA
     */
    function processDCAFromSavings(
        address user,
        address savedToken,
        uint256 savedAmount,
        SpendSaveStorage.SwapContext memory context
    ) external returns (bool queued);

    /**
     * @notice Get DCA execution history
     * @param user The user address
     * @param limit Maximum number of records to return
     * @return history Array of DCA executions
     */
    function getDCAHistory(address user, uint256 limit) external view returns (DCAExecution[] memory history);
}
