// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SpendSaveStorage} from "./SpendSaveStorage.sol";
import {IDailySavingsModule} from "./interfaces/IDailySavingsModule.sol";
import {ITokenModule} from "./interfaces/ITokenModule.sol";
import {IYieldModule} from "./interfaces/IYieldModule.sol";

/**
 * @title DailySavings
 * @dev Manages daily savings functionality with gas optimizations and better error handling
 */
contract DailySavings is IDailySavingsModule {
    using SafeERC20 for IERC20;

    // Cached constants to reduce gas costs
    uint256 private constant MAX_PENALTY_BPS = 3000; // 30%
    uint256 private constant ONE_DAY_IN_SECONDS = 1 days;
    uint256 private constant BPS_DENOMINATOR = 10000;
    uint256 private constant BATCH_SIZE = 5;
    uint256 private constant MIN_GAS_TO_KEEP = 100000;

    // Helper struct to avoid stack too deep and optimize storage reads
    struct DailySavingsStatus {
        bool enabled;
        bool shouldProcess;
        uint256 lastExecutionTime;
        uint256 startTime;
        uint256 daysPassed;
        uint256 dailyAmount;
        uint256 goalAmount;
        uint256 currentAmount;
        uint256 penaltyBps;
        uint256 endTime;
        bool goalReached;
    }

    struct ExecutionContext {
        bool shouldProcess;
        uint256 amountToSave;
        string reason;
    }

    struct WithdrawalContext {
        bool enabled;
        uint256 goalAmount;
        uint256 currentAmount;
        uint256 penaltyBps;
        bool goalReached;
        uint256 userBalance;
        uint256 netAmount;
        uint256 penalty;
    }

    struct BatchProcessingContext {
        uint256 totalSaved;
        uint256 gasLimit;
        uint256 processingCount;
    }
    
    // Storage reference
    SpendSaveStorage public storage_;
    
    // Module references
    ITokenModule public tokenModule;
    IYieldModule public yieldModule;
    
    // Standardized module references
    address internal _savingStrategyModule;
    address internal _savingsModule;
    address internal _dcaModule;
    address internal _slippageModule;
    address internal _tokenModule;
    address internal _dailySavingsModule;
    
    // Events
    event DailySavingsConfigured(address indexed user, address indexed token, uint256 dailyAmount, uint256 goalAmount, uint256 endTime);
    event DailySavingsDisabled(address indexed user, address indexed token);
    event DailySavingsExecuted(address indexed user, address indexed token, uint256 amount, uint256 gasUsed);
    event DailySavingsExecutionSkipped(address indexed user, address indexed token, string reason);
    event DailySavingsWithdrawn(address indexed user, address indexed token, uint256 amount, uint256 penalty, bool goalReached);
    event DailySavingsYieldStrategySet(address indexed user, address indexed token, SpendSaveStorage.YieldStrategy strategy);
    event DailySavingsGoalReached(address indexed user, address indexed token, uint256 totalAmount);
    event BatchProcessingCompleted(address indexed user, uint256 tokenCount, uint256 totalSaved, uint256 gasUsed);
    event TransferError(address indexed user, address indexed token, string reason);
    event YieldModuleNotInitialized(address indexed user, address indexed token);
    event YieldStrategyApplied(address indexed user, address indexed token, SpendSaveStorage.YieldStrategy strategy);
    event YieldStrategyFailed(address indexed user, address indexed token, string reason);
    event ModuleReferencesSet();
    
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
    error InsufficientGas(uint256 available, uint256 required);
    error TokenNotRegistered(address token);
    
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
    function setModuleReferences(
        address savingStrategy,
        address savings,
        address dca,
        address slippage,
        address token,
        address dailySavings
    ) external override onlyOwner {
        _savingStrategyModule = savingStrategy;
        _savingsModule = savings;
        _dcaModule = dca;
        _slippageModule = slippage;
        _tokenModule = token;
        _dailySavingsModule = dailySavings;
        
        // Set the typed references for backward compatibility
        tokenModule = ITokenModule(token);
        yieldModule = IYieldModule(address(0)); // Not passed in standard interface
        
        emit ModuleReferencesSet();
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
    ) external override onlyAuthorized(user) nonReentrant {
        _validateConfigParams(token, dailyAmount, penaltyBps, endTime);
        
        // Store daily amount
        storage_.setDailySavingsAmount(user, token, dailyAmount);
        
        // Configure settings
        SpendSaveStorage.DailySavingsConfigParams memory params = SpendSaveStorage.DailySavingsConfigParams({
            enabled: true,
            lastExecutionTime: block.timestamp,  // NEW: Set to current time for new configs
            startTime: block.timestamp,  
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
    function disableDailySavings(address user, address token) external override onlyAuthorized(user) nonReentrant {
        _validateSavingsEnabled(user, token);
        
        _resetDailySavings(user, token);
        
        emit DailySavingsDisabled(user, token);
    }
    
    // Helper to validate savings are enabled
    function _validateSavingsEnabled(address user, address token) internal view {
        SpendSaveStorage.DailySavingsConfig memory config = storage_.getDailySavingsConfig(user);
        bool tokenConfigured = false;
        for (uint i = 0; i < config.tokens.length; i++) {
            if (config.tokens[i] == token) {
                tokenConfigured = true;
                break;
            }
        }
        bool enabled = config.isActive && tokenConfigured;
        if(!enabled) revert NoSavingsConfigured();
    }
    
    // Helper to reset daily savings
    function _resetDailySavings(
        address user, 
        address token
    ) internal {
        SpendSaveStorage.DailySavingsConfigParams memory params = SpendSaveStorage.DailySavingsConfigParams({
            enabled: false,
            lastExecutionTime: 0,  // NEW: Reset execution time
            startTime: 0,          // NEW: Reset start time  
            goalAmount: 0,
            currentAmount: 0,
            penaltyBps: 0,
            endTime: 0
        });

        storage_.setDailySavingsConfig(user, token, params);
        storage_.setDailySavingsAmount(user, token, 0);
    }
    
    // Execute daily savings for all user's tokens with gas optimization
    function executeDailySavings(address user) external override nonReentrant returns (uint256) {
        // Check gas limit first
        if (gasleft() < BATCH_SIZE * 150000 + MIN_GAS_TO_KEEP) {
            revert InsufficientGas(gasleft(), BATCH_SIZE * 150000 + MIN_GAS_TO_KEEP);
        }
        
        address[] memory tokens = storage_.getUserSavingsTokens(user);
        return _processBatches(user, tokens);
    }
    
    // Process tokens in batches for gas efficiency
    function _processBatches(address user, address[] memory tokens) internal returns (uint256) {
        uint256 startGas = gasleft();
        BatchProcessingContext memory context = BatchProcessingContext({
            totalSaved: 0,
            gasLimit: 150000, // Initial gas estimate per token
            processingCount: 0
        });
        
        // Process in batches
        for (uint256 i = 0; i < tokens.length; i += BATCH_SIZE) {
            // Stop if we're running low on gas
            if (gasleft() < context.gasLimit * BATCH_SIZE + MIN_GAS_TO_KEEP) break;
            
            uint256 batchEnd = i + BATCH_SIZE > tokens.length ? tokens.length : i + BATCH_SIZE;
            _processBatch(user, tokens, i, batchEnd, context);
        }
        
        uint256 gasUsed = startGas - gasleft();
        emit BatchProcessingCompleted(user, context.processingCount, context.totalSaved, gasUsed);
        
        return context.totalSaved;
    }
    
    // Process a batch of tokens
    function _processBatch(
        address user,
        address[] memory tokens,
        uint256 startIdx,
        uint256 endIdx,
        BatchProcessingContext memory context
    ) internal {
        for (uint256 i = startIdx; i < endIdx; i++) {
            // Check gas for this token
            if (gasleft() < context.gasLimit + MIN_GAS_TO_KEEP) break;
            
            address token = tokens[i];
            uint256 tokenStartGas = gasleft();
            
            try this.executeDailySavingsForToken(user, token) returns (uint256 amount) {
                if (amount > 0) {
                    context.totalSaved += amount;
                    context.processingCount++;
                    
                    // Calculate actual gas used and adjust estimate
                    uint256 gasUsed = tokenStartGas - gasleft();
                    context.gasLimit = _adjustGasEstimate(context.gasLimit, gasUsed);
                }
            } catch Error(string memory reason) {
                emit DailySavingsExecutionSkipped(user, token, reason);
            } catch {
                emit DailySavingsExecutionSkipped(user, token, "Unknown error");
            }
        }
    }
    
    // Adjust gas estimate based on actual usage
    function _adjustGasEstimate(uint256 currentEstimate, uint256 actualUsage) internal pure returns (uint256) {
        if (actualUsage > currentEstimate) {
            // Increase estimate but don't overreact
            return currentEstimate + ((actualUsage - currentEstimate) / 4);
        } else if (actualUsage < currentEstimate * 8 / 10) {
            // Decrease estimate if we used significantly less (below 80%)
            return (currentEstimate + actualUsage) / 2;
        }
        return currentEstimate; // Keep same estimate if usage is close
    }
    
    // Execute daily savings for a specific token - optimized version
    function executeDailySavingsForToken(
        address user, 
        address token
    ) public override nonReentrant returns (uint256) {
        uint256 startGas = gasleft();
        
        // Get execution context with all necessary checks
        ExecutionContext memory context = _prepareExecutionContext(user, token);
        
        // Early return with clear reason if conditions aren't met
        if (!context.shouldProcess) {
            emit DailySavingsExecutionSkipped(user, token, context.reason);
            return 0;
        }
        
        // Process the savings
        uint256 amount = _executeTokenSavings(user, token, context.amountToSave);
        
        // Add explicit check for failed execution
        if (amount == 0) {
            emit DailySavingsExecutionSkipped(user, token, "Token transfer failed");
            return 0;
        }
        
        uint256 gasUsed = startGas - gasleft();
        emit DailySavingsExecuted(user, token, amount, gasUsed);
        
        return amount;
    }

    // Prepare execution context with all necessary data and validation
    function _prepareExecutionContext(
        address user, 
        address token
    ) internal view returns (ExecutionContext memory context) {
        // Get complete savings status in a single storage read
        DailySavingsStatus memory status = _getDailySavingsStatus(user, token);
        
        // Validate basic conditions
        if (!status.enabled) {
            return ExecutionContext({
                shouldProcess: false,
                amountToSave: 0,
                reason: "Savings not enabled"
            });
        }
        
        // Check if goal already reached
        if (status.goalReached) {
            return ExecutionContext({
                shouldProcess: false,
                amountToSave: 0,
                reason: "Goal already reached"
            });
        }
        
        // Check if enough time has passed
        if (status.daysPassed == 0) {
            return ExecutionContext({
                shouldProcess: false,
                amountToSave: 0,
                reason: "Not enough time passed since last execution"
            });
        }
        
        // Calculate amount to save
        uint256 amountToSave = _calculateSavingsAmount(status);
        if (amountToSave == 0) {
            return ExecutionContext({
                shouldProcess: false,
                amountToSave: 0,
                reason: "No amount to save"
            });
        }
        
        // Check if user has sufficient allowance and balance
        (bool sufficientFunds, string memory reason) = _checkAllowanceAndBalance(user, token, amountToSave);
        if (!sufficientFunds) {
            return ExecutionContext({
                shouldProcess: false,
                amountToSave: 0,
                reason: reason
            });
        }
        
        // All checks passed, ready to process
        return ExecutionContext({
            shouldProcess: true,
            amountToSave: amountToSave,
            reason: ""
        });
    }

    // Execute token savings with proper error handling
    function _executeTokenSavings(
        address user, 
        address token, 
        uint256 amount
    ) internal returns (uint256) {
        // Try to transfer tokens with proper error handling
        bool transferSuccess;
        
        try IERC20(token).transferFrom(user, address(this), amount) {
            transferSuccess = true;
        } catch Error(string memory reason) {
            emit TransferError(user, token, reason);
            return 0;
        } catch {
            emit TransferError(user, token, "Unknown transfer error");
            return 0;
        }
        
        if (transferSuccess) {
            // Update storage and process tokens only if transfer was successful
            _updateSavingsState(user, token, amount);
            return amount;
        }
        
        return 0;
    }


    // Update savings state with all necessary operations
    function _updateSavingsState(
        address user, 
        address token, 
        uint256 amount
    ) internal {
        // Update execution time and amount
        storage_.updateDailySavingsExecution(user, token, amount);
        
        // Mint ERC6909 savings tokens
        _mintSavingsTokenForDailySavings(user, token, amount);
        
        // Check if goal has been reached
        _checkGoalReached(user, token);
        
        // Apply yield strategy if configured
        _applyYieldStrategy(user, token);
    }

    // Check if goal is reached and emit event if needed
    function _checkGoalReached(address user, address token) internal {
        // Get current amount and goal in a single storage read
        (,,, uint256 goalAmount, uint256 currentAmount,,) = 
            storage_.getDailySavingsConfig(user, token);
            
        bool goalReached = goalAmount > 0 && currentAmount >= goalAmount;
        
        if (goalReached) {
            emit DailySavingsGoalReached(user, token, currentAmount);
        }
    }  

    // Apply yield strategy if configured
    function _applyYieldStrategy(address user, address token) internal {
        // First check if yield module is initialized
        if (address(yieldModule) == address(0)) {
            emit YieldModuleNotInitialized(user, token);
            return;
        }
        
        SpendSaveStorage.YieldStrategy strategy = storage_.getDailySavingsYieldStrategy(user, token);
        
        if (strategy != SpendSaveStorage.YieldStrategy.NONE) {
            try yieldModule.applyYieldStrategy(user, token) {
                emit YieldStrategyApplied(user, token, strategy);
            } catch Error(string memory reason) {
                emit YieldStrategyFailed(user, token, reason);
            } catch {
                emit YieldStrategyFailed(user, token, "Unknown error");
            }
        }
    }
    
    // Optimized method to get daily savings status with fewer storage reads
    function _getDailySavingsStatus(address user, address token) internal view returns (DailySavingsStatus memory status) {
        // Get all configuration data in a single storage read
        (
            status.enabled,
            status.lastExecutionTime,
            status.startTime,
            status.goalAmount,
            status.currentAmount,
            status.penaltyBps,
            status.endTime
        ) = storage_.getDailySavingsConfig(user, token);
        
        // Calculate goal reached
        status.goalReached = status.goalAmount > 0 && status.currentAmount >= status.goalAmount;
        
        // Calculate days passed since last execution
        if (status.enabled && !status.goalReached) {
            status.daysPassed = (block.timestamp - status.lastExecutionTime) / ONE_DAY_IN_SECONDS;
            
            // Get daily amount if we have days to process
            if (status.daysPassed > 0) {
                status.dailyAmount = storage_.dailySavingsAmounts(user, token);
                status.shouldProcess = status.dailyAmount > 0;
            }
        }
        
        return status;
    }
    
    // Calculate savings amount based on days passed and goal
    function _calculateSavingsAmount(DailySavingsStatus memory status) internal pure returns (uint256) {
        if (status.dailyAmount == 0) return 0;
        
        // Calculate amount to save based on days passed
        uint256 amountToSave = status.dailyAmount * status.daysPassed;
        
        // If we have a goal, cap the amount to not exceed the goal
        if (status.goalAmount > 0) {
            uint256 remaining = status.goalAmount > status.currentAmount ? 
                status.goalAmount - status.currentAmount : 0;
                
            if (amountToSave > remaining) {
                amountToSave = remaining;
            }
        }
        
        return amountToSave;
    }
    
    // Check allowance and balance without reverting
    function _checkAllowanceAndBalance(
        address user,
        address token,
        uint256 amount
    ) internal view returns (bool sufficient, string memory reason) {
        if (amount == 0) return (false, "Zero amount");
        
        uint256 allowance = IERC20(token).allowance(user, address(this));
        if (allowance < amount) return (false, "Insufficient allowance");
        
        uint256 balance = IERC20(token).balanceOf(user);
        if (balance < amount) return (false, "Insufficient balance");
        
        return (true, "");
    }
    
    // Withdraw savings with optimized error handling
    function withdrawDailySavings(
        address user,
        address token,
        uint256 amount
    ) external override onlyAuthorized(user) nonReentrant returns (uint256) {
        // Prepare all withdrawal data with validation
        WithdrawalContext memory context = _prepareWithdrawalContext(user, token, amount);
        
        // Process the withdrawal
        _processWithdrawal(user, token, amount, context);
        
        emit DailySavingsWithdrawn(user, token, amount, context.penalty, context.goalReached);
        return context.netAmount;
    }
    
    // Prepare withdrawal context with all necessary data
    function _prepareWithdrawalContext(
        address user,
        address token,
        uint256 amount
    ) internal view returns (WithdrawalContext memory context) {
        // Validate amount
        if (amount == 0) revert InvalidAmount();
        
        // Get configuration in a single storage read
        (context.enabled, , , context.goalAmount, context.currentAmount, context.penaltyBps, ) = 
            storage_.getDailySavingsConfig(user, token);
            
        if (!context.enabled) revert NoSavingsConfigured();
        
        // Check if user has enough saved tokens
        uint256 tokenId = tokenModule.getTokenId(token);
        context.userBalance = tokenModule.balanceOf(user, tokenId);
        
        if (context.userBalance < amount) {
            revert InsufficientBalance(amount, context.userBalance);
        }
        
        // Calculate goal reached status
        context.goalReached = context.goalAmount > 0 && context.currentAmount >= context.goalAmount;
        
        // Calculate penalty if applicable
        context.penalty = context.goalReached ? 0 : (amount * context.penaltyBps) / BPS_DENOMINATOR;
        
        // Calculate net amount
        context.netAmount = amount - context.penalty;
        
        return context;
    }
    
    // Process withdrawal with error handling
    function _processWithdrawal(
        address user,
        address token,
        uint256 amount,
        WithdrawalContext memory context
    ) internal {
        // Burn tokens first to enforce CEI pattern
        uint256 tokenId = tokenModule.getTokenId(token);

        if (tokenId == 0) {
            revert TokenNotRegistered(token);
        }

        tokenModule.burnSavingsToken(user, tokenId, amount);
        
        // Update saved amount in storage
        _updateConfigAfterWithdrawal(user, token, amount, context.currentAmount);
        
        // Transfer funds with error handling
        _transferWithdrawalFunds(user, token, context.netAmount, context.penalty);
    }
    
    // Update config after withdrawal
    function _updateConfigAfterWithdrawal(
        address user, 
        address token, 
        uint256 amount, 
        uint256 currentAmount
    ) internal {
        // Calculate new amount after withdrawal
        uint256 newAmount = currentAmount >= amount ? currentAmount - amount : 0;
        
        // Get current config first (except currentAmount which we already have)
        (bool enabled, , , uint256 goalAmount, , uint256 penaltyBps, uint256 endTime) = 
            storage_.getDailySavingsConfig(user, token);
        
        // Create parameter struct
        SpendSaveStorage.DailySavingsConfigParams memory params = SpendSaveStorage.DailySavingsConfigParams({
            enabled: enabled,
            lastExecutionTime: block.timestamp, // or retrieve the correct value if needed
            startTime: block.timestamp, // set appropriately if you have this info, else 0
            goalAmount: goalAmount,
            currentAmount: newAmount,
            penaltyBps: penaltyBps,
            endTime: endTime
        });

        storage_.setDailySavingsConfig(user, token, params);
    }
    
    // Transfer withdrawal funds with error handling
    function _transferWithdrawalFunds(
        address user,
        address token,
        uint256 netAmount,
        uint256 penalty
    ) internal {
        // Transfer net amount to user with proper error handling
        try IERC20(token).transfer(user, netAmount) {
            // Success - continue to penalty transfer if needed
        } catch {
            revert WithdrawalFailed();
        }
        
        // Transfer penalty to treasury if applicable
        if (penalty > 0) {
            address treasury = storage_.treasury();
            // Use safeTransfer for penalty - it's ok if this fails
            try IERC20(token).transfer(treasury, penalty) {
                // Success
            } catch {
                // If penalty transfer fails, we don't revert since the user already got their funds
                emit TransferError(user, token, "Failed to transfer penalty to treasury");
            }
        }
    }
    
    // Set yield strategy for a token
    function setDailySavingsYieldStrategy(
        address user,
        address token,
        SpendSaveStorage.YieldStrategy strategy
    ) external override onlyAuthorized(user) nonReentrant {
        _validateSavingsEnabled(user, token);
        
        storage_.setDailySavingsYieldStrategy(user, token, strategy);
        
        emit DailySavingsYieldStrategySet(user, token, strategy);
    }
    
    // Check if user has any pending daily savings - optimized for gas
    function hasPendingDailySavings(address user) external view override returns (bool) {
        address[] memory tokens = storage_.getUserSavingsTokens(user);
        
        for (uint i = 0; i < tokens.length; i++) {
            // Use lighter-weight check without detailed data
            if (_hasTokenPendingSavings(user, tokens[i])) {
                return true;
            }
        }
        
        return false;
    }
    
    // Light-weight check for pending savings for a single token
    function _hasTokenPendingSavings(address user, address token) internal view returns (bool) {
        // Get enabled status and last execution time
        (bool enabled, uint256 lastExecutionTime, , uint256 goalAmount, uint256 currentAmount, , ) = 
            storage_.getDailySavingsConfig(user, token);
            
        // Quick checks
        if (!enabled) return false;
        if (goalAmount > 0 && currentAmount >= goalAmount) return false;
        
        // Check if at least one day has passed
        uint256 daysPassed = (block.timestamp - lastExecutionTime) / ONE_DAY_IN_SECONDS;
        if (daysPassed == 0) return false;
        
        // Get daily amount
        uint256 dailyAmount = storage_.dailySavingsAmounts(user, token);
        if (dailyAmount == 0) return false;
        
        // Basic allowance and balance check (lightweight version)
        uint256 amount = dailyAmount * daysPassed;
        if (goalAmount > 0) {
            uint256 remaining = goalAmount > currentAmount ? goalAmount - currentAmount : 0;
            if (amount > remaining) amount = remaining;
        }
        
        // Skip transfer-from allowance check for gas efficiency
        return IERC20(token).balanceOf(user) >= amount;
    }
    
    // Get daily execution status with optimized gas usage
    function getDailyExecutionStatus(
        address user,
        address token
    ) public view override returns (
        bool canExecute,
        uint256 daysPassed,
        uint256 amountToSave
    ) {
        // Get status in a gas-efficient way
        DailySavingsStatus memory status = _getDailySavingsStatus(user, token);
        
        // Early returns for common cases
        if (!status.enabled || status.goalReached || status.daysPassed == 0) {
            return (false, status.daysPassed, 0);
        }
        
        // Calculate amount to save
        amountToSave = _calculateSavingsAmount(status);
        
        // Check if we have anything to save
        if (amountToSave == 0) {
            return (false, status.daysPassed, 0);
        }
        
        // Check allowance and balance
        (canExecute, ) = _checkAllowanceAndBalance(user, token, amountToSave);
        
        return (canExecute, status.daysPassed, amountToSave);
    }
    
    // Get comprehensive savings status with all details
    function getDailySavingsStatus(
        address user,
        address token
    ) external view override returns (
        bool enabled,
        uint256 dailyAmount,
        uint256 goalAmount,
        uint256 currentAmount,
        uint256 remainingAmount,
        uint256 penaltyAmount,
        uint256 estimatedCompletionDate
    ) {
        // Get complete status in a single function call
        DailySavingsStatus memory status = _getDailySavingsStatus(user, token);
        
        if (!status.enabled) return (false, 0, 0, 0, 0, 0, 0);
        
        // Calculate remaining amount
        remainingAmount = status.goalAmount > status.currentAmount ? 
            status.goalAmount - status.currentAmount : 0;
        
        // Calculate penalty amount
        penaltyAmount = (status.currentAmount * status.penaltyBps) / BPS_DENOMINATOR;
        
        // Calculate estimated completion date
        estimatedCompletionDate = _estimateCompletionDate(
            status.dailyAmount,
            remainingAmount,
            status.goalAmount,
            status.currentAmount,
            status.endTime
        );
        
        return (
            status.enabled,
            status.dailyAmount,
            status.goalAmount,
            status.currentAmount,
            remainingAmount,
            penaltyAmount,
            estimatedCompletionDate
        );
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

    // Helper to mint savings token for daily savings
    function _mintSavingsTokenForDailySavings(address user, address token, uint256 amount) internal {
        if (address(tokenModule) != address(0) && amount > 0) {
            uint256 tokenId = tokenModule.getTokenId(token);
            if (tokenId == 0) {
                tokenId = tokenModule.registerToken(token);
            }
            try tokenModule.mintSavingsToken(user, tokenId, amount) {
                // Success - could emit specific daily savings event here
            } catch {
                // Handle error appropriately for daily savings context
            }
        }
    }
    
    /**
     * @notice Execute daily savings for a specific token
     * @dev Simplified version for direct token execution
     * @param user The user address
     * @param token The token address
     * @return amount The amount that was saved
     */
    function executeTokenSavings(address user, address token) 
        external 
        override 
        returns (uint256 amount) 
    {
        // Check if daily savings is enabled for this user/token
        (bool enabled,,,,,,) = storage_.getDailySavingsConfig(user, token);
        if (!enabled) return 0;
        
        // Get daily savings configuration
        SpendSaveStorage.DailySavingsConfigParams memory config = storage_.getDailySavingsConfigParams(user, token);
        
        // Check if execution is due (at least one day has passed)
        if (block.timestamp < config.lastExecutionTime + ONE_DAY_IN_SECONDS) return 0;
        
        // Get user's token balance
        uint256 balance = IERC20(token).balanceOf(user);
        if (balance == 0) return 0;
        
        // Get daily amount from storage
        uint256 dailyAmount = storage_.dailySavingsAmounts(user, token);
        if (dailyAmount == 0) return 0;
        
        // Calculate amount to save (use daily amount, not percentage-based)
        amount = dailyAmount > balance ? balance : dailyAmount;
        
        // Check if we have a goal and don't exceed it
        if (config.goalAmount > 0) {
            uint256 remaining = config.goalAmount > config.currentAmount ? 
                config.goalAmount - config.currentAmount : 0;
            if (amount > remaining) {
                amount = remaining;
            }
        }
        
        if (amount == 0) return 0;
        
        // Check allowance and balance
        (bool sufficientFunds, ) = _checkAllowanceAndBalance(user, token, amount);
        if (!sufficientFunds) return 0;
        
        // Execute the savings using the existing infrastructure
        uint256 savedAmount = _executeTokenSavings(user, token, amount);
        
        if (savedAmount > 0) {
            // Update storage and process tokens
            _updateSavingsState(user, token, savedAmount);
            
            emit DailySavingsExecuted(user, token, savedAmount, 0); // gasUsed = 0 for simplicity
        }
        
        return savedAmount;
    }
}