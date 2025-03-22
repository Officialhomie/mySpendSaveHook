// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IERC20} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StateLibrary} from "lib/v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {ReentrancyGuard} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import "./SpendSaveStorage.sol";
import "./ISavingStrategyModule.sol";
import "./ISavingsModule.sol";

/**
 * @title SavingStrategy
 * @dev Handles user saving strategies and swap preparation
 */
contract SavingStrategy is ISavingStrategyModule, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    
    // Cached constants to reduce gas costs
    uint256 private constant PERCENTAGE_DENOMINATOR = 10000;
    uint256 private constant MAX_PERCENTAGE = 10000; // 100%
    uint256 private constant TOKEN_UNIT = 1e18; // Assuming 18 decimals

    struct SavingStrategyParams {
        uint256 percentage;
        uint256 autoIncrement;
        uint256 maxPercentage;
        bool roundUpSavings;
        SpendSaveStorage.SavingsTokenType savingsTokenType;
        address specificSavingsToken;
    }

    struct SwapContextBuilder {
        SpendSaveStorage.SwapContext context;
        SpendSaveStorage.SavingStrategy strategy;
    }

    struct SavingsCalculation {
        uint256 saveAmount;
        uint256 reducedSwapAmount;
    }

    // Storage reference
    SpendSaveStorage public storage_;
    
    // Module references
    ISavingsModule public savingsModule;
    
    // Events
    event SavingStrategySet(address indexed user, uint256 percentage, uint256 autoIncrement, uint256 maxPercentage, SpendSaveStorage.SavingsTokenType tokenType);
    event GoalSet(address indexed user, address indexed token, uint256 amount);
    event SwapPrepared(address indexed user, uint256 currentSavePercentage, SpendSaveStorage.SavingsTokenType tokenType);
    event SpecificSavingsTokenSet(address indexed user, address indexed token);
    event TransferFailure(address indexed user, address indexed token, uint256 amount, bytes reason);
    event InputTokenSaved(address indexed user, address indexed token, uint256 savedAmount, uint256 remainingSwapAmount);
    event ModuleInitialized(address indexed storage_);
    event ModuleReferencesSet(address indexed savingsModule);
    event SavingStrategyUpdated(address indexed user, uint256 newPercentage);
    event TreasuryFeeCollected(address indexed user, address indexed token, uint256 fee);
    event FailedToApplySavings(address user, string reason);

    // Define event declarations
    event ProcessingInputTokenSavings(address indexed sender, address indexed token, uint256 amount);
    event InputTokenSavingsSkipped(address indexed sender, string reason);
    event SavingsCalculated(address indexed sender, uint256 saveAmount, uint256 reducedSwapAmount);
    event UserBalanceChecked(address indexed sender, address indexed token, uint256 balance);
    event InsufficientBalance(address indexed sender, address indexed token, uint256 required, uint256 available);
    event AllowanceChecked(address indexed sender, address indexed token, uint256 allowance);
    event InsufficientAllowance(address indexed sender, address indexed token, uint256 required, uint256 available);
    event SavingsTransferStatus(address indexed sender, address indexed token, bool success);

    event SavingsTransferInitiated(address indexed sender, address indexed token, uint256 amount);
    event SavingsTransferSuccess(address indexed sender, address indexed token, uint256 amount, uint256 contractBalance);
    event SavingsTransferFailure(address indexed sender, address indexed token, uint256 amount, bytes reason);
    event NetAmountAfterFee(address indexed sender, address indexed token, uint256 netAmount);
    event UserSavingsUpdated(address indexed sender, address indexed token, uint256 newSavings);

    // Define event declarations
    event FeeApplied(address indexed sender, address indexed token, uint256 feeAmount);
    event SavingsProcessingFailed(address indexed sender, address indexed token, bytes reason);
    event SavingsProcessedSuccessfully(address indexed sender, address indexed token, uint256 amount);


    
    // Custom errors
    error PercentageTooHigh(uint256 provided, uint256 max);
    error MaxPercentageTooLow(uint256 maxPercentage, uint256 percentage);
    error InvalidSpecificToken();
    error SavingsTooHigh(uint256 saveAmount, uint256 inputAmount);
    error AlreadyInitialized();
    error OnlyUserOrHook();
    error OnlyHook();
    error OnlyOwner();
    error UnauthorizedCaller();
    
    // Constructor is empty since module will be initialized via initialize()
    constructor() {}

    modifier onlyAuthorized(address user) {
        if (msg.sender != user && 
            msg.sender != address(storage_) && 
            msg.sender != storage_.spendSaveHook()) {
            revert UnauthorizedCaller();
        }
        _;
    }
    
    // Initialize module with storage reference
    function initialize(SpendSaveStorage _storage) external override nonReentrant {
        if(address(storage_) != address(0)) revert AlreadyInitialized();
        storage_ = _storage;
        emit ModuleInitialized(address(_storage));
    }
    
    // Set references to other modules
    function setModuleReferences(address _savingsModule) external nonReentrant {
        if(msg.sender != storage_.owner()) revert OnlyOwner();
        savingsModule = ISavingsModule(_savingsModule);
        emit ModuleReferencesSet(_savingsModule);
    }
    
    // Public function to set a user's saving strategy
    function setSavingStrategy(
        address user, 
        uint256 percentage, 
        uint256 autoIncrement, 
        uint256 maxPercentage, 
        bool roundUpSavings,
        SpendSaveStorage.SavingsTokenType savingsTokenType, 
        address specificSavingsToken
    ) external override onlyAuthorized(user) nonReentrant {
        // Validation
        if (percentage > MAX_PERCENTAGE) revert PercentageTooHigh({provided: percentage, max: MAX_PERCENTAGE});
        if (maxPercentage > MAX_PERCENTAGE) revert PercentageTooHigh({provided: maxPercentage, max: MAX_PERCENTAGE});
        if (maxPercentage < percentage) revert MaxPercentageTooLow({maxPercentage: maxPercentage, percentage: percentage});
        
        if (savingsTokenType == SpendSaveStorage.SavingsTokenType.SPECIFIC) {
            if (specificSavingsToken == address(0)) revert InvalidSpecificToken();
        }
        
        // Get current strategy
        SpendSaveStorage.SavingStrategy memory strategy = _getUserSavingStrategy(user);
        
        // Update strategy values
        strategy.percentage = percentage;
        strategy.autoIncrement = autoIncrement;
        strategy.maxPercentage = maxPercentage;
        strategy.roundUpSavings = roundUpSavings;
        strategy.savingsTokenType = savingsTokenType;
        strategy.specificSavingsToken = specificSavingsToken;
        
        // Update the strategy in storage
        _saveUserStrategy(user, strategy);
        
        if (savingsTokenType == SpendSaveStorage.SavingsTokenType.SPECIFIC) {
            emit SpecificSavingsTokenSet(user, specificSavingsToken);
        }
        
        emit SavingStrategySet(user, percentage, autoIncrement, maxPercentage, savingsTokenType);
    }

    function _saveUserStrategy(
        address user, 
        SpendSaveStorage.SavingStrategy memory strategy
    ) internal {
        storage_.setUserSavingStrategy(
            user,
            strategy.percentage,
            strategy.autoIncrement,
            strategy.maxPercentage,
            strategy.goalAmount,
            strategy.roundUpSavings,
            strategy.enableDCA,
            strategy.savingsTokenType,
            strategy.specificSavingsToken
        );
    }
    
    // Set savings goal for a token
    function setSavingsGoal(address user, address token, uint256 amount) external override onlyAuthorized(user) nonReentrant {
        // Get current strategy
        SpendSaveStorage.SavingStrategy memory strategy = _getUserSavingStrategy(user);
        
        // Update goal amount
        strategy.goalAmount = amount;
        
        // Update strategy in storage
        _saveUserStrategy(user, strategy);
        
        emit GoalSet(user, token, amount);
    }
    
    // Prepare for savings before swap - optimized for gas usage
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) external override nonReentrant {
        if (msg.sender != address(storage_) && msg.sender != storage_.spendSaveHook()) revert OnlyHook();
        
        // Initialize context and exit early if no strategy
        SpendSaveStorage.SavingStrategy memory strategy = _getUserSavingStrategy(sender);
        
        // Fast path - no strategy
        if (strategy.percentage == 0) {
            SpendSaveStorage.SwapContext memory emptyContext;
            emptyContext.hasStrategy = false;
            storage_.setSwapContext(sender, emptyContext);
            return;
        }
        
        // Build context for swap with strategy
        SpendSaveStorage.SwapContext memory context = _buildSwapContext(sender, strategy, key, params);
        
        // Process input token savings if applicable
        if (context.savingsTokenType == SpendSaveStorage.SavingsTokenType.INPUT) {
            // Use proper error handling without try/catch
            bool success = _processInputTokenSavings(sender, context);
            if (!success) {
                emit FailedToApplySavings(sender, "Failed to process input token savings");
            }
        }
        
        // Store the context in storage for use in afterSwap
        storage_.setSwapContext(sender, context);
        
        emit SwapPrepared(sender, context.currentPercentage, strategy.savingsTokenType);
    }

    // New helper function to build swap context
    function _buildSwapContext(
        address user,
        SpendSaveStorage.SavingStrategy memory strategy,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) internal view returns (SpendSaveStorage.SwapContext memory context) {
        context.hasStrategy = true;
        
        // Calculate current percentage with auto-increment if applicable
        context.currentPercentage = _calculateCurrentPercentage(
            strategy.percentage,
            strategy.autoIncrement,
            strategy.maxPercentage
        );
        
        // Get current tick from pool
        context.currentTick = _getCurrentTick(key);
        
        // Copy properties from strategy to context
        context.roundUpSavings = strategy.roundUpSavings;
        context.enableDCA = strategy.enableDCA;
        context.dcaTargetToken = storage_.dcaTargetToken(user);
        context.savingsTokenType = strategy.savingsTokenType;
        context.specificSavingsToken = strategy.specificSavingsToken;
        
        // For INPUT token savings type, extract input token and amount
        if (strategy.savingsTokenType == SpendSaveStorage.SavingsTokenType.INPUT) {
            (context.inputToken, context.inputAmount) = _extractInputTokenAndAmount(key, params);
        }
        
        return context;
    }

    // Helper function to get user saving strategy
    function _getUserSavingStrategy(address user) internal view returns (SpendSaveStorage.SavingStrategy memory strategy) {
        (
            strategy.percentage,
            strategy.autoIncrement,
            strategy.maxPercentage,
            strategy.goalAmount,
            strategy.roundUpSavings,
            strategy.enableDCA,
            strategy.savingsTokenType,
            strategy.specificSavingsToken
        ) = storage_.getUserSavingStrategy(user);
        
        return strategy;
    }

    // Helper to calculate the current saving percentage with auto-increment
    function _calculateCurrentPercentage(
        uint256 basePercentage,
        uint256 autoIncrement,
        uint256 maxPercentage
    ) internal pure returns (uint256) {
        if (autoIncrement == 0 || basePercentage >= maxPercentage) {
            return basePercentage;
        }
        
        uint256 newPercentage = basePercentage + autoIncrement;
        return newPercentage > maxPercentage ? maxPercentage : newPercentage;
    }

    // Helper to extract input token and amount from swap params
    function _extractInputTokenAndAmount(
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) internal pure returns (address token, uint256 amount) {
        token = params.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        amount = uint256(params.amountSpecified > 0 ? params.amountSpecified : -params.amountSpecified);
        return (token, amount);
    }

    // Helper to process input token savings - returns success status instead of using try/catch
    function _processInputTokenSavings(
        address sender,
        SpendSaveStorage.SwapContext memory context
    ) internal returns (bool) {
        emit ProcessingInputTokenSavings(sender, context.inputToken, context.inputAmount);
        
        // Skip if no input amount
        if (context.inputAmount == 0) {
            emit InputTokenSavingsSkipped(sender, "Input amount is 0");
            return true;
        }
        
        // Calculate savings amount
        SavingsCalculation memory calc = _calculateInputSavings(context);
        emit SavingsCalculated(sender, calc.saveAmount, calc.reducedSwapAmount);
        
        // Skip if nothing to save
        if (calc.saveAmount == 0) {
            emit InputTokenSavingsSkipped(sender, "Save amount is 0");
            return true;
        }
        
        // Check user balance before transfer
        try IERC20(context.inputToken).balanceOf(sender) returns (uint256 balance) {
            emit UserBalanceChecked(sender, context.inputToken, balance);
            if (balance < calc.saveAmount) {
                emit InsufficientBalance(sender, context.inputToken, calc.saveAmount, balance);
                return false;
            }
        } catch {
            emit InputTokenSavingsSkipped(sender, "Failed to check balance");
            return false;
        }
        
        // Check user allowance before transfer
        try IERC20(context.inputToken).allowance(sender, address(this)) returns (uint256 allowance) {
            emit AllowanceChecked(sender, context.inputToken, allowance);
            if (allowance < calc.saveAmount) {
                emit InsufficientAllowance(sender, context.inputToken, calc.saveAmount, allowance);
                return false;
            }
        } catch {
            emit InputTokenSavingsSkipped(sender, "Failed to check allowance");
            return false;
        }
        
        // Execute the savings transfer and processing
        bool success = _executeSavingsTransfer(sender, context.inputToken, calc.saveAmount);
        emit SavingsTransferStatus(sender, context.inputToken, success);
        
        return success;
    }



    function _calculateInputSavings(
        SpendSaveStorage.SwapContext memory context
    ) internal view returns (SavingsCalculation memory) {
        uint256 inputAmount = context.inputAmount;
        
        uint256 saveAmount = calculateSavingsAmount(
            inputAmount,
            context.currentPercentage,
            context.roundUpSavings
        );
        
        if (saveAmount == 0) {
            return SavingsCalculation({
                saveAmount: 0,
                reducedSwapAmount: inputAmount
            });
        }
        
        // Apply safety check for saving amount
        saveAmount = _applySavingLimits(saveAmount, inputAmount);
        
        // Calculate the remaining amount after savings
        uint256 reducedSwapAmount = inputAmount - saveAmount;
        
        return SavingsCalculation({
            saveAmount: saveAmount,
            reducedSwapAmount: reducedSwapAmount
        });
    }

    // function _executeSavingsTransfer(
    //     address sender,
    //     address token,
    //     uint256 amount
    // ) internal returns (bool) {
    //     // Try to transfer tokens for savings using try/catch
    //     try IERC20(token).transferFrom(sender, address(this), amount) {
    //         // Apply fee and process savings
    //         uint256 netAmount = _applyFeeAndProcessSavings(sender, token, amount);
            
    //         // Emit event for tracking
    //         emit InputTokenSaved(sender, token, netAmount, amount - netAmount);
            
    //         return true;
    //     } catch (bytes memory reason) {
    //         emit TransferFailure(sender, token, amount, reason);
    //         return false;
    //     }
    // }

    function _executeSavingsTransfer(
        address sender,
        address token,
        uint256 amount
    ) internal returns (bool) {
        emit SavingsTransferInitiated(sender, token, amount);
        
        bool transferSuccess = false;

        // Try to transfer tokens for savings using try/catch
        try IERC20(token).transferFrom(sender, address(this), amount) {
            transferSuccess = true;
            
            // Double-check that we received the tokens
            uint256 contractBalance = IERC20(token).balanceOf(address(this));
            emit SavingsTransferSuccess(sender, token, amount, contractBalance);
            
            // Apply fee and process savings
            uint256 netAmount = _applyFeeAndProcessSavings(sender, token, amount);
            emit NetAmountAfterFee(sender, token, netAmount);
            
            // Emit event for tracking user savings update
            uint256 userSavings = storage_.savings(sender, token);
            emit UserSavingsUpdated(sender, token, userSavings);
            
            return true;
        } catch Error(string memory reason) {
            emit SavingsTransferFailure(sender, token, amount, bytes(reason));
            return false;
        } catch (bytes memory reason) {
            emit SavingsTransferFailure(sender, token, amount, reason);
            return false;
        }
    }



    // Helper to apply saving limits
    function _applySavingLimits(uint256 saveAmount, uint256 inputAmount) internal pure returns (uint256) {
        if (saveAmount >= inputAmount) {
            return inputAmount / 2; // Save at most half to ensure swap continues
        }
        return saveAmount;
    }

    // Helper to apply fee and process savings
    function _applyFeeAndProcessSavings(
        address sender,
        address token,
        uint256 amount
    ) internal returns (uint256) {
        // Apply treasury fee if configured
        uint256 amountAfterFee = storage_.calculateAndTransferFee(sender, token, amount);

        // Emit event if a fee was taken
        if (amountAfterFee < amount) {
            uint256 fee = amount - amountAfterFee;
            emit FeeApplied(sender, token, fee);
        }

        // Ensure we have the correct savingsModule reference
        if (address(savingsModule) == address(0)) {
            emit SavingsProcessingFailed(sender, token, "Savings module reference is null");
            return 0;
        }

        // Process the savings through the savings module
        try savingsModule.processSavings(sender, token, amountAfterFee) {
            emit SavingsProcessedSuccessfully(sender, token, amountAfterFee);
        } catch Error(string memory reason) {
            emit SavingsProcessingFailed(sender, token, bytes(reason));
            return 0;
        } catch (bytes memory reason) {
            emit SavingsProcessingFailed(sender, token, reason);
            return 0;
        }

        return amountAfterFee;
    }

    
    // Update user's saving strategy after swap - optimized to only update when needed
    function updateSavingStrategy(address sender, SpendSaveStorage.SwapContext memory context) external override nonReentrant {
        if (msg.sender != address(storage_) && msg.sender != storage_.spendSaveHook()) revert OnlyHook();
        
        // Early return if no auto-increment or no percentage change
        if (!_shouldUpdateStrategy(sender, context.currentPercentage)) return;
        
        // Get current strategy
        SpendSaveStorage.SavingStrategy memory strategy = _getUserSavingStrategy(sender);
        
        // Update percentage
        strategy.percentage = context.currentPercentage;
        
        // Update the strategy in storage
        _saveUserStrategy(sender, strategy);

        emit SavingStrategyUpdated(sender, strategy.percentage);
    }
    
    // Helper to check if strategy should be updated
    function _shouldUpdateStrategy(address user, uint256 currentPercentage) internal view returns (bool) {
        SpendSaveStorage.SavingStrategy memory strategy = _getUserSavingStrategy(user);
        return strategy.autoIncrement > 0 && currentPercentage > strategy.percentage;
    }
    
    // Calculate savings amount based on percentage and rounding preference - gas optimized
    function calculateSavingsAmount(
        uint256 amount,
        uint256 percentage,
        bool roundUp
    ) public pure override returns (uint256) {
        if (percentage == 0) return 0;
        
        uint256 saveAmount = (amount * percentage) / PERCENTAGE_DENOMINATOR;
        
        if (roundUp && saveAmount > 0 && saveAmount % TOKEN_UNIT != 0) {
            // Round up to nearest whole token unit (assuming 18 decimals)
            uint256 remainder = saveAmount % TOKEN_UNIT;
            saveAmount += (TOKEN_UNIT - remainder);
        }
        
        return saveAmount;
    }
    
    // Get current pool tick - cached function for gas optimization
    function _getCurrentTick(PoolKey memory poolKey) internal view returns (int24) {
        PoolId poolId = poolKey.toId();
        
        // Use StateLibrary to get the current tick from pool manager
        (,int24 currentTick,,) = StateLibrary.getSlot0(storage_.poolManager(), poolId);
        
        return currentTick;
    }
}