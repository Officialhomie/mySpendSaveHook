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
import {
    BeforeSwapDelta,
    toBeforeSwapDelta
    } from "lib/v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {Currency} from "v4-core/types/Currency.sol";

import "./SpendSaveStorage.sol";
import "./ISavingStrategyModule.sol";
import "./ISavingsModule.sol";

/**j
 * @title SavingStrategy
 * @dev Handles user saving strategies and swap preparation
 */
contract SavingStrategy is ISavingStrategyModule, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using CurrencySettler for Currency;
    
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
    event ProcessingInputTokenSavings(address indexed actualUser, address indexed token, uint256 amount);
    event InputTokenSavingsSkipped(address indexed actualUser, string reason);
    event SavingsCalculated(address indexed actualUser, uint256 saveAmount, uint256 reducedSwapAmount);
    event UserBalanceChecked(address indexed actualUser, address indexed token, uint256 balance);
    event InsufficientBalance(address indexed actualUser, address indexed token, uint256 required, uint256 available);
    event AllowanceChecked(address indexed actualUser, address indexed token, uint256 allowance);
    event InsufficientAllowance(address indexed actualUser, address indexed token, uint256 required, uint256 available);
    event SavingsTransferStatus(address indexed actualUser, address indexed token, bool success);

    event SavingsTransferInitiated(address indexed actualUser, address indexed token, uint256 amount);
    event SavingsTransferSuccess(address indexed actualUser, address indexed token, uint256 amount, uint256 contractBalance);
    event SavingsTransferFailure(address indexed actualUser, address indexed token, uint256 amount, bytes reason);
    event NetAmountAfterFee(address indexed actualUser, address indexed token, uint256 netAmount);
    event UserSavingsUpdated(address indexed actualUser, address indexed token, uint256 newSavings);

    // Define event declarations
    event FeeApplied(address indexed actualUser, address indexed token, uint256 feeAmount);
    event SavingsProcessingFailed(address indexed actualUser, address indexed token, bytes reason);
    event SavingsProcessedSuccessfully(address indexed actualUser, address indexed token, uint256 amount);

    event ProcessInputSavingsAfterSwapCalled(
        address indexed actualUser,
        address indexed inputToken,
        uint256 pendingSaveAmount
    );


    
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
        address actualUser, 
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) external virtual override nonReentrant returns (BeforeSwapDelta) {
        if (msg.sender != address(storage_) && msg.sender != storage_.spendSaveHook()) revert OnlyHook();

        // Initialize context and exit early if no strategy
        SpendSaveStorage.SavingStrategy memory strategy = _getUserSavingStrategy(actualUser);

        // Fast path - no strategy
        if (strategy.percentage == 0) {
            SpendSaveStorage.SwapContext memory emptyContext;
            emptyContext.hasStrategy = false;
            storage_.setSwapContext(actualUser, emptyContext);
            return toBeforeSwapDelta(0, 0); // No adjustment for either currency
        }

        // Build context for swap with strategy
        SpendSaveStorage.SwapContext memory context = _buildSwapContext(actualUser, strategy, key, params);

        // Process input token savings if applicable
        int128 specifiedDelta = 0;
        int128 unspecifiedDelta = 0;
        
        if (context.savingsTokenType == SpendSaveStorage.SavingsTokenType.INPUT) {
            // Calculate savings amount
            SavingsCalculation memory calc = _calculateInputSavings(context);
            
            if (calc.saveAmount > 0) {
                // Store amount for processing in afterSwap
                context.pendingSaveAmount = calc.saveAmount;
                
                // FIXED: Use positive deltas to REDUCE the swap amount
                if (params.zeroForOne) {
                    if (params.amountSpecified < 0) {
                        // Exact input swap: Reduce the swap amount
                        specifiedDelta = int128(int256(calc.saveAmount));
                    } else {
                        // Exact output swap: Reduce the unspecified amount
                        unspecifiedDelta = int128(int256(calc.saveAmount));
                    }
                } else {
                    if (params.amountSpecified < 0) {
                        // Exact input swap: Reduce the swap amount
                        specifiedDelta = int128(int256(calc.saveAmount));
                    } else {
                        // Exact output swap: Reduce the unspecified amount
                        unspecifiedDelta = int128(int256(calc.saveAmount));
                    }
                }
            }
        }

        // Store context
        storage_.setSwapContext(actualUser, context);
        
        emit SwapPrepared(actualUser, context.currentPercentage, strategy.savingsTokenType);

        // Return the delta for both currencies using the toBeforeSwapDelta helper
        return toBeforeSwapDelta(specifiedDelta, unspecifiedDelta);
    }

    // New helper function to build swap context
    function _buildSwapContext(
        address user,
        SpendSaveStorage.SavingStrategy memory strategy,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) internal view virtual returns (SpendSaveStorage.SwapContext memory context) {
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
    ) internal pure virtual returns (address token, uint256 amount) {
        token = params.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        amount = uint256(params.amountSpecified > 0 ? params.amountSpecified : -params.amountSpecified);
        return (token, amount);
    }

    // Helper to process input token savings 
    // Process the actual input token savings - only executes the transfer and processing
    function _processInputTokenSavings(
        address actualUser,
        SpendSaveStorage.SwapContext memory context
    ) internal returns (bool) {
        // Skip if no input amount
        if (context.inputAmount == 0) {
            emit InputTokenSavingsSkipped(actualUser, "Input amount is 0");
            return false;
        }
        
        // Calculate savings amount
        SavingsCalculation memory calc = _calculateInputSavings(context);
        
        // Skip if nothing to save
        if (calc.saveAmount == 0) {
            emit InputTokenSavingsSkipped(actualUser, "Save amount is 0");
            return false;
        }
        
        // Check user balance before transfer
        try IERC20(context.inputToken).balanceOf(actualUser) returns (uint256 balance) {
            emit UserBalanceChecked(actualUser, context.inputToken, balance);
            if (balance < calc.saveAmount) {
                emit InsufficientBalance(actualUser, context.inputToken, calc.saveAmount, balance);
                return false;
            }
        } catch {
            emit InputTokenSavingsSkipped(actualUser, "Failed to check balance");
            return false;
        }
        
        // Check user allowance before transfer
        try IERC20(context.inputToken).allowance(actualUser, address(this)) returns (uint256 allowance) {
            emit AllowanceChecked(actualUser, context.inputToken, allowance);
            if (allowance < calc.saveAmount) {
                emit InsufficientAllowance(actualUser, context.inputToken, calc.saveAmount, allowance);
                return false;
            }
        } catch {
            emit InputTokenSavingsSkipped(actualUser, "Failed to check allowance");
            return false;
        }
        
        // Execute the savings transfer and processing
        return _executeSavingsTransfer(actualUser, context.inputToken, calc.saveAmount);
    }

    // Calculate input savings
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
        
        // The reduced swap amount is what will go through the regular pool swap
        // THIS IS IMPORTANT: The PoolManager will automatically adjust based on the BeforeSwapDelta
        uint256 reducedSwapAmount = inputAmount - saveAmount;
        
        return SavingsCalculation({
            saveAmount: saveAmount,
            reducedSwapAmount: reducedSwapAmount
        });
    }

    function _executeSavingsTransfer(
        address actualUser,
        address token,
        uint256 amount
    ) internal returns (bool) {
        emit SavingsTransferInitiated(actualUser, token, amount);
        
        bool transferSuccess = false;

        // Try to transfer tokens for savings using try/catch
        try IERC20(token).transferFrom(actualUser, address(this), amount) {
            transferSuccess = true;
            
            // Double-check that we received the tokens
            uint256 contractBalance = IERC20(token).balanceOf(address(this));
            emit SavingsTransferSuccess(actualUser, token, amount, contractBalance);
            
            // Apply fee and process savings
            uint256 netAmount = _applyFeeAndProcessSavings(actualUser, token, amount);
            emit NetAmountAfterFee(actualUser, token, netAmount);
            
            // Emit event for tracking user savings update
            uint256 userSavings = storage_.savings(actualUser, token);
            emit UserSavingsUpdated(actualUser, token, userSavings);
            
            return true;
        } catch Error(string memory reason) {
            emit SavingsTransferFailure(actualUser, token, amount, bytes(reason));
            return false;
        } catch (bytes memory reason) {
            emit SavingsTransferFailure(actualUser, token, amount, reason);
            return false;
        }
    }



    // Helper to apply saving limits
    function _applySavingLimits(uint256 saveAmount, uint256 inputAmount) internal pure virtual returns (uint256) {
        if (saveAmount >= inputAmount) {
            return inputAmount / 2; // Save at most half to ensure swap continues
        }
        return saveAmount;
    }

    function processInputSavingsAfterSwap(
        address actualUser,
        SpendSaveStorage.SwapContext memory context
    ) external virtual nonReentrant returns (bool) {
        if (msg.sender != storage_.spendSaveHook()) revert OnlyHook();
        if (context.pendingSaveAmount == 0) return false;
        
        // UPDATED: No need to transfer tokens from the user - we already have them via take()
        emit ProcessInputSavingsAfterSwapCalled(actualUser, context.inputToken, context.pendingSaveAmount);
        
        // Apply fee and process savings
        uint256 processedAmount = _applyFeeAndProcessSavings(
            actualUser, 
            context.inputToken, 
            context.pendingSaveAmount
        );

        // Return true if any amount was processed successfully
        return processedAmount > 0;
    }

    // Helper to apply fee and process savings
    function _applyFeeAndProcessSavings(
        address actualUser,
        address token,
        uint256 amount
    ) internal returns (uint256) {
        // Apply treasury fee
        uint256 amountAfterFee = storage_.calculateAndTransferFee(actualUser, token, amount);

        // UPDATED: We already have the tokens via take(), so no need to transfer them again
        // Just process the savings directly
        try savingsModule.processSavings(actualUser, token, amountAfterFee) {
            emit SavingsProcessedSuccessfully(actualUser, token, amountAfterFee);
        } catch Error(string memory reason) {
            emit SavingsProcessingFailed(actualUser, token, bytes(reason));
            return 0;
        } catch (bytes memory reason) {
            emit SavingsProcessingFailed(actualUser, token, reason);
            return 0;
        }

        return amountAfterFee;
    }

    
    // Update user's saving strategy after swap - optimized to only update when needed
    function updateSavingStrategy(address actualUser, SpendSaveStorage.SwapContext memory context) external override nonReentrant {
        if (msg.sender != address(storage_) && msg.sender != storage_.spendSaveHook()) revert OnlyHook();
        
        // Early return if no auto-increment or no percentage change
        if (!_shouldUpdateStrategy(actualUser, context.currentPercentage)) return;
        
        // Get current strategy
        SpendSaveStorage.SavingStrategy memory strategy = _getUserSavingStrategy(actualUser);
        
        // Update percentage
        strategy.percentage = context.currentPercentage;
        
        // Update the strategy in storage
        _saveUserStrategy(actualUser, strategy);

        emit SavingStrategyUpdated(actualUser, strategy.percentage);
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