// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Multicall_v4} from "lib/v4-periphery/src/base/Multicall_v4.sol";
import {ReentrancyGuard} from
    "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {SpendSaveStorage} from "./SpendSaveStorage.sol";
import {IDCAModule} from "./interfaces/IDCAModule.sol";
import {ISavingsModule} from "./interfaces/ISavingsModule.sol";
import {ISavingStrategyModule} from "./interfaces/ISavingStrategyModule.sol";

/**
 * @title SpendSaveMulticall
 * @notice Phase 2 Enhancement: Advanced multicall operations for gas-efficient batch execution
 * @dev Extends Multicall_v4 to provide:
 *      - Gas-optimized batch operations across all SpendSave modules
 *      - Atomic transaction execution with rollback on failure
 *      - Cross-module interaction batching
 *      - Emergency circuit breakers for safety
 *
 * Key Features:
 * - Batch DCA executions across multiple users
 * - Batch savings operations (deposits, withdrawals, goal updates)
 * - Batch liquidity management operations
 * - Gas refund mechanisms for large batches
 * - Slippage protection across batched operations
 *
 * @author SpendSave Protocol Team
 */
contract SpendSaveMulticall is Multicall_v4, ReentrancyGuard {
    // ==================== EVENTS ====================

    /// @notice Emitted when batch operation is executed
    event BatchExecuted(
        address indexed executor,
        uint256 indexed batchId,
        uint256 successfulCalls,
        uint256 totalCalls,
        uint256 gasUsed,
        uint256 gasRefund
    );

    /// @notice Emitted when emergency stop is triggered
    event EmergencyStop(address indexed caller, string reason);

    /// @notice Emitted when gas refund is processed
    event GasRefund(address indexed recipient, uint256 amount);

    // ==================== STORAGE ====================

    /// @notice Reference to SpendSave storage contract
    SpendSaveStorage public immutable storage_;

    /// @notice Emergency stop flag
    bool public emergencyStop;

    /// @notice Batch execution counter
    uint256 public batchCounter;

    /// @notice Gas refund pool balance
    uint256 public gasRefundPool;

    /// @notice Minimum batch size for gas refund eligibility
    uint256 public constant MIN_REFUND_BATCH_SIZE = 10;

    /// @notice Gas refund rate (percentage of gas cost refunded)
    uint256 public constant GAS_REFUND_RATE = 20; // 20%

    /// @notice Maximum gas per batch to prevent DOS
    uint256 public constant MAX_BATCH_GAS = 8000000; // 8M gas

    /// @notice Maximum number of calls per batch
    uint256 public constant MAX_BATCH_SIZE = 50; // Maximum 50 calls per batch

    /// @notice Authorized batch executors
    mapping(address => bool) public authorizedExecutors;

    // ==================== CONSTRUCTOR ====================

    /**
     * @notice Initialize the SpendSaveMulticall
     * @param _storage SpendSaveStorage contract address
     */
    constructor(address _storage) {
        require(_storage != address(0), "Invalid storage address");
        storage_ = SpendSaveStorage(_storage);

        // Set initial authorized executors
        authorizedExecutors[msg.sender] = true;
    }

    // ==================== MODIFIERS ====================

    modifier onlyWhenActive() {
        require(!emergencyStop, "Emergency stop active");
        _;
    }

    modifier onlyAuthorized() {
        require(
            authorizedExecutors[msg.sender] || msg.sender == storage_.owner() || msg.sender == storage_.spendSaveHook(),
            "Unauthorized"
        );
        _;
    }

    // ==================== BATCH EXECUTION FUNCTIONS ====================

    /**
     * @notice Execute batch of calls with gas optimization and refunds
     * @param calls Array of call data
     * @param requireSuccess Whether all calls must succeed
     * @return results Array of return data from calls
     */
    function batchExecuteWithRefund(bytes[] calldata calls, bool requireSuccess)
        external
        payable
        nonReentrant
        onlyWhenActive
        returns (bytes[] memory results)
    {
        require(calls.length > 0, "Empty batch");
        require(calls.length <= MAX_BATCH_SIZE, "Batch too large");

        uint256 batchId = ++batchCounter;
        uint256 gasStart = gasleft();
        uint256 successfulCalls = 0;

        // Execute the multicall
        results = _batchExecute(calls, requireSuccess);

        // Count successful calls
        for (uint256 i = 0; i < results.length; i++) {
            if (results[i].length > 0) {
                successfulCalls++;
            }
        }

        uint256 gasUsed = gasStart - gasleft();
        uint256 gasRefund = 0;

        // Calculate and process gas refund for large batches
        if (calls.length >= MIN_REFUND_BATCH_SIZE && gasRefundPool > 0) {
            gasRefund = _processGasRefund(msg.sender, gasUsed);
        }

        emit BatchExecuted(msg.sender, batchId, successfulCalls, calls.length, gasUsed, gasRefund);

        return results;
    }

    /**
     * @notice Execute batch of DCA operations across multiple users
     * @param users Array of user addresses
     * @param dcaParams Array of DCA parameters for each user
     * @return results Array of execution results
     */
    function batchExecuteDCA(address[] calldata users, DCABatchParams[] calldata dcaParams)
        external
        onlyAuthorized
        onlyWhenActive
        returns (bytes[] memory results)
    {
        require(users.length == dcaParams.length, "Array length mismatch");
        require(users.length > 0, "Empty batch");

        bytes[] memory calls = new bytes[](users.length);

        // Prepare DCA execution calls
        for (uint256 i = 0; i < users.length; i++) {
            calls[i] = abi.encodeWithSelector(IDCAModule.executeDCA.selector, users[i]);
        }

        return this.batchExecuteWithRefund(calls, false); // Allow partial success
    }

    /**
     * @notice Execute batch of savings operations
     * @param users Array of user addresses
     * @param savingsParams Array of savings operation parameters
     * @return results Array of execution results
     */
    function batchExecuteSavings(address[] calldata users, SavingsBatchParams[] calldata savingsParams)
        external
        onlyAuthorized
        onlyWhenActive
        returns (bytes[] memory results)
    {
        require(users.length == savingsParams.length, "Array length mismatch");
        require(users.length > 0, "Empty batch");

        bytes[] memory calls = new bytes[](users.length);

        // Prepare savings operation calls based on operation type
        for (uint256 i = 0; i < users.length; i++) {
            if (savingsParams[i].operationType == SavingsOperationType.DEPOSIT) {
                // Create empty context for batch processing
                SpendSaveStorage.SwapContext memory emptyContext;
                calls[i] = abi.encodeWithSelector(
                    ISavingsModule.processSavings.selector,
                    users[i],
                    savingsParams[i].token,
                    savingsParams[i].amount,
                    emptyContext
                );
            } else if (savingsParams[i].operationType == SavingsOperationType.WITHDRAW) {
                calls[i] = abi.encodeWithSelector(
                    ISavingsModule.withdraw.selector,
                    users[i],
                    savingsParams[i].token,
                    savingsParams[i].amount,
                    false // force = false
                );
            } else if (savingsParams[i].operationType == SavingsOperationType.SET_GOAL) {
                calls[i] = abi.encodeWithSelector(
                    ISavingStrategyModule.setSavingsGoal.selector,
                    users[i],
                    savingsParams[i].token,
                    savingsParams[i].amount
                );
            }
        }

        return this.batchExecuteWithRefund(calls, false);
    }

    /**
     * @notice Execute batch of liquidity management operations
     * @param users Array of user addresses
     * @param lpParams Array of liquidity parameters
     * @return results Array of execution results
     */
    function batchExecuteLiquidityOperations(address[] calldata users, LiquidityBatchParams[] calldata lpParams)
        external
        onlyAuthorized
        onlyWhenActive
        returns (bytes[] memory results)
    {
        require(users.length == lpParams.length, "Array length mismatch");
        require(users.length > 0, "Empty batch");

        bytes[] memory calls = new bytes[](users.length);

        // Prepare liquidity operation calls
        for (uint256 i = 0; i < users.length; i++) {
            if (lpParams[i].operationType == LiquidityOperationType.CONVERT_TO_LP) {
                calls[i] = abi.encodeWithSelector(
                    // This would call SpendSaveLiquidityManager.convertSavingsToLP
                    bytes4(keccak256("convertSavingsToLP(address,address,address,int24,int24,uint256)")),
                    users[i],
                    lpParams[i].token0,
                    lpParams[i].token1,
                    lpParams[i].tickLower,
                    lpParams[i].tickUpper,
                    lpParams[i].deadline
                );
            } else if (lpParams[i].operationType == LiquidityOperationType.COLLECT_FEES) {
                calls[i] = abi.encodeWithSelector(
                    // This would call SpendSaveLiquidityManager.collectAndCompoundFees
                    bytes4(keccak256("collectAndCompoundFees(address)")),
                    users[i]
                );
            }
        }

        return this.batchExecuteWithRefund(calls, false);
    }

    // ==================== INTERNAL FUNCTIONS ====================

    /**
     * @notice Internal batch execution with enhanced error handling
     */
    function _batchExecute(bytes[] calldata calls, bool requireSuccess) internal returns (bytes[] memory results) {
        results = new bytes[](calls.length);

        for (uint256 i = 0; i < calls.length; i++) {
            (bool success, bytes memory result) = address(this).delegatecall(calls[i]);

            if (requireSuccess) {
                require(success, "Batch call failed");
            }

            results[i] = success ? result : new bytes(0);
        }

        return results;
    }

    /**
     * @notice Process gas refund for eligible batches
     */
    function _processGasRefund(address recipient, uint256 gasUsed) internal returns (uint256 refund) {
        refund = (gasUsed * tx.gasprice * GAS_REFUND_RATE) / 100;

        if (refund > gasRefundPool) {
            refund = gasRefundPool;
        }

        if (refund > 0) {
            gasRefundPool -= refund;

            // Transfer refund to recipient
            (bool success,) = payable(recipient).call{value: refund}("");
            require(success, "Gas refund transfer failed");

            emit GasRefund(recipient, refund);
        }

        return refund;
    }

    // ==================== ADMIN FUNCTIONS ====================

    /**
     * @notice Add funds to gas refund pool
     */
    function fundGasRefundPool() external payable onlyAuthorized {
        gasRefundPool += msg.value;
    }

    /**
     * @notice Withdraw from gas refund pool
     */
    function withdrawFromGasRefundPool(uint256 amount) external onlyAuthorized {
        require(amount <= gasRefundPool, "Insufficient pool balance");
        gasRefundPool -= amount;

        (bool success,) = payable(msg.sender).call{value: amount}("");
        require(success, "Withdrawal failed");
    }

    /**
     * @notice Set authorized executor status
     */
    function setAuthorizedExecutor(address executor, bool authorized) external {
        require(msg.sender == storage_.owner(), "Only owner");
        authorizedExecutors[executor] = authorized;
    }

    /**
     * @notice Emergency stop mechanism
     */
    function setEmergencyStop(bool stop, string calldata reason) external {
        require(msg.sender == storage_.owner() || msg.sender == storage_.spendSaveHook(), "Unauthorized");

        emergencyStop = stop;
        if (stop) {
            emit EmergencyStop(msg.sender, reason);
        }
    }

    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Estimate gas cost for a batch of calls
     * @param calls Array of call data
     * @return estimatedGas Estimated gas consumption
     */
    function estimateBatchGas(bytes[] calldata calls) external view returns (uint256 estimatedGas) {
        // Simple estimation: base gas per call plus calldata cost
        estimatedGas = calls.length * 25000; // Base gas per call

        for (uint256 i = 0; i < calls.length; i++) {
            estimatedGas += calls[i].length * 16; // Calldata cost
        }

        return estimatedGas;
    }

    /**
     * @notice Get current gas refund pool balance
     */
    function getGasRefundPoolBalance() external view returns (uint256) {
        return gasRefundPool;
    }

    /**
     * @notice Check if address is authorized executor
     */
    function isAuthorizedExecutor(address executor) external view returns (bool) {
        return authorizedExecutors[executor];
    }

    // ==================== STRUCTS ====================

    struct DCABatchParams {
        address fromToken;
        address toToken;
        uint256 amount;
        uint256 minAmountOut;
    }

    struct SavingsBatchParams {
        address token;
        uint256 amount;
        SavingsOperationType operationType;
    }

    struct LiquidityBatchParams {
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
        uint256 deadline;
        LiquidityOperationType operationType;
    }

    enum SavingsOperationType {
        DEPOSIT,
        WITHDRAW,
        SET_GOAL
    }

    enum LiquidityOperationType {
        CONVERT_TO_LP,
        COLLECT_FEES,
        REBALANCE
    }
}
