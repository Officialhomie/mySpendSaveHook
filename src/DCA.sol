// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {BalanceDelta} from "lib/v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {TickMath} from "lib/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "lib/v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {ReentrancyGuard} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {SwapParams} from "lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";

import "./SpendSaveStorage.sol";
import "./interfaces/IDCAModule.sol";
import "./interfaces/ITokenModule.sol";
import "./interfaces/ISlippageControlModule.sol";
import "./interfaces/ISavingsModule.sol";

/**
 * @title DCA
 * @dev Manages dollar-cost averaging functionality
 */
contract DCA is IDCAModule, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    
    // Constants
    uint24 private constant DEFAULT_FEE_TIER = 3000; // 0.3%
    int24 private constant DEFAULT_TICK_SPACING = 60;
    uint256 private constant MAX_MULTIPLIER = 100; // Maximum 2x multiplier (100%)

    struct SwapExecutionParams {
        uint256 amount;
        uint256 minAmountOut;
        uint160 sqrtPriceLimitX96;
    }

    struct SwapExecutionResult {
        uint256 receivedAmount;
        bool success;
    }
    
    struct TickMovement {
        int24 delta;
        bool isPositive;
    }

    // Storage reference
    SpendSaveStorage public storage_;
    
    // Module references
    ITokenModule public tokenModule;
    ISlippageControlModule public slippageModule;
    ISavingsModule public savingsModule;
    
    // Pool manager reference for tick operations
    IPoolManager public poolManager;
    
    // Standardized module references
    address internal _savingStrategyModule;
    address internal _savingsModule;
    address internal _dcaModule;
    address internal _slippageModule;
    address internal _tokenModule;
    address internal _dailySavingsModule;
    
    // Events
    event DCAEnabled(address indexed user, address indexed targetToken, bool enabled);
    event DCADisabled(address indexed user);
    event DCATickStrategySet(address indexed user, int24 tickDelta, uint256 tickExpiryTime, bool onlyImprovePrice);
    event DCAQueued(address indexed user, address fromToken, address toToken, uint256 amount, int24 executionTick);
    event DCAExecuted(address indexed user, address fromToken, address toToken, uint256 fromAmount, uint256 toAmount);
    event TickUpdated(PoolId indexed poolId, int24 oldTick, int24 newTick);
    event ModuleReferencesSet(address tokenModule, address slippageModule, address savingsModule);
    event ModuleInitialized(address storage_);
    event TreasuryFeeCollected(address indexed user, address token, uint256 amount);
    event TransferFailure(address indexed user, address token, uint256 amount, bytes reason);
    event SwapExecutionZeroOutput(uint256 amount, bool zeroForOne);
    event SpecificTokenSwapProcessed(
        address indexed user,
        address indexed fromToken,
        address indexed toToken,
        uint256 inputAmount,
        uint256 outputAmount
    );

    event SpecificTokenSwapFailed(
        address indexed user,
        address indexed fromToken,
        address indexed toToken,
        string reason
    );
    
    // Custom errors
    error DCANotEnabled();
    error NoTargetTokenSet();
    error InsufficientSavings(address token, uint256 requested, uint256 available);
    error InvalidDCAExecution();
    error ZeroAmountSwap();
    error SwapExecutionFailed();
    error SlippageToleranceExceeded(uint256 received, uint256 expected);
    error AlreadyInitialized();
    error OnlyOwner();
    error UnauthorizedCaller();
    error TokenTransferFailed();
    error InvalidTickBounds();
    
    // Constructor is empty since module will be initialized via initialize()
    constructor() {}

    modifier onlyAuthorized(address user) {
        if (!_isAuthorizedCaller(user)) {
            revert UnauthorizedCaller();
        }
        _;
    }
    
    modifier onlyOwner() {
        if (msg.sender != storage_.owner()) {
            revert OnlyOwner();
        }
        _;
    }
    
    // Helper for authorization check
    function _isAuthorizedCaller(address user) internal view returns (bool) {
        return (msg.sender == user || 
                msg.sender == address(storage_) || 
                msg.sender == storage_.spendSaveHook());
    }
    
    // Initialize module with storage reference
    function initialize(SpendSaveStorage _storage) external override nonReentrant {
        if (address(storage_) != address(0)) {
            revert AlreadyInitialized();
        }
        storage_ = _storage;
        emit ModuleInitialized(address(_storage));
    }
    
    // Set references to other modules
    function setModuleReferences(
        address _savingStrategy,
        address _savings,
        address _dca,
        address _slippage,
        address _token,
        address _dailySavings
    ) external override nonReentrant onlyOwner {
        _savingStrategyModule = _savingStrategy;
        _savingsModule = _savings;
        _dcaModule = _dca;
        _slippageModule = _slippage;
        _tokenModule = _token;
        _dailySavingsModule = _dailySavings;
        
        // Set the typed references for backward compatibility
        tokenModule = ITokenModule(_token);
        slippageModule = ISlippageControlModule(_slippage);
        savingsModule = ISavingsModule(_savings);
        
        // Set pool manager reference from storage
        poolManager = IPoolManager(storage_.poolManager());
        
        emit ModuleReferencesSet(_tokenModule, _slippageModule, _savingsModule);
    }
    
    // Helper function to get current strategy parameters
    function _getCurrentStrategyParams(address user) internal view returns (
        uint256 percentage,
        uint256 autoIncrement,
        uint256 maxPercentage,
        uint256 goalAmount,
        bool roundUpSavings,
        SpendSaveStorage.SavingsTokenType savingsTokenType,
        address specificSavingsToken
    ) {
        // Instead of destructuring, get the whole struct and access fields directly
        SpendSaveStorage.SavingStrategy memory strategy = storage_.getUserSavingStrategy(user);
        
        // Then access the fields you need directly from the struct:
        percentage = strategy.percentage;
        autoIncrement = strategy.autoIncrement;
        maxPercentage = strategy.maxPercentage;
        goalAmount = strategy.goalAmount;
        roundUpSavings = strategy.roundUpSavings;
        // Note: we ignore enableDCA here as it's not needed for this function
        savingsTokenType = strategy.savingsTokenType;
        specificSavingsToken = strategy.specificSavingsToken;
        
        return (
            percentage,
            autoIncrement,
            maxPercentage,
            goalAmount,
            roundUpSavings,
            savingsTokenType,
            specificSavingsToken
        );
    }

    // Enable DCA into a target token
    function enableDCA(
        address user,
        address targetToken,
        uint256 minAmount,
        uint256 maxSlippage
    ) external override onlyAuthorized(user) nonReentrant {
        // Get current strategy parameters
        (
            uint256 percentage,
            uint256 autoIncrement,
            uint256 maxPercentage,
            uint256 goalAmount,
            bool roundUpSavings,
            SpendSaveStorage.SavingsTokenType savingsTokenType,
            address specificSavingsToken
        ) = _getCurrentStrategyParams(user);
        
        // Update the strategy with the new enableDCA value
        _updateSavingStrategy(
            user,
            percentage,
            autoIncrement,
            maxPercentage,
            goalAmount,
            roundUpSavings,
            true, // Assuming enableDCA is true for this function
            savingsTokenType,
            specificSavingsToken,
            targetToken
        );
        
        emit DCAEnabled(user, targetToken, true);
    }
    
    // Helper to update saving strategy
    function _updateSavingStrategy(
        address user,
        uint256 percentage,
        uint256 autoIncrement,
        uint256 maxPercentage,
        uint256 goalAmount,
        bool roundUpSavings,
        bool enableDCAFlag,
        SpendSaveStorage.SavingsTokenType savingsTokenType,
        address specificSavingsToken,
        address targetToken
    ) internal {
        // Create a complete SavingStrategy struct with all the values
        SpendSaveStorage.SavingStrategy memory newStrategy = SpendSaveStorage.SavingStrategy({
            percentage: percentage,
            autoIncrement: autoIncrement,
            maxPercentage: maxPercentage,
            goalAmount: goalAmount,
            roundUpSavings: roundUpSavings,
            enableDCA: enableDCAFlag,  // This is the DCA setting we're updating
            savingsTokenType: savingsTokenType,
            specificSavingsToken: specificSavingsToken  // Keep the original specific token
        });
        
        // Then call the method that actually exists in SpendSaveStorage
        storage_.setSavingStrategy(user, newStrategy);
        
        // Note: DCA target token is handled separately in the DCA module
        // The targetToken parameter is used for DCA execution, not for the savings strategy
    }

    // Helper function to get the current custom slippage tolerance
    function _getCurrentCustomSlippageTolerance(address user) internal view returns (uint256) {
        (,,,,,uint256 customSlippageTolerance) = storage_.getDcaTickStrategy(user);
        return customSlippageTolerance;
    }
 
    // Set DCA tick strategy
    function setDCATickStrategy(
        address user,
        int24 lowerTick,
        int24 upperTick
    ) external override onlyAuthorized(user) nonReentrant {
        // Validate tick bounds
        if (lowerTick >= upperTick) revert InvalidTickBounds();
        
        // Update the strategy in storage
        storage_.setDcaTickStrategy(
            user,
            lowerTick,
            upperTick
        );
        
        emit TickStrategySet(user, lowerTick, upperTick);
    }
    
    // Queue DCA from a savings token generated in a swap
    function queueDCAFromSwap(
        address user,
        address fromToken,
        SpendSaveStorage.SwapContext memory context
    ) external onlyAuthorized(user) nonReentrant {
        // Validate conditions for DCA queue
        if (!_shouldQueueDCA(context, fromToken)) return;
        
        // Get savings amount for this token
        uint256 amount = storage_.savings(user, fromToken);
        if (amount == 0) return;
        
        // Create the pool key and queue the DCA execution
        PoolKey memory poolKey = storage_.createPoolKey(fromToken, context.dcaTargetToken);
        
        _queueDCAExecutionInternal(
            user,
            fromToken,
            context.dcaTargetToken,
            amount,
            poolKey,
            context.currentTick,
            0 // No custom slippage, use default
        );
    }
    
    // Helper to check if DCA should be queued
    function _shouldQueueDCA(SpendSaveStorage.SwapContext memory context, address fromToken) internal pure returns (bool) {
        return context.enableDCA && 
               context.dcaTargetToken != address(0) && 
               fromToken != context.dcaTargetToken;
    }

    // Helper function to determine whether the swap is zeroForOne
      function _isZeroForOne(address fromToken, address toToken) internal pure returns (bool) {
        return fromToken < toToken;
    }

    // Helper to get execution tick and deadline
    function _getExecutionDetails(
        address user,
        PoolKey memory poolKey, 
        int24 currentTick, 
        bool zeroForOne
    ) internal view returns (int24 executionTick, uint256 deadline) {
        executionTick = calculateDCAExecutionTick(user, poolKey, currentTick, zeroForOne);
        
        // Get tick expiry time
        (,uint256 tickExpiryTime,,,,) = storage_.getDcaTickStrategy(user);
        
        deadline = block.timestamp + tickExpiryTime;
        return (executionTick, deadline);
    }

    /**
     * @notice Queue tokens for DCA execution
     * @dev Optimized for gas efficiency in swap path
     * @param user The user address
     * @param fromToken The token to convert from
     * @param toToken The token to convert to
     * @param amount The amount to queue
     */
    function queueDCAExecution(
        address user,
        address fromToken,
        address toToken,
        uint256 amount
    ) external override onlyAuthorized(user) nonReentrant {
        // Create pool key for the token pair
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(fromToken < toToken ? fromToken : toToken),
            currency1: Currency.wrap(fromToken < toToken ? toToken : fromToken),
            fee: DEFAULT_FEE_TIER,
            hooks: IHooks(address(0)),
            tickSpacing: DEFAULT_TICK_SPACING
        });
        
        // Get current tick from pool manager using StateLibrary
        (,int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());
        
        // Call the internal implementation with default slippage
        _queueDCAExecutionInternal(
            user,
            fromToken,
            toToken,
            amount,
            poolKey,
            currentTick,
            0 // Use default slippage
        );
    }
    
    // Internal implementation for queueDCAExecution with full parameters
    function _queueDCAExecutionInternal(
        address user,
        address fromToken,
        address toToken,
        uint256 amount,
        PoolKey memory poolKey,
        int24 currentTick,
        uint256 customSlippageTolerance
    ) internal {
        // Determine swap direction
        bool zeroForOne = _isZeroForOne(fromToken, toToken);
        
        // Get execution tick and deadline
        (int24 executionTick, uint256 deadline) = _getExecutionDetails(
            user, 
            poolKey, 
            currentTick, 
            zeroForOne
        );
        
        // Add to queue
        storage_.addToDcaQueue(
            user,
            fromToken,
            toToken,
            amount,
            executionTick,
            deadline,
            customSlippageTolerance
        );
        
        emit DCAQueued(user, fromToken, toToken, amount, executionTick);
    }

    // Helper function to validate DCA prerequisites
    function _validateDCAPrerequisites(
        address user, 
        address fromToken, 
        uint256 amount
    ) internal view returns (address targetToken) {
        // Check if DCA is enabled
        SpendSaveStorage.SavingStrategy memory strategy = storage_.getUserSavingStrategy(user);
        bool isDCAEnabled = strategy.enableDCA;
        if (!isDCAEnabled) revert DCANotEnabled();
        
        targetToken = storage_.dcaTargetToken(user);
        if (targetToken == address(0)) revert NoTargetTokenSet();
        
        uint256 userSavings = storage_.savings(user, fromToken);
        if (userSavings < amount) {
            revert InsufficientSavings(fromToken, amount, userSavings);
        }
        
        return targetToken;
    }

    /**
     * @notice Execute pending DCA for a user
     * @dev Production implementation with gas optimization
     */
    function executeDCA(address user) external override returns (bool executed, uint256 totalAmount) {
        // Get the user's enhanced DCA queue
        uint256 queueLength = storage_.getDcaQueueLength(user);
        if (queueLength == 0) return (false, 0);

        // Get user's DCA config
        (bool enabled, address targetToken, uint256 minAmount, uint256 maxSlippage,,) = 
            storage_.getUserDcaConfig(user);

        if (!enabled) return (false, 0);

        // Track which items were executed
        bool[] memory executedItems = new bool[](queueLength);

        for (uint256 i = 0; i < queueLength; i++) {
            // Get queue item details
            (
                address fromToken,
                address toToken,
                uint256 amount,
                int24 executionTick,
                uint256 deadline,
                bool itemExecuted,
                uint256 customSlippageTolerance
            ) = storage_.getDcaQueueItem(user, i);

            if (!itemExecuted && amount >= minAmount && block.timestamp <= deadline) {
                uint256 amountOut;
                uint256 executedPrice;
                (amountOut, executedPrice) = _executeSingleDCAWithPrice(
                    user,
                    fromToken,
                    toToken,
                    amount,
                    customSlippageTolerance > 0 ? customSlippageTolerance : maxSlippage
                );
                
                if (amountOut > 0) {
                    totalAmount += amountOut;
                    executed = true;
                    executedItems[i] = true;

                    // Mark as executed in storage
                    storage_.markDcaExecuted(user, i);
                }
            }
        }

        // Clean up executed items from the queue
        if (executed) {
            storage_.removeExecutedDcaItems(user);
        }

        return (executed, totalAmount);
    }

    /**
     * @notice Batch execute DCA for multiple users
     * @dev Gas-efficient implementation for keeper operations
     */
    function batchExecuteDCA(address[] calldata users) 
        external 
        override 
        returns (DCAExecution[] memory executions) 
    {
        // First, count total executions for array sizing
        uint256 totalExecutions = 0;
        for (uint256 u = 0; u < users.length; u++) {
            address user = users[u];
            uint256 queueLength = storage_.getDcaQueueLength(user);
            (bool enabled,,,,,) = storage_.getUserDcaConfig(user);
            
            if (enabled) {
                for (uint256 i = 0; i < queueLength; i++) {
                    (,,,,, bool itemExecuted, uint256 deadline) = storage_.getDcaQueueItem(user, i);
                    if (!itemExecuted && block.timestamp <= deadline) {
                        totalExecutions++;
                    }
                }
            }
        }

        executions = new DCAExecution[](totalExecutions);
        uint256 execIdx = 0;

        for (uint256 u = 0; u < users.length; u++) {
            address user = users[u];
            uint256 queueLength = storage_.getDcaQueueLength(user);
            (bool enabled, address targetToken, uint256 minAmount, uint256 maxSlippage,,) = 
                storage_.getUserDcaConfig(user);

            if (!enabled) continue;

            for (uint256 i = 0; i < queueLength; i++) {
                (
                    address fromToken,
                    address toToken,
                    uint256 amount,
                    int24 executionTick,
                    uint256 deadline,
                    bool itemExecuted,
                    uint256 customSlippageTolerance
                ) = storage_.getDcaQueueItem(user, i);

                if (!itemExecuted && amount >= minAmount && block.timestamp <= deadline) {
                    uint256 amountOut;
                    uint256 executedPrice;
                    (amountOut, executedPrice) = _executeSingleDCAWithPrice(
                        user,
                        fromToken,
                        toToken,
                        amount,
                        customSlippageTolerance > 0 ? customSlippageTolerance : maxSlippage
                    );

                    if (amountOut > 0) {
                        executions[execIdx++] = DCAExecution({
                            fromToken: fromToken,
                            toToken: toToken,
                            amount: amountOut,
                            timestamp: block.timestamp,
                            executedPrice: executedPrice
                        });
                        storage_.markDcaExecuted(user, i);
                    }
                }
            }
        }

        // Resize array to actual number of executions
        if (execIdx < totalExecutions) {
            assembly {
                mstore(executions, execIdx)
            }
        }
    }

    /**
     * @notice Get user's DCA configuration
     * @param user The user address
     * @return config The DCA configuration
     */
    function getDCAConfig(address user) external view override returns (DCAConfig memory config) {
        (bool enabled, address targetToken, uint256 minAmount, uint256 maxSlippage, int24 lowerTick, int24 upperTick) = 
            storage_.getUserDcaConfig(user);
        
        config = DCAConfig({
            enabled: enabled,
            targetToken: targetToken,
            minAmount: minAmount,
            maxSlippage: maxSlippage,
            lowerTick: lowerTick,
            upperTick: upperTick
        });
    }
    
    /**
     * @notice Get pending DCA queue for a user
     * @param user The user address
     * @return tokens Array of from tokens
     * @return amounts Array of amounts
     * @return targets Array of target tokens
     */
    function getPendingDCA(address user) external view override returns (
        address[] memory tokens,
        uint256[] memory amounts,
        address[] memory targets
    ) {
        uint256 queueLength = storage_.getDcaQueueLength(user);
        tokens = new address[](queueLength);
        amounts = new uint256[](queueLength);
        targets = new address[](queueLength);
        
        uint256 pendingCount = 0;
        for (uint256 i = 0; i < queueLength; i++) {
            (address fromToken, address toToken, uint256 amount, , uint256 deadline, bool executed, ) = 
                storage_.getDcaQueueItem(user, i);
            
            if (!executed && block.timestamp <= deadline) {
                tokens[pendingCount] = fromToken;
                amounts[pendingCount] = amount;
                targets[pendingCount] = toToken;
                pendingCount++;
            }
        }
        
        // Resize arrays to actual pending count
        if (pendingCount < queueLength) {
            assembly {
                mstore(tokens, pendingCount)
                mstore(amounts, pendingCount)
                mstore(targets, pendingCount)
            }
        }
    }
    
    /**
     * @notice Check if DCA should execute based on current tick
     * @param user The user address
     * @param poolKey The pool key to check
     * @return shouldExecute Whether DCA should execute
     * @return currentTick The current pool tick
     */
    function shouldExecuteDCA(
        address user,
        PoolKey calldata poolKey
    ) external view override returns (bool shouldExecute, int24 currentTick) {
        // Get current tick from pool manager
        (,currentTick,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());
        
        // Get user's tick strategy
        (int24 tickDelta, uint256 tickExpiryTime, bool onlyImprovePrice, int24 minTickImprovement, , ) = 
            storage_.getDcaTickStrategy(user);
        
        // Check if tick strategy is still valid
        if (tickExpiryTime > 0 && block.timestamp > tickExpiryTime) {
            return (false, currentTick);
        }
        
        // Get last execution tick
        int24 lastExecutionTick = storage_.getLastDcaExecutionTick(user, PoolId.unwrap(poolKey.toId()));
        
        // Calculate tick movement
        int24 tickMovement = currentTick - lastExecutionTick;
        
        // Check if tick movement meets criteria
        if (tickMovement >= tickDelta) {
            if (onlyImprovePrice) {
                shouldExecute = tickMovement >= minTickImprovement;
            } else {
                shouldExecute = true;
            }
        }
        
        return (shouldExecute, currentTick);
    }
    
    /**
     * @notice Calculate optimal DCA execution amount
     * @param user The user address
     * @param fromToken The source token
     * @param toToken The target token
     * @param availableAmount Amount available for DCA
     * @return optimalAmount The optimal amount to execute
     */
    function calculateOptimalDCAAmount(
        address user,
        address fromToken,
        address toToken,
        uint256 availableAmount
    ) external view override returns (uint256 optimalAmount) {
        // Get user's DCA config
        (bool enabled, , uint256 minAmount, , , ) = storage_.getUserDcaConfig(user);
        
        if (!enabled) return 0;
        
        // Get user's savings balance
        uint256 savingsBalance = storage_.savings(user, fromToken);
        
        // Calculate optimal amount based on available savings and minimum amount
        if (savingsBalance >= minAmount) {
            optimalAmount = savingsBalance > availableAmount ? availableAmount : savingsBalance;
        }
        
        return optimalAmount;
    }
    
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
    ) external override returns (bool queued) {
        // Check if DCA is enabled and target token is set
        if (!context.enableDCA || context.dcaTargetToken == address(0)) {
            return false;
        }
        
        // Don't queue if saved token is the same as target token
        if (savedToken == context.dcaTargetToken) {
            return false;
        }
        
        // Get user's DCA config
        (bool enabled, , uint256 minAmount, , , ) = storage_.getUserDcaConfig(user);
        
        if (!enabled || savedAmount < minAmount) {
            return false;
        }
        
        // Queue the DCA execution
        try this.queueDCAExecution(
            user,
            savedToken,
            context.dcaTargetToken,
            savedAmount
        ) {
            queued = true;
        } catch {
            queued = false;
        }
        
        return queued;
    }
    
    /**
     * @notice Get DCA execution history
     * @param user The user address
     * @param limit Maximum number of records to return
     * @return history Array of DCA executions
     */
    function getDCAHistory(
        address user,
        uint256 limit
    ) external view override returns (DCAExecution[] memory history) {
        // This would require tracking DCA execution history in storage
        // For now, return empty array as a placeholder
        // TODO: Implement DCA history tracking in storage contract
        history = new DCAExecution[](0);
    }

    /**
     * @notice Disable DCA for a user
     * @dev Simple flag update in storage
     */
    function disableDCA(address user) external override {
        if (msg.sender != user && msg.sender != storage_.owner()) {
            revert UnauthorizedCaller();
        }
        storage_.setDcaEnabled(user, false);
        emit DCADisabled(user);
    }

    /**
     * @notice Execute a single DCA with price tracking
     * @param user The user address
     * @param fromToken The source token
     * @param toToken The target token
     * @param amount The amount to swap
     * @param maxSlippage The maximum slippage tolerance
     * @return amountOut The amount received
     * @return executedPrice The executed price (amountOut / amount)
     */
    function _executeSingleDCAWithPrice(
        address user,
        address fromToken,
        address toToken,
        uint256 amount,
        uint256 maxSlippage
    ) internal returns (uint256 amountOut, uint256 executedPrice) {
        PoolKey memory poolKey = storage_.createPoolKey(fromToken, toToken);
        bool zeroForOne = fromToken < toToken;
        
        amountOut = executeDCASwap(
            user,
            fromToken,
            toToken,
            amount,
            poolKey,
            zeroForOne,
            maxSlippage
        );
        
        // Calculate executed price: amountOut / amount (with safety for division by zero)
        // Scale by 1e18 for fixed-point precision
        executedPrice = amount > 0 ? (amountOut * 1e18) / amount : 0;
    }

    /**
     * @notice Calculate maximum amount for slippage tolerance
     * @param fromToken The source token
     * @param toToken The target token
     * @param maxSlippage The maximum slippage tolerance
     * @return maxAmount The maximum amount that can be swapped without exceeding slippage
     */
    function _calculateMaxAmountForSlippage(
        address fromToken,
        address toToken,
        uint256 maxSlippage
    ) internal view returns (uint256) {
        // Placeholder: In production, query pool state and simulate swap for slippage
        // For now, return a large number (no limit)
        // This would typically involve:
        // 1. Getting pool liquidity
        // 2. Calculating price impact
        // 3. Determining max amount before slippage exceeds tolerance
        return type(uint256).max;
    }
    
    // Helper to process a single queue item
    function _processQueueItem(address user, uint256 index, PoolKey memory poolKey, int24 currentTick) internal {
        // Get the DCA execution info
        (
            address fromToken,
            address toToken,
            uint256 amount,
            int24 executionTick,
            uint256 deadline,
            bool executed,
            uint256 customSlippageTolerance
        ) = storage_.getDcaQueueItem(user, index);
        
        // Create a DCAExecution struct for easier handling
        SpendSaveStorage.DCAExecution memory dca = SpendSaveStorage.DCAExecution({
            amount: amount,
            token: toToken,
            executionTime: deadline,
            price: 0, // Will be set after execution
            successful: false
        });
        
        if (!executed && shouldExecuteDCAAtTick(user, index, currentTick)) {
            executeDCAAtIndex(user, index, poolKey, currentTick);
        }
    }
    
    // Get current pool tick
    function getCurrentTick(PoolKey memory poolKey) public nonReentrant returns (int24) {
        PoolId poolId = poolKey.toId();
        
        // Get current tick from pool manager
        (,int24 currentTick,,) = StateLibrary.getSlot0(IPoolManager(storage_.poolManager()), poolId);
        
        // Update stored tick if changed
        _updateStoredTick(poolId, currentTick);
        
        return currentTick;
    }
    
    // Helper to update stored tick
    function _updateStoredTick(PoolId poolId, int24 currentTick) internal {
        int24 oldTick = storage_.poolTicks(poolId);
        if (oldTick != currentTick) {
            storage_.setPoolTick(poolId, currentTick);
            emit TickUpdated(poolId, oldTick, currentTick);
        }
    }
    
    // Execute a specific DCA from the queue
    function executeDCAAtIndex(
        address user,
        uint256 index,
        PoolKey memory poolKey,
        int24 currentTick
    ) internal {
        // Validate and retrieve execution parameters
        (
            address fromToken,
            address toToken,
            uint256 amount,
            bool executed,
            bool zeroForOne,
            uint256 swapAmount,
            uint256 customSlippageTolerance
        ) = _prepareExecutionParameters(user, index, currentTick);
        
        if (executed) revert InvalidDCAExecution();
        
        // Execute the swap
        executeDCASwap(
            user,
            fromToken,
            toToken,
            swapAmount,
            poolKey,
            zeroForOne,
            customSlippageTolerance
        );
        
        // Mark as executed
        storage_.markDcaExecuted(user, index);
    }
    
    // Helper to prepare execution parameters
    function _prepareExecutionParameters(
        address user,
        uint256 index,
        int24 currentTick
    ) internal view returns (
        address fromToken,
        address toToken,
        uint256 amount,
        bool executed,
        bool zeroForOne,
        uint256 swapAmount,
        uint256 customSlippageTolerance
    ) {
        // Get execution details from storage
        int24 executionTick;
        uint256 deadline;
        
        (
            fromToken,
            toToken,
            amount,
            executionTick,
            deadline,
            executed,
            customSlippageTolerance
        ) = storage_.getDcaQueueItem(user, index);
        
        // Determine direction
        zeroForOne = fromToken < toToken;
        
        // Calculate swap amount considering dynamic sizing
        swapAmount = _calculateSwapAmount(user, amount, executionTick, currentTick, zeroForOne);
        
        // Validate sufficient balance
        uint256 userSavings = storage_.savings(user, fromToken);
        if (userSavings < swapAmount) {
            revert InsufficientSavings(fromToken, swapAmount, userSavings);
        }
        
        return (fromToken, toToken, amount, executed, zeroForOne, swapAmount, customSlippageTolerance);
    }
    
    // Helper to calculate swap amount
    function _calculateSwapAmount(
        address user,
        uint256 baseAmount,
        int24 executionTick,
        int24 currentTick,
        bool zeroForOne
    ) internal view returns (uint256) {
        // Check if using dynamic sizing
        bool dynamicSizing;
        (,,,,dynamicSizing,) = storage_.getDcaTickStrategy(user);
        
        if (!dynamicSizing) return baseAmount;
        
        return calculateDynamicDCAAmount(
            baseAmount,
            executionTick,
            currentTick,
            zeroForOne
        );
    }
    
    // Execute the actual DCA swap
    function executeDCASwap(
        address user,
        address fromToken,
        address toToken,
        uint256 amount,
        PoolKey memory poolKey,
        bool zeroForOne,
        uint256 customSlippageTolerance
    ) public returns (uint256) {
        if (amount == 0) revert ZeroAmountSwap();

        // Validate balance
        _validateBalance(user, fromToken, amount);

        // Prepare swap with slippage protection
        SwapExecutionParams memory params = _prepareSwapExecution(
            user, fromToken, toToken, amount, customSlippageTolerance
        );

        // Execute the swap
        SwapExecutionResult memory result = _executePoolSwap(
            poolKey, params, zeroForOne, amount
        );
        
        // Check if swap succeeded
        if (!result.success) revert SwapExecutionFailed();
        
        // Get minimum amount out
        uint256 minAmountOut = params.minAmountOut;
        
        // Check for slippage
        if (result.receivedAmount < minAmountOut) {
            bool shouldContinue = slippageModule.handleSlippageExceeded(
                user,
                fromToken,
                toToken,
                amount,
                result.receivedAmount,
                minAmountOut
            );
            
            if (!shouldContinue) {
                revert SlippageToleranceExceeded(result.receivedAmount, minAmountOut);
            }
        }
        
        // Process the results
        _processSwapResults(user, fromToken, toToken, amount, result.receivedAmount);
        
        emit DCAExecuted(user, fromToken, toToken, amount, result.receivedAmount);
        
        return result.receivedAmount;
    }

    function _prepareSwapExecution(
        address user,
        address fromToken,
        address toToken,
        uint256 amount,
        uint256 customSlippageTolerance
    ) internal returns (SwapExecutionParams memory) {
        // Approve the pool manager to spend tokens
        IERC20(fromToken).approve(address(storage_.poolManager()), amount);
        
        // Get minimum amount out with slippage protection
        uint256 minAmountOut = slippageModule.getMinimumAmountOut(
            user, fromToken, toToken, amount, customSlippageTolerance
        );
        
        return SwapExecutionParams({
            amount: amount,
            minAmountOut: minAmountOut,
            sqrtPriceLimitX96: 0 // Will be set in the executing function
        });
    }

    function _executePoolSwap(
        PoolKey memory poolKey,
        SwapExecutionParams memory params,
        bool zeroForOne,
        uint256 amount
    ) internal returns (SwapExecutionResult memory) {
        // Set price limit to ensure reasonable execution
        params.sqrtPriceLimitX96 = zeroForOne ? 
            TickMath.MIN_SQRT_PRICE + 1 : 
            TickMath.MAX_SQRT_PRICE - 1;
        
        // Prepare swap parameters
        SwapParams memory swapParams = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: params.sqrtPriceLimitX96
        });
        
        // Execute the swap
        BalanceDelta delta;
        try IPoolManager(storage_.poolManager()).swap(poolKey, swapParams, "") returns (BalanceDelta _delta) {
            delta = _delta;
        } catch {
            revert SwapExecutionFailed();
        }
        
        // Calculate the amount received
        uint256 receivedAmount = _calculateReceivedAmount(delta, zeroForOne);
        
        // Check if we received any tokens
        bool success = receivedAmount > 0;
        
        if (!success) {
            emit SwapExecutionZeroOutput(amount, zeroForOne);
        }
        
        return SwapExecutionResult({
            receivedAmount: receivedAmount,
            success: success
        });
    }
    
    // Helper to validate balance
    function _validateBalance(address user, address fromToken, uint256 amount) internal view {
        uint256 userSavings = storage_.savings(user, fromToken);
        if (userSavings < amount) {
            revert InsufficientSavings(fromToken, amount, userSavings);
        }
    }
    
    // Helper to execute swap via pool manager
    function _executeSwap(
        address user,
        address fromToken,
        address toToken,
        uint256 amount,
        PoolKey memory poolKey,
        bool zeroForOne,
        uint256 customSlippageTolerance
    ) internal returns (uint256 receivedAmount) {
        // Approve pool manager to spend fromToken
        IERC20(fromToken).approve(address(storage_.poolManager()), amount);
        
        // Set price limit to ensure the swap executes at a reasonable price
        uint160 sqrtPriceLimitX96 = zeroForOne ? 
            TickMath.MIN_SQRT_PRICE + 1 : 
            TickMath.MAX_SQRT_PRICE - 1;
        
        // Prepare swap parameters
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        
        // Get min amount out with slippage protection
        uint256 minAmountOut = slippageModule.getMinimumAmountOut(
            user,
            fromToken,
            toToken,
            amount,
            customSlippageTolerance
        );
        
        // Execute swap
        BalanceDelta delta = _performPoolSwap(poolKey, params);
        
        // Calculate received amount based on the swap delta
        receivedAmount = _calculateReceivedAmount(delta, zeroForOne);
        
        // Check for slippage
        _handleSlippage(user, fromToken, toToken, amount, receivedAmount, minAmountOut);
        
        return receivedAmount;
    }
    
    // Helper to perform pool swap
    function _performPoolSwap(PoolKey memory poolKey, SwapParams memory params) internal returns (BalanceDelta delta) {
        try IPoolManager(storage_.poolManager()).swap(poolKey, params, "") returns (BalanceDelta _delta) {
            return _delta;
        } catch {
            revert SwapExecutionFailed();
        }
    }
    
    // Helper to calculate received amount
    function _calculateReceivedAmount(BalanceDelta delta, bool zeroForOne) internal pure returns (uint256) {
        if (zeroForOne) {
            return uint256(int256(-delta.amount1()));
        } else {
            return uint256(int256(-delta.amount0()));
        }
    }
    
    // Helper to handle slippage check
    function _handleSlippage(
        address user,
        address fromToken,
        address toToken,
        uint256 amount,
        uint256 receivedAmount,
        uint256 minAmountOut
    ) internal {
        if (receivedAmount < minAmountOut) {
            // Call the handler which will either revert or continue based on user preference
            bool shouldContinue = slippageModule.handleSlippageExceeded(
                user,
                fromToken,
                toToken,
                amount,
                receivedAmount,
                minAmountOut
            );
            
            // If shouldContinue is false, revert the transaction
            if (!shouldContinue) {
                revert SlippageToleranceExceeded(receivedAmount, minAmountOut);
            }
        }
    }
    
    // Helper to process swap results
    function _processSwapResults(
        address user,
        address fromToken,
        address toToken,
        uint256 amount,
        uint256 receivedAmount
    ) internal {
        // Update savings balances
        storage_.decreaseSavings(user, fromToken, amount);
        
        // Calculate fee and final amount
        uint256 treasuryFee = storage_.treasuryFee();
        uint256 feeAmount = (receivedAmount * treasuryFee) / 10000;
        uint256 finalReceivedAmount = receivedAmount - feeAmount;
        
        // Update user's savings with final amount after fee
        storage_.increaseSavings(user, toToken, finalReceivedAmount);
        
        // Update ERC-6909 token balances
        // Convert token addresses to token IDs first
        uint256 fromTokenId = tokenModule.getTokenId(fromToken);
        uint256 toTokenId = tokenModule.getTokenId(toToken);

        // If tokens aren't registered yet, register them
        if (fromTokenId == 0) {
            fromTokenId = tokenModule.registerToken(fromToken);
        }
        if (toTokenId == 0) {
            toTokenId = tokenModule.registerToken(toToken);
        }

        // Now call with correct tokenId parameters
        tokenModule.burnSavingsToken(user, fromTokenId, amount);
        tokenModule.mintSavingsToken(user, toTokenId, finalReceivedAmount);

        // Transfer tokens to user
        _transferTokensToUser(user, toToken, finalReceivedAmount);
    }
    
    // Helper to transfer tokens to user
    function _transferTokensToUser(address user, address token, uint256 amount) internal {
        bool success = false;
        bytes memory returnData;
        
        // Use low-level call instead of try-catch with safeTransfer
        (success, returnData) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, user, amount)
        );
        
        if (!success) {
            emit TransferFailure(user, token, amount, returnData);
            revert TokenTransferFailed();
        }
    }
    
    // Calculate optimal tick for DCA execution
    function calculateDCAExecutionTick(
        address user,
        PoolKey memory poolKey,
        int24 currentTick,
        bool zeroForOne
    ) internal view returns (int24) {
        // Get the tick delta from the strategy
        (int24 tickDelta,,,,,) = storage_.getDcaTickStrategy(user);
        
        // If no strategy, execute at current tick
        if (tickDelta == 0) {
            return currentTick;
        }
        
        // Calculate target tick based on direction
        return zeroForOne ? currentTick - tickDelta : currentTick + tickDelta;
    }
    
    // Check if a queued DCA should execute based on current tick
    function shouldExecuteDCAAtTick(
        address user,
        uint256 index,
        int24 currentTick
    ) internal view returns (bool) {
        // Get the DCA queue item data
        (
            address fromToken,
            address toToken,
            uint256 amount,
            int24 executionTick,
            uint256 deadline,
            bool executed,
            uint256 customSlippageTolerance
        ) = storage_.getDcaQueueItem(user, index);
        
        if (executed) return false;
        
        // Get strategy parameters
        DCAExecutionCriteria memory criteria = _getDCAExecutionCriteria(user);
        
        // If past deadline, execute regardless of tick
        if (criteria.tickExpiryTime > 0 && block.timestamp > deadline) {
            return true;
        }
        
        // Determine if price has improved enough to execute
        bool priceImproved = _hasPriceImproved(
            fromToken, 
            toToken, 
            currentTick, 
            executionTick, 
            criteria.minTickImprovement
        );
        
        // If we only execute on price improvement, check that condition
        if (criteria.onlyImprovePrice) {
            return priceImproved;
        }
        
        // Otherwise, execute at or past the target tick
        return true;
    }
    
    // Helper struct to store DCA execution criteria
    struct DCAExecutionCriteria {
        bool onlyImprovePrice;
        int24 minTickImprovement;
        uint256 tickExpiryTime;
    }
    
    // Helper to get DCA execution criteria
    function _getDCAExecutionCriteria(
        address user
    ) internal view returns (DCAExecutionCriteria memory criteria) {
        (,criteria.tickExpiryTime,criteria.onlyImprovePrice,criteria.minTickImprovement,,) = 
            storage_.getDcaTickStrategy(user);
            
        return criteria;
    }
    
    // Helper to check if price has improved
    function _hasPriceImproved(
        address fromToken,
        address toToken,
        int24 currentTick,
        int24 executionTick,
        int24 minTickImprovement
    ) internal pure returns (bool) {
        bool zeroForOne = fromToken < toToken;
        bool priceImproved;
        
        if (zeroForOne) {
            // For 0->1, price improves when current tick < execution tick
            priceImproved = currentTick <= executionTick;
            
            // Check minimum improvement if required
            if (minTickImprovement > 0) {
                priceImproved = priceImproved && (executionTick - currentTick >= minTickImprovement);
            }
        } else {
            // For 1->0, price improves when current tick > execution tick
            priceImproved = currentTick >= executionTick;
            
            // Check minimum improvement if required
            if (minTickImprovement > 0) {
                priceImproved = priceImproved && (currentTick - executionTick >= minTickImprovement);
            }
        }
        
        return priceImproved;
    }
    
    // Calculate DCA amount based on tick movement (for dynamic sizing)
    function calculateDynamicDCAAmount(
        uint256 baseAmount,
        int24 entryTick,
        int24 currentTick,
        bool zeroForOne
    ) internal pure returns (uint256) {
        // Calculate tick movement and determine multiplier
        TickMovement memory movement = _calculateTickMovement(
            entryTick, currentTick, zeroForOne
        );
        
        if (!movement.isPositive) return baseAmount;
        
        // Apply multiplier with capping
        return _applyMultiplier(baseAmount, movement.delta);
    }

    function _calculateTickMovement(
        int24 entryTick,
        int24 currentTick,
        bool zeroForOne
    ) internal pure returns (TickMovement memory) {
        // If no tick movement, return zero delta
        if (entryTick == currentTick) {
            return TickMovement({
                delta: 0,
                isPositive: false
            });
        }
        
        // Calculate tick delta based on swap direction
        int24 delta = zeroForOne ? 
            (entryTick - currentTick) : 
            (currentTick - entryTick);
        
        return TickMovement({
            delta: delta,
            isPositive: delta > 0
        });
    }
    
    function _applyMultiplier(
        uint256 baseAmount, 
        int24 tickDelta
    ) internal pure returns (uint256) {
        // Convert to uint safely
        uint256 multiplier = uint24(tickDelta);
        
        // Cap multiplier at MAX_MULTIPLIER (100)
        if (multiplier > MAX_MULTIPLIER) {
            multiplier = MAX_MULTIPLIER;
        }
        
        // Apply multiplier to base amount
        return baseAmount + (baseAmount * multiplier) / 100;
    }
    
    // ==================== INTERNAL HELPER FUNCTIONS FOR DCA ====================
    /**
     * @notice Helper function to burn savings token for DCA
     * @param user The user address
     * @param token The token address
     * @param amount The amount to burn
     * @dev Converts token address to tokenId before burning (ERC6909 pattern)
     */
    function _burnSavingsTokenForDCA(address user, address token, uint256 amount) internal {
        if (address(tokenModule) != address(0) && amount > 0) {
            uint256 tokenId = tokenModule.getTokenId(token);
            if (tokenId != 0) {
                try tokenModule.burnSavingsToken(user, tokenId, amount) {
                    // Success - could emit event here
                } catch {
                    // Handle error appropriately for DCA context
                }
            }
        }
    }

    /**
     * @notice Helper function to mint savings token for DCA
     * @param user The user address
     * @param token The token address
     * @param amount The amount to mint
     * @dev Converts token address to tokenId before minting (ERC6909 pattern)
     */
    function _mintSavingsTokenForDCA(address user, address token, uint256 amount) internal {
        if (address(tokenModule) != address(0) && amount > 0) {
            uint256 tokenId = tokenModule.getTokenId(token);
            if (tokenId == 0) {
                tokenId = tokenModule.registerToken(token);
            }
            try tokenModule.mintSavingsToken(user, tokenId, amount) {
                // Success - could emit event here
            } catch {
                // Handle error appropriately for DCA context
            }
        }
    }
    
}