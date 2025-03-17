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
        if (percentage > 10000) revert PercentageTooHigh({provided: percentage, max: 10000});
        if (maxPercentage > 10000) revert PercentageTooHigh({provided: maxPercentage, max: 10000});
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
        SpendSaveStorage.SavingStrategy memory strategy;
        
        // Use accessor method to get the saving strategy
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
        
        // Update goal amount
        strategy.goalAmount = amount;
        
        // Update strategy in storage
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
        
        emit GoalSet(user, token, amount);
    }
    
    // Prepare for savings before swap
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) external override nonReentrant {
        if (msg.sender != address(storage_) && msg.sender != storage_.spendSaveHook()) revert OnlyHook();
        
        // Initialize context and exit early if no strategy
        SwapContextBuilder memory builder = _initializeContextBuilder(sender);
        
        if (!builder.context.hasStrategy) {
            storage_.setSwapContext(sender, builder.context);
            return;
        }
        
        // Complete the context preparation
        _prepareSwapContext(builder, key, params);
        
        // Process input token savings if applicable
        if (builder.context.savingsTokenType == SpendSaveStorage.SavingsTokenType.INPUT) {
            _processInputTokenSavings(sender, builder.context);
        }
        
        // Store the context in storage for use in afterSwap
        storage_.setSwapContext(sender, builder.context);
        
        emit SwapPrepared(sender, builder.context.currentPercentage, builder.strategy.savingsTokenType);
    }

    function _initializeContextBuilder(
        address user
    ) internal view returns (SwapContextBuilder memory) {
        SwapContextBuilder memory builder;
        
        // Get user's saving strategy
        builder.strategy = _getUserSavingStrategy(user);
        
        // Initialize context with strategy flag
        builder.context.hasStrategy = builder.strategy.percentage > 0;
        
        return builder;
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

    // Helper function to prepare swap context
    function _prepareSwapContext(
        SwapContextBuilder memory builder,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) internal view {
        // Get current tick from pool
        builder.context.currentTick = getCurrentTick(key);
        
        // Calculate current percentage with auto-increment if applicable
        builder.context.currentPercentage = _calculateCurrentPercentage(
            builder.strategy.percentage,
            builder.strategy.autoIncrement,
            builder.strategy.maxPercentage
        );
        
        // Copy basic properties from strategy to context
        _copyStrategyToContext(builder);
        
        // For INPUT token savings type, extract input token and amount
        if (builder.strategy.savingsTokenType == SpendSaveStorage.SavingsTokenType.INPUT) {
            (builder.context.inputToken, builder.context.inputAmount) = 
                _extractInputTokenAndAmount(key, params);
        }
    }


    function _copyStrategyToContext(SwapContextBuilder memory builder) internal view {
        builder.context.roundUpSavings = builder.strategy.roundUpSavings;
        builder.context.enableDCA = builder.strategy.enableDCA;
        builder.context.dcaTargetToken = storage_.dcaTargetToken(msg.sender);
        builder.context.savingsTokenType = builder.strategy.savingsTokenType;
        builder.context.specificSavingsToken = builder.strategy.specificSavingsToken;
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
        if (params.zeroForOne) {
            token = Currency.unwrap(key.currency0);
        } else {
            token = Currency.unwrap(key.currency1);
        }
        
        amount = uint256(params.amountSpecified > 0 ? params.amountSpecified : -params.amountSpecified);
        return (token, amount);
    }

    // Helper to process input token savings
    function _processInputTokenSavings(
        address sender,
        SpendSaveStorage.SwapContext memory context
    ) internal {
        // Skip if no input amount
        if (context.inputAmount == 0) return;
        
        // Calculate savings amount
        SavingsCalculation memory calc = _calculateInputSavings(context);
        
        // Skip if nothing to save
        if (calc.saveAmount == 0) return;
        
        // Execute the savings transfer and processing
        _executeSavingsTransfer(sender, context.inputToken, calc.saveAmount);
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

    function _executeSavingsTransfer(
        address sender,
        address token,
        uint256 amount
    ) internal returns (bool) {
        // Try to transfer tokens for savings
        bool success = _transferTokensForSavings(sender, token, amount);
        
        if (success) {
            // Apply fee and process savings
            uint256 netAmount = _applyFeeAndProcessSavings(sender, token, amount);
            
            // Emit event for tracking
            emit InputTokenSaved(sender, token, netAmount, amount - netAmount);
        }
        
        return success;
    }

    // Helper to apply saving limits
    function _applySavingLimits(uint256 saveAmount, uint256 inputAmount) internal pure returns (uint256) {
        if (saveAmount >= inputAmount) {
            return inputAmount / 2; // Save at most half to ensure swap continues
        }
        return saveAmount;
    }

    // Helper to transfer tokens for savings
    function _transferTokensForSavings(
        address sender,
        address token,
        uint256 amount
    ) internal returns (bool success) {
        try IERC20(token).transferFrom(sender, address(this), amount) {
            return true;
        } catch (bytes memory reason) {
            emit TransferFailure(sender, token, amount, reason);
            return false;
        }
    }

    // Helper to apply fee and process savings
    function _applyFeeAndProcessSavings(
        address sender,
        address token,
        uint256 amount
    ) internal returns (uint256) {
        // Apply treasury fee if configured
        uint256 amountAfterFee = storage_.calculateAndTransferFee(sender, token, amount);
        
        // If a fee was taken, emit an event
        if (amountAfterFee < amount) {
            uint256 fee = amount - amountAfterFee;
            emit TreasuryFeeCollected(sender, token, fee);
        }
        
        // Process the savings through the savings module
        savingsModule.processSavings(sender, token, amountAfterFee);
        
        return amountAfterFee;
    }
    





    // Update user's saving strategy after swap
    function updateSavingStrategy(address sender, SpendSaveStorage.SwapContext memory context) external override nonReentrant {
        if (msg.sender != address(storage_) && msg.sender != storage_.spendSaveHook()) revert OnlyHook();
        
        // Get current strategy
        SpendSaveStorage.SavingStrategy memory strategy;
        
        // Use accessor method to get the saving strategy
        (
            strategy.percentage,
            strategy.autoIncrement,
            strategy.maxPercentage,
            strategy.goalAmount,
            strategy.roundUpSavings,
            strategy.enableDCA,
            strategy.savingsTokenType,
            strategy.specificSavingsToken
        ) = storage_.getUserSavingStrategy(sender);
        
        if (strategy.autoIncrement > 0 && context.currentPercentage > strategy.percentage) {
            // Only update if auto-increment is enabled and the percentage has increased
            strategy.percentage = context.currentPercentage;
            
            // Update the strategy in storage
            storage_.setUserSavingStrategy(
                sender,
                strategy.percentage,
                strategy.autoIncrement,
                strategy.maxPercentage,
                strategy.goalAmount,
                strategy.roundUpSavings,
                strategy.enableDCA,
                strategy.savingsTokenType,
                strategy.specificSavingsToken
            );

            emit SavingStrategyUpdated(sender, strategy.percentage);
        }
    }
    
    // Calculate savings amount based on percentage and rounding preference
    function calculateSavingsAmount(
        uint256 amount,
        uint256 percentage,
        bool roundUp
    ) public pure override returns (uint256) {
        uint256 saveAmount = (amount * percentage) / 10000;
        
        if (roundUp && saveAmount > 0) {
            // Round up to nearest whole token unit (assuming 18 decimals)
            uint256 remainder = saveAmount % 1e18;
            if (remainder > 0) {
                saveAmount += (1e18 - remainder);
            }
        }
        
        return saveAmount;
    }
    
    // Get current pool tick
    function getCurrentTick(PoolKey memory poolKey) internal view returns (int24) {
        PoolId poolId = poolKey.toId();
        
        // Use StateLibrary to get the current tick from pool manager
        (,int24 currentTick,,) = StateLibrary.getSlot0(storage_.poolManager(), poolId);
        
        return currentTick;
    }
}