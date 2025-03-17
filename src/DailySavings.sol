// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./SpendSaveStorage.sol";
import "./IDailySavingsModule.sol";
import "./ITokenModule.sol";
import "./IYieldModule.sol";

/**
 * @title DailySavings
 * @dev Manages daily savings functionality
 */
contract DailySavings is IDailySavingsModule {
    using SafeERC20 for IERC20;

    // Helper struct to avoid stack too deep
    struct DailySavingsStatus {
        bool enabled;
        bool shouldProcess;
        uint256 lastExecutionTime;
        uint256 daysPassed;
        uint256 dailyAmount;
        uint256 goalAmount;
        uint256 currentAmount;
    }

    struct ExecutionContext {
        bool shouldProcess;
        uint256 amountToSave;
    }
    
    // Constants
    uint256 private constant MAX_PENALTY_BPS = 3000; // 30%
    uint256 private constant ONE_DAY_IN_SECONDS = 1 days;
    
    // Storage reference
    SpendSaveStorage public storage_;
    
    // Module references
    ITokenModule public tokenModule;
    IYieldModule public yieldModule;
    
    // Events
    event DailySavingsConfigured(address indexed user, address indexed token, uint256 dailyAmount, uint256 goalAmount, uint256 endTime);
    event DailySavingsDisabled(address indexed user, address indexed token);
    event DailySavingsExecuted(address indexed user, address indexed token, uint256 amount);
    event DailySavingsWithdrawn(address indexed user, address indexed token, uint256 amount, uint256 penalty, bool goalReached);
    event DailySavingsYieldStrategySet(address indexed user, address indexed token, SpendSaveStorage.YieldStrategy strategy);
    event DailySavingsGoalReached(address indexed user, address indexed token, uint256 totalAmount);
    
    // Custom errors
    error AlreadyInitialized();
    error InvalidAmount();
    error InvalidToken();
    error InvalidPenalty();
    error InvalidEndTime();
    error UnauthorizedCaller();
    error WithdrawalFailed();
    error TransferFailed();
    error InsufficientAllowance(uint256 required, uint256 available);
    error InsufficientBalance(uint256 required, uint256 available);
    error NoSavingsConfigured();
    error InsufficientSavings(address token, uint256 required, uint256 available);
    
    // Security guard
    bool private _reentrancyGuard;
    error ReentrancyGuardReentered();

    modifier nonReentrant() {
        if (_reentrancyGuard) revert ReentrancyGuardReentered();
        _reentrancyGuard = true;
        _;
        _reentrancyGuard = false;
    }
    
    modifier onlyAuthorized(address user) {
        if (!_isAuthorizedCaller(user)) {
            revert UnauthorizedCaller();
        }
        _;
    }
    
    modifier onlyOwner() {
        if (msg.sender != storage_.owner()) {
            revert UnauthorizedCaller();
        }
        _;
    }
    
    // Helper for authorization check
    function _isAuthorizedCaller(address user) internal view returns (bool) {
        return (msg.sender == user || 
                msg.sender == address(storage_) || 
                msg.sender == storage_.spendSaveHook());
    }
    
    // Constructor is empty since module will be initialized via initialize()
    constructor() {}
    
    // Initialize module with storage reference
    function initialize(SpendSaveStorage _storage) external override {
        if(address(storage_) != address(0)) revert AlreadyInitialized();
        storage_ = _storage;
    }
    
    // Set references to other modules
    function setModuleReferences(address _tokenModule, address _yieldModule) external onlyOwner {
        tokenModule = ITokenModule(_tokenModule);
        yieldModule = IYieldModule(_yieldModule);
    }
    
    // Validate configuration parameters
    function _validateConfigParams(
        address token,
        uint256 dailyAmount,
        uint256 penaltyBps,
        uint256 endTime
    ) internal view {
        if(token == address(0)) revert InvalidToken();
        if(dailyAmount == 0) revert InvalidAmount();
        if(penaltyBps > MAX_PENALTY_BPS) revert InvalidPenalty();
        if(endTime > 0 && endTime <= block.timestamp) revert InvalidEndTime();
    }
    
    // Configure daily savings for a specific token
    function configureDailySavings(
        address user,
        address token,
        uint256 dailyAmount,
        uint256 goalAmount,
        uint256 penaltyBps,
        uint256 endTime
    ) external override onlyAuthorized(user) {
        _validateConfigParams(token, dailyAmount, penaltyBps, endTime);
        
        // Store daily amount
        storage_.setDailySavingsAmount(user, token, dailyAmount);
        
        // Configure settings
        SpendSaveStorage.DailySavingsConfigParams memory params = SpendSaveStorage.DailySavingsConfigParams({
            enabled: true,
            goalAmount: goalAmount,
            currentAmount: 0,    // starting at 0 for a new configuration
            penaltyBps: penaltyBps,
            endTime: endTime
        });

        storage_.setDailySavingsConfig(user, token, params);
        
        // Check if we need to register token for ERC6909
        tokenModule.getTokenId(token);
        
        emit DailySavingsConfigured(user, token, dailyAmount, goalAmount, endTime);
    }
    
    // Disable daily savings for a token
    function disableDailySavings(address user, address token) external override onlyAuthorized(user) {
        _validateSavingsEnabled(user, token);
        
        _resetDailySavings(user, token);
        
        emit DailySavingsDisabled(user, token);
    }
    
    // Helper to validate savings are enabled
    function _validateSavingsEnabled(address user, address token) internal view {
        (bool enabled, , , , , , ) = storage_.getDailySavingsConfig(user, token);
        if(!enabled) revert NoSavingsConfigured();
    }
    
    // Helper to reset daily savings
    function _resetDailySavings(
        address user, 
        address token
    ) internal {
        SpendSaveStorage.DailySavingsConfigParams memory params = SpendSaveStorage.DailySavingsConfigParams({
            enabled: false,
            goalAmount: 0,
            currentAmount: 0,
            penaltyBps: 0,
            endTime: 0
        });

        storage_.setDailySavingsConfig(user, token, params);
        
        storage_.setDailySavingsAmount(user, token, 0);
    }
    
    // Execute daily savings for all user's tokens
    function executeDailySavings(address user) external override nonReentrant returns (uint256) {
        address[] memory tokens = storage_.getUserSavingsTokens(user);
        return _processTokenArray(user, tokens);
    }
    
    // Helper to process array of tokens
    function _processTokenArray(address user, address[] memory tokens) internal returns (uint256) {
        uint256 totalSaved = 0;
        
        for (uint i = 0; i < tokens.length; i++) {
            totalSaved += executeDailySavingsForToken(user, tokens[i]);
        }
        
        return totalSaved;
    }
    
    // Execute daily savings for a specific token
    function executeDailySavingsForToken(
        address user, 
        address token
    ) public override nonReentrant returns (uint256) {
        // Get savings status in a cleaner way
        ExecutionContext memory context = _prepareExecutionContext(user, token);
        
        // Skip early if conditions aren't met
        if (!context.shouldProcess) return 0;
        
        // Process the savings
        return _executeTokenSavings(user, token, context.amountToSave);
    }

    function _prepareExecutionContext(
        address user, 
        address token
    ) internal view returns (ExecutionContext memory) {
        // Get savings status
        DailySavingsStatus memory status = _getDailySavingsStatus(user, token);
        
        if (!status.shouldProcess) {
            return ExecutionContext({
                shouldProcess: false,
                amountToSave: 0
            });
        }
        
        // Calculate amount to save
        uint256 amountToSave = _calculateSavingsAmount(status);
        if (amountToSave == 0) {
            return ExecutionContext({
                shouldProcess: false,
                amountToSave: 0
            });
        }
        
        // Check if user has sufficient allowance and balance
        (bool sufficientFunds, ) = _checkAllowanceAndBalance(user, token, amountToSave);
        if (sufficientFunds) {
            return ExecutionContext({
                shouldProcess: true,
                amountToSave: amountToSave
            });
        } else {
            return ExecutionContext({
                shouldProcess: false,
                amountToSave: 0
            });
        }
    }

    function _executeTokenSavings(
        address user, 
        address token, 
        uint256 amount
    ) internal returns (uint256) {
        // Transfer tokens from user to this contract
        IERC20(token).safeTransferFrom(user, address(this), amount);
        
        // Update storage and process tokens
        _updateSavingsState(user, token, amount);
        
        emit DailySavingsExecuted(user, token, amount);
        return amount;
    }

    function _updateSavingsState(
        address user, 
        address token, 
        uint256 amount
    ) internal {
        // Update execution time and amount
        storage_.updateDailySavingsExecution(user, token, amount);
        
        // Mint ERC6909 savings tokens
        tokenModule.mintSavingsToken(user, token, amount);
        
        // Check if goal has been reached and emit event if needed
        _checkAndHandleGoalReached(user, token);
        
        // Apply yield strategy if configured
        _applyYieldStrategyIfNeeded(user, token);
    }

    function _checkAndHandleGoalReached(address user, address token) internal {
        (,,, uint256 goalAmount, uint256 currentAmount,,) = 
            storage_.getDailySavingsConfig(user, token);
            
        bool goalReached = goalAmount > 0 && currentAmount >= goalAmount;
        
        if (goalReached) {
            emit DailySavingsGoalReached(user, token, currentAmount);
        }
    }  

    function _applyYieldStrategyIfNeeded(address user, address token) internal {
        SpendSaveStorage.YieldStrategy strategy = storage_.getDailySavingsYieldStrategy(user, token);
        bool shouldApplyYield = strategy != SpendSaveStorage.YieldStrategy.NONE;
        
        if (shouldApplyYield) {
            yieldModule.applyYieldStrategy(user, token);
        }
    }

    
    // Helper to get daily savings status
    function _getDailySavingsStatus(address user, address token) internal view returns (DailySavingsStatus memory status) {
        (status.enabled, status.lastExecutionTime, , status.goalAmount, status.currentAmount, , ) = 
            storage_.getDailySavingsConfig(user, token);
        
        if (!status.enabled) return status;
        
        // Check if goal already reached
        bool goalReached = status.goalAmount > 0 && status.currentAmount >= status.goalAmount;
        if (goalReached) return status;
        
        // Calculate days passed
        status.daysPassed = (block.timestamp - status.lastExecutionTime) / ONE_DAY_IN_SECONDS;
        if (status.daysPassed == 0) return status;
        
        // Get daily amount
        status.dailyAmount = storage_.getDailySavingsAmount(user, token);
        status.shouldProcess = true;
        
        return status;
    }
    
    // Helper to calculate savings amount
    function _calculateSavingsAmount(DailySavingsStatus memory status) internal pure returns (uint256) {
        if (status.dailyAmount == 0) return 0;
        
        // Calculate amount to save based on days passed
        uint256 amountToSave = status.dailyAmount * status.daysPassed;
        
        // If we have a goal, cap the amount to not exceed the goal
        if (status.goalAmount > 0) {
            uint256 remaining = status.goalAmount - status.currentAmount;
            if (amountToSave > remaining) {
                amountToSave = remaining;
            }
        }
        
        return amountToSave;
    }
    
    // Helper to validate allowance and balance
    function _validateAllowanceAndBalance(address user, address token, uint256 amount) internal view {
        uint256 allowance = IERC20(token).allowance(user, address(this));
        if (allowance < amount) {
            revert InsufficientAllowance(amount, allowance);
        }
        
        uint256 balance = IERC20(token).balanceOf(user);
        if (balance < amount) {
            revert InsufficientBalance(amount, balance);
        }
    }
    
    // Helper to process daily savings
    function _processDailySavings(address user, address token, uint256 amount) internal returns (uint256) {
        // Transfer tokens from user to this contract
        IERC20(token).safeTransferFrom(user, address(this), amount);
        
        // Update execution time and amount
        storage_.updateDailySavingsExecution(user, token, amount);
        
        // Mint ERC6909 savings tokens
        tokenModule.mintSavingsToken(user, token, amount);
        
        // Check if goal has been reached
        _checkGoalReached(user, token);
        
        // Apply yield strategy if configured
        _applyYieldStrategy(user, token);
        
        emit DailySavingsExecuted(user, token, amount);
        return amount;
    }
    
    // Helper to check if goal is reached
    function _checkGoalReached(address user, address token) internal {
        (,,, uint256 goalAmount, uint256 currentAmount,,) = 
            storage_.getDailySavingsConfig(user, token);
            
        if (goalAmount > 0 && currentAmount >= goalAmount) {
            emit DailySavingsGoalReached(user, token, currentAmount);
        }
    }
    
    // Helper to apply yield strategy
    function _applyYieldStrategy(address user, address token) internal {
        SpendSaveStorage.YieldStrategy strategy = storage_.getDailySavingsYieldStrategy(user, token);
        if (strategy != SpendSaveStorage.YieldStrategy.NONE) {
            yieldModule.applyYieldStrategy(user, token);
        }
    }
    
    // Withdraw savings
    function withdrawDailySavings(address user, address token, uint256 amount) external override onlyAuthorized(user) nonReentrant returns (uint256) {
        // Get configuration and validation
        WithdrawalStatus memory status = _getWithdrawalStatus(user, token, amount);
        
        // Calculate penalty if applicable
        uint256 penalty = _calculatePenalty(status);
        
        // Calculate net amount
        uint256 netAmount = amount - penalty;
        
        // Burn tokens and update configuration
        _processSavingsWithdrawal(user, token, amount, status.currentAmount);
        
        // Transfer tokens
        _transferWithdrawalFunds(user, token, netAmount, penalty);
        
        emit DailySavingsWithdrawn(user, token, amount, penalty, status.goalReached);
        return netAmount;
    }
    
    // Helper struct for withdrawal
    struct WithdrawalStatus {
        bool enabled;
        uint256 goalAmount;
        uint256 currentAmount;
        uint256 penaltyBps;
        bool goalReached;
    }
    
    // Helper to get withdrawal status
    function _getWithdrawalStatus(address user, address token, uint256 amount) internal view returns (WithdrawalStatus memory status) {
        (status.enabled, , , status.goalAmount, status.currentAmount, status.penaltyBps, ) = 
            storage_.getDailySavingsConfig(user, token);
            
        if (!status.enabled) revert NoSavingsConfigured();
        if (amount == 0) revert InvalidAmount();
        
        // Check if user has enough saved tokens
        uint256 tokenId = tokenModule.getTokenId(token);
        uint256 userBalance = tokenModule.balanceOf(user, tokenId);
        
        if (userBalance < amount) {
            revert InsufficientBalance(amount, userBalance);
        }
        
        status.goalReached = status.goalAmount > 0 && status.currentAmount >= status.goalAmount;
        
        return status;
    }
    
    // Helper to calculate penalty
    function _calculatePenalty(WithdrawalStatus memory status) internal pure returns (uint256 penalty) {
        if (!status.goalReached && status.penaltyBps > 0) {
            return (status.penaltyBps * status.currentAmount) / 10000;
        }
        return 0;
    }
    
    // Helper to process savings withdrawal
    function _processSavingsWithdrawal(address user, address token, uint256 amount, uint256 currentAmount) internal {
        // Burn ERC6909 tokens
        tokenModule.burnSavingsToken(user, token, amount);
        
        // Update saved amount in storage
        _updateConfigAfterWithdrawal(user, token, amount, currentAmount);
    }
    
    // Helper to update config after withdrawal
    function _updateConfigAfterWithdrawal(
        address user, 
        address token, 
        uint256 amount, 
        uint256 currentAmount
    ) internal {
        // Get current config first
        (bool enabled, uint256 lastExecutionTime, uint256 startTime, uint256 goalAmount, , uint256 penaltyBps, uint256 endTime) = 
            storage_.getDailySavingsConfig(user, token);

        // Calculate new amount after withdrawal
        uint256 newAmount = currentAmount >= amount ? currentAmount - amount : 0;
        
        // Create parameter struct
        SpendSaveStorage.DailySavingsConfigParams memory params = SpendSaveStorage.DailySavingsConfigParams({
            enabled: enabled,
            goalAmount: goalAmount,
            currentAmount: newAmount,
            penaltyBps: penaltyBps,
            endTime: endTime
        });

        storage_.setDailySavingsConfig(user, token, params);
    }
    
    // Helper to transfer withdrawal funds
    function _transferWithdrawalFunds(address user, address token, uint256 netAmount, uint256 penalty) internal {
        // Transfer net amount to user
        IERC20(token).safeTransfer(user, netAmount);
        
        // Transfer penalty to treasury if applicable
        if (penalty > 0) {
            address treasury = storage_.treasury();
            IERC20(token).safeTransfer(treasury, penalty);
        }
    }
    
    // Set yield strategy for a token
    function setDailySavingsYieldStrategy(address user, address token, SpendSaveStorage.YieldStrategy strategy) external override onlyAuthorized(user) {
        _validateSavingsEnabled(user, token);
        
        storage_.setDailySavingsYieldStrategy(user, token, strategy);
        
        emit DailySavingsYieldStrategySet(user, token, strategy);
    }
    
    // Check if user has any pending daily savings
    function hasPendingDailySavings(address user) external view override returns (bool) {
        address[] memory tokens = storage_.getUserSavingsTokens(user);
        
        for (uint i = 0; i < tokens.length; i++) {
            (bool canExecute, , ) = getDailyExecutionStatus(user, tokens[i]);
            if (canExecute) return true;
        }
        
        return false;
    }
    
    // Get daily execution status
    function getDailyExecutionStatus(address user, address token) public view override returns (
        bool canExecute,
        uint256 daysPassed,
        uint256 amountToSave
    ) {
        // Get daily savings status
        DailySavingsStatus memory status = _getDailySavingsStatus(user, token);
        
        if (!status.shouldProcess) return (false, 0, 0);
        
        // Calculate amount to save
        amountToSave = _calculateSavingsAmount(status);
        daysPassed = status.daysPassed;
        
        // Check allowance and balance without reverting
        (canExecute, ) = _checkAllowanceAndBalance(user, token, amountToSave);
        
        return (canExecute, daysPassed, amountToSave);
    }
    
    // Helper to check allowance and balance without reverting
    function _checkAllowanceAndBalance(address user, address token, uint256 amount) internal view returns (bool sufficient, string memory reason) {
        if (amount == 0) return (false, "Zero amount");
        
        uint256 allowance = IERC20(token).allowance(user, address(this));
        if (allowance < amount) return (false, "Insufficient allowance");
        
        uint256 balance = IERC20(token).balanceOf(user);
        if (balance < amount) return (false, "Insufficient balance");
        
        return (true, "");
    }
    
    // Get savings status
    function getDailySavingsStatus(address user, address token) external view override returns (
        bool enabled,
        uint256 dailyAmount,
        uint256 goalAmount,
        uint256 currentAmount,
        uint256 remainingAmount,
        uint256 penaltyAmount,
        uint256 estimatedCompletionDate
    ) {
        // Get configuration from storage
        uint256 lastExecutionTime;
        uint256 startTime;
        uint256 penaltyBps;
        uint256 endTime;
        
        (
            enabled,
            lastExecutionTime,
            startTime,
            goalAmount,
            currentAmount,
            penaltyBps,
            endTime
        ) = storage_.getDailySavingsConfig(user, token);
            
        if (!enabled) return (false, 0, 0, 0, 0, 0, 0);
        
        // Get additional data and calculate derived values
        return _calculateDerivedValues(
            user,
            token,
            enabled,
            lastExecutionTime,
            startTime,
            goalAmount,
            currentAmount,
            penaltyBps,
            endTime
        );
    }
    
    // Helper to calculate derived values for savings status
    function _calculateDerivedValues(
        address user,
        address token,
        bool enabled,
        uint256 lastExecutionTime,
        uint256 startTime,
        uint256 goalAmount,
        uint256 currentAmount,
        uint256 penaltyBps,
        uint256 endTime
    ) internal view returns (
        bool,
        uint256 dailyAmount,
        uint256,
        uint256,
        uint256 remainingAmount,
        uint256 penaltyAmount,
        uint256 estimatedCompletionDate
    ) {
        dailyAmount = storage_.getDailySavingsAmount(user, token);
        
        // Calculate remaining amount
        remainingAmount = goalAmount > currentAmount ? goalAmount - currentAmount : 0;
        
        // Calculate potential penalty
        penaltyAmount = currentAmount * penaltyBps / 10000;
        
        // Estimate completion date
        estimatedCompletionDate = _estimateCompletionDate(
            dailyAmount,
            remainingAmount,
            goalAmount,
            currentAmount,
            endTime
        );
        
        return (enabled, dailyAmount, goalAmount, currentAmount, remainingAmount, penaltyAmount, estimatedCompletionDate);
    }


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
        uint256 calculatedSwapAmount = _calculateSwapAmount(user, amount, executionTick, currentTick, zeroForOne);

        swapAmount = calculatedSwapAmount;
        
        // Validate sufficient balance
        uint256 userSavings = storage_.savings(user, fromToken);
        if (userSavings < swapAmount) {
            revert InsufficientSavings(fromToken, swapAmount, userSavings);
        }
        
        return (fromToken, toToken, amount, executed, zeroForOne, swapAmount, customSlippageTolerance);
    }

    // Add this helper function to DailySavings.sol
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
        
        // Simple implementation for dynamic sizing
        // For a proper implementation, you might want to use similar logic to what's in the DCA module
        int24 tickDelta = zeroForOne ? 
            (executionTick - currentTick) : 
            (currentTick - executionTick);
        
        if (tickDelta <= 0) return baseAmount;
        
        // Scale amount based on tick movement
        uint256 multiplier = uint24(tickDelta) > 100 ? 100 : uint24(tickDelta);
        return baseAmount + (baseAmount * multiplier) / 100;
    }
    
    // Helper to estimate completion date
    function _estimateCompletionDate(
        uint256 dailyAmount,
        uint256 remainingAmount,
        uint256 goalAmount,
        uint256 currentAmount,
        uint256 endTime
    ) internal view returns (uint256) {
        if (remainingAmount > 0 && dailyAmount > 0) {
            uint256 daysLeft = remainingAmount / dailyAmount;
            if (remainingAmount % dailyAmount > 0) daysLeft += 1;
            
            return block.timestamp + (daysLeft * ONE_DAY_IN_SECONDS);
        } else if (goalAmount > 0 && currentAmount >= goalAmount) {
            // Goal already reached
            return block.timestamp;
        } else if (endTime > 0) {
            // Use configured end time
            return endTime;
        }
        
        return 0;
    }
}