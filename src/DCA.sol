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

import "./SpendSaveStorage.sol";
import "./IDCAModule.sol";
import "./ITokenModule.sol";
import "./ISlippageControlModule.sol";

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
    
    // Events
    event DCAEnabled(address indexed user, address indexed targetToken, bool enabled);
    event DCATickStrategySet(address indexed user, int24 tickDelta, uint256 tickExpiryTime, bool onlyImprovePrice);
    event DCAQueued(address indexed user, address fromToken, address toToken, uint256 amount, int24 executionTick);
    event DCAExecuted(address indexed user, address fromToken, address toToken, uint256 fromAmount, uint256 toAmount);
    event TickUpdated(PoolId indexed poolId, int24 oldTick, int24 newTick);
    event ModuleReferencesSet(address tokenModule, address slippageModule);
    event ModuleInitialized(address storage_);
    event TreasuryFeeCollected(address indexed user, address token, uint256 amount);
    event TransferFailure(address indexed user, address token, uint256 amount, bytes reason);
    
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
    function setModuleReferences(address _tokenModule, address _slippageModule) external nonReentrant onlyOwner {
        tokenModule = ITokenModule(_tokenModule);
        slippageModule = ISlippageControlModule(_slippageModule);
        emit ModuleReferencesSet(_tokenModule, _slippageModule);
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
        (
            percentage,
            autoIncrement,
            maxPercentage,
            goalAmount,
            roundUpSavings,
            ,  // Ignore current enableDCA value
            savingsTokenType,
            specificSavingsToken
        ) = storage_.getUserSavingStrategy(user);
        
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
    function enableDCA(address user, address targetToken, bool enabled) external override onlyAuthorized(user) nonReentrant {
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
            enabled,
            savingsTokenType,
            specificSavingsToken,
            targetToken
        );
        
        emit DCAEnabled(user, targetToken, enabled);
    }
    
    // Helper to update saving strategy
    function _updateSavingStrategy(
        address user,
        uint256 percentage,
        uint256 autoIncrement,
        uint256 maxPercentage,
        uint256 goalAmount,
        bool roundUpSavings,
        bool enableDCA,
        SpendSaveStorage.SavingsTokenType savingsTokenType,
        address specificSavingsToken,
        address targetToken
    ) internal {
        // Update the strategy with new values
        storage_.setUserSavingStrategy(
            user,
            percentage,
            autoIncrement,
            maxPercentage,
            goalAmount,
            roundUpSavings,
            enableDCA,
            savingsTokenType,
            specificSavingsToken
        );
        
        // Set the target token
        storage_.setDcaTargetToken(user, targetToken);
    }

    // Helper function to get the current custom slippage tolerance
    function _getCurrentCustomSlippageTolerance(address user) internal view returns (uint256) {
        (,,,,,uint256 customSlippageTolerance) = storage_.getDcaTickStrategy(user);
        return customSlippageTolerance;
    }
    // Set DCA tick strategy
    function setDCATickStrategy(
        address user,
        int24 tickDelta,
        uint256 tickExpiryTime,
        bool onlyImprovePrice,
        int24 minTickImprovement,
        bool dynamicSizing
    ) external override onlyAuthorized(user) nonReentrant {
        // Get current slippage tolerance to keep it the same
        uint256 customSlippageTolerance = _getCurrentCustomSlippageTolerance(user);
        
        // Update the strategy
        storage_.setDcaTickStrategy(
            user,
            tickDelta,
            tickExpiryTime,
            onlyImprovePrice,
            minTickImprovement,
            dynamicSizing,
            customSlippageTolerance
        );
        
        emit DCATickStrategySet(user, tickDelta, tickExpiryTime, onlyImprovePrice);
    }
    
    // Queue DCA from a savings token generated in a swap
    function queueDCAFromSwap(
        address user,
        address fromToken,
        SpendSaveStorage.SwapContext memory context
    ) external override onlyAuthorized(user) nonReentrant {
        // Validate conditions for DCA queue
        if (!_shouldQueueDCA(context, fromToken)) return;
        
        // Get savings amount for this token
        uint256 amount = storage_.savings(user, fromToken);
        if (amount == 0) return;
        
        // Create the pool key and queue the DCA execution
        PoolKey memory poolKey = createPoolKey(fromToken, context.dcaTargetToken);
        
        queueDCAExecution(
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

    // Queue DCA for execution at optimal tick
    function queueDCAExecution(
        address user,
        address fromToken,
        address toToken,
        uint256 amount,
        PoolKey memory poolKey,
        int24 currentTick,
        uint256 customSlippageTolerance
    ) public override onlyAuthorized(user) nonReentrant {
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
        (,,,,, bool enableDCA,,) = storage_.getUserSavingStrategy(user);
        if (!enableDCA) revert DCANotEnabled();
        
        targetToken = storage_.dcaTargetToken(user);
        if (targetToken == address(0)) revert NoTargetTokenSet();
        
        uint256 userSavings = storage_.savings(user, fromToken);
        if (userSavings < amount) {
            revert InsufficientSavings(fromToken, amount, userSavings);
        }
        
        return targetToken;
    }

    // Execute a DCA swap
    function executeDCA(
        address user,
        address fromToken,
        uint256 amount,
        uint256 customSlippageTolerance
    ) external override onlyAuthorized(user) nonReentrant {
        // Validate prerequisites and get target token
        address targetToken = _validateDCAPrerequisites(user, fromToken, amount);
        
        // Create pool key for the swap
        PoolKey memory poolKey = createPoolKey(fromToken, targetToken);
        
        // Get current tick
        int24 currentTick = getCurrentTick(poolKey);
        
        // Determine execution strategy
        _executeDCAWithStrategy(
            user,
            fromToken,
            targetToken,
            amount,
            poolKey,
            currentTick,
            customSlippageTolerance
        );
    }
    
    // Helper for DCA execution strategy determination
    function _executeDCAWithStrategy(
        address user,
        address fromToken,
        address targetToken,
        uint256 amount,
        PoolKey memory poolKey,
        int24 currentTick,
        uint256 customSlippageTolerance
    ) internal {
        // Check if there's a tick strategy
        (int24 tickDelta, uint256 tickExpiryTime,,,,) = storage_.getDcaTickStrategy(user);
        
        bool shouldQueueExecution = (tickDelta != 0 && tickExpiryTime != 0);
        
        if (shouldQueueExecution) {
            // Queue for execution at optimal tick
            queueDCAExecution(
                user,
                fromToken,
                targetToken,
                amount,
                poolKey,
                currentTick,
                customSlippageTolerance
            );
        } else {
            // No tick strategy, execute immediately
            bool zeroForOne = _isZeroForOne(fromToken, targetToken);
            
            executeDCASwap(
                user,
                fromToken,
                targetToken,
                amount,
                poolKey,
                zeroForOne,
                customSlippageTolerance
            );
        }
    }
        
    // Process all queued DCAs that should execute at current tick
    function processQueuedDCAs(address user, PoolKey memory poolKey) external override onlyAuthorized(user) nonReentrant {
        int24 currentTick = getCurrentTick(poolKey);
        uint256 queueLength = storage_.getDcaQueueLength(user);
        
        for (uint256 i = 0; i < queueLength; i++) {
            _processQueueItem(user, i, poolKey, currentTick);
        }
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
            fromToken: fromToken,
            toToken: toToken,
            amount: amount,
            executionTick: executionTick,
            deadline: deadline,
            executed: executed,
            customSlippageTolerance: customSlippageTolerance
        });
        
        if (!executed && shouldExecuteDCAAtTick(user, dca, currentTick)) {
            executeDCAAtIndex(user, index, poolKey, currentTick);
        }
    }
    
    // Get current pool tick
    function getCurrentTick(PoolKey memory poolKey) public override nonReentrant returns (int24) {
        PoolId poolId = poolKey.toId();
        
        // Get current tick from pool manager
        (,int24 currentTick,,) = StateLibrary.getSlot0(storage_.poolManager(), poolId);
        
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
    ) internal {
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
        
        // Process the results
        _processSwapResults(user, fromToken, toToken, amount, result.receivedAmount);
        
        emit DCAExecuted(user, fromToken, toToken, amount, result.receivedAmount);
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
        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: params.sqrtPriceLimitX96
        });
        
        // Execute the swap
        BalanceDelta delta;
        try storage_.poolManager().swap(poolKey, swapParams, "") returns (BalanceDelta _delta) {
            delta = _delta;
        } catch {
            revert SwapExecutionFailed();
        }
        
        // Calculate the amount received
        uint256 receivedAmount = _calculateReceivedAmount(delta, zeroForOne);
        
        return SwapExecutionResult({
            receivedAmount: receivedAmount,
            success: true
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
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
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
    function _performPoolSwap(PoolKey memory poolKey, IPoolManager.SwapParams memory params) internal returns (BalanceDelta delta) {
        try storage_.poolManager().swap(poolKey, params, "") returns (BalanceDelta _delta) {
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
        
        // Calculate and transfer fee
        uint256 finalReceivedAmount = storage_.calculateAndTransferFee(user, toToken, receivedAmount);
        
        // Update user's savings with final amount after fee
        storage_.increaseSavings(user, toToken, finalReceivedAmount);
        
        // Update ERC-6909 token balances
        tokenModule.burnSavingsToken(user, fromToken, amount);
        tokenModule.mintSavingsToken(user, toToken, finalReceivedAmount);

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
        SpendSaveStorage.DCAExecution memory dca,
        int24 currentTick
    ) internal view returns (bool) {
        if (dca.executed) return false;
        
        // Get strategy parameters
        DCAExecutionCriteria memory criteria = _getDCAExecutionCriteria(user, dca);
        
        // If past deadline, execute regardless of tick
        if (criteria.tickExpiryTime > 0 && block.timestamp > dca.deadline) {
            return true;
        }
        
        // Determine if price has improved enough to execute
        bool priceImproved = _hasPriceImproved(
            dca.fromToken, 
            dca.toToken, 
            currentTick, 
            dca.executionTick, 
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
        address user, 
        SpendSaveStorage.DCAExecution memory dca
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
    
    
    // Helper function to create a pool key
    function createPoolKey(address tokenA, address tokenB) internal view returns (PoolKey memory) {
        // Ensure tokens are in correct order
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: DEFAULT_FEE_TIER, // 0.3% fee tier
            tickSpacing: DEFAULT_TICK_SPACING,
            hooks: IHooks(address(0)) // No hooks for this swap to avoid recursive calls
        });
    }
}