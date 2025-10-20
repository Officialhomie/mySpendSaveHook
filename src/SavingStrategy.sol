// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IERC20} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "lib/v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";

import {SpendSaveStorage} from "./SpendSaveStorage.sol";
import {ISavingStrategyModule} from "./interfaces/ISavingStrategyModule.sol";
import {ISavingsModule} from "./interfaces/ISavingsModule.sol";

/**
 * @title SavingStrategy - Optimized User Savings Strategy Management
 * @notice Handles user saving strategies with gas-optimized storage patterns and comprehensive functionality
 * @dev Updated to leverage packed storage while maintaining full feature compatibility
 * 
 * Key Optimizations:
 * - Uses packed storage for frequently accessed data to minimize gas costs
 * - Delegates heavy computation to the optimized hook for swap execution
 * - Maintains comprehensive event emission for frontend integration
 * - Preserves all existing access control and validation patterns
 * 
 * @author SpendSave Protocol Team
 */
contract SavingStrategy is ISavingStrategyModule, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // ==================== CONSTANTS ====================
    
    /// @dev Percentage denominator for basis point calculations (10000 = 100%)
    uint256 private constant PERCENTAGE_DENOMINATOR = 10000;
    
    /// @dev Maximum allowable percentage (100%)
    uint256 private constant MAX_PERCENTAGE = 10000;
    
    /// @dev Maximum value for uint16 (validation boundary)
    uint16 private constant MAX_UINT16 = 65535;

    // ==================== STATE VARIABLES ====================
    
    /// @notice Reference to the centralized storage contract
    SpendSaveStorage public storage_;
    
    /// @notice Reference to the savings module for cross-module operations
    ISavingsModule public savingsModule;
    
    // Standardized module references
    address internal _savingStrategyModule;
    address internal _savingsModule;
    address internal _dcaModule;
    address internal _slippageModule;
    address internal _tokenModule;
    address internal _dailySavingsModule;

    // ==================== COMPREHENSIVE EVENT SYSTEM ====================
    
    /// @notice Emitted when a user's saving strategy is configured
    event SavingStrategySet(
        address indexed user, 
        uint256 percentage, 
        uint256 autoIncrement, 
        uint256 maxPercentage, 
        SpendSaveStorage.SavingsTokenType tokenType
    );
    
    /// @notice Emitted when a savings goal is set for a user
    event GoalSet(address indexed user, address indexed token, uint256 amount);
    
    /// @notice Emitted when strategy is updated during swap execution
    event StrategyUpdated(address indexed user, uint256 newPercentage);
    
    /// @notice Emitted when module is successfully initialized
    event ModuleInitialized(address indexed storageAddress);
    
    /// @notice Emitted when module references are configured
    event ModuleReferencesSet(address indexed savingsModule);
    
    /// @notice Emitted when swap prepared is completed
    event SwapPrepared(address indexed user, uint256 currentSavePercentage, SpendSaveStorage.SavingsTokenType tokenType);
    
    /// @notice Emitted when specific savings token is set
    event SpecificSavingsTokenSet(address indexed user, address indexed token);
    
    /// @notice Emitted when savings strategy auto-increment is applied
    event SavingStrategyUpdated(address indexed user, uint256 newPercentage);
    
    /// @notice Emitted when treasury fee is collected
    event TreasuryFeeCollected(address indexed user, address indexed token, uint256 fee);
    
    /// @notice Emitted when savings processing fails
    event FailedToApplySavings(address user, string reason);
    
    /// @notice Emitted when input token savings processing begins
    event ProcessingInputTokenSavings(address indexed actualUser, address indexed token, uint256 amount);
    
    /// @notice Emitted when input token savings are skipped
    event InputTokenSavingsSkipped(address indexed actualUser, string reason);
    
    /// @notice Emitted when savings amount is calculated
    event SavingsCalculated(address indexed actualUser, uint256 saveAmount, uint256 reducedSwapAmount);
    
    /// @notice Emitted when user balance is checked
    event UserBalanceChecked(address indexed actualUser, address indexed token, uint256 balance);
    
    /// @notice Emitted when user has insufficient balance
    event InsufficientBalance(address indexed actualUser, address indexed token, uint256 required, uint256 available);
    
    /// @notice Emitted when allowance is checked
    event AllowanceChecked(address indexed actualUser, address indexed token, uint256 allowance);
    
    /// @notice Emitted when user has insufficient allowance
    event InsufficientAllowance(address indexed actualUser, address indexed token, uint256 required, uint256 available);
    
    /// @notice Emitted with savings transfer status
    event SavingsTransferStatus(address indexed actualUser, address indexed token, bool success);
    
    /// @notice Emitted when savings transfer is initiated
    event SavingsTransferInitiated(address indexed actualUser, address indexed token, uint256 amount);
    
    /// @notice Emitted when savings transfer succeeds
    event SavingsTransferSuccess(address indexed actualUser, address indexed token, uint256 amount, uint256 contractBalance);
    
    /// @notice Emitted when savings transfer fails
    event SavingsTransferFailure(address indexed actualUser, address indexed token, uint256 amount, bytes reason);
    
    /// @notice Emitted when input token is successfully saved
    event InputTokenSaved(address indexed user, address indexed token, uint256 savedAmount, uint256 remainingSwapAmount);
    
    /// @notice Emitted when afterSwap processing is called
    event ProcessInputSavingsAfterSwapCalled(address indexed actualUser, address indexed inputToken, uint256 pendingSaveAmount);
    
    /// @notice Emitted when net amount after fee is calculated
    event NetAmountAfterFee(address indexed actualUser, address indexed token, uint256 netAmount);
    
    /// @notice Emitted when user savings are updated
    event UserSavingsUpdated(address indexed actualUser, address indexed token, uint256 newSavings);
    
    /// @notice Emitted when fee is applied to savings
    event FeeApplied(address indexed actualUser, address indexed token, uint256 feeAmount);
    
    /// @notice Emitted when savings processing fails
    event SavingsProcessingFailed(address indexed actualUser, address indexed token, bytes reason);
    
    /// @notice Emitted when savings processing succeeds
    event SavingsProcessedSuccessfully(address indexed actualUser, address indexed token, uint256 amount);

    // ==================== COMPREHENSIVE ERROR SYSTEM ====================
    
    /// @notice Error when percentage exceeds maximum allowed
    error PercentageTooHigh(uint256 provided, uint256 max);
    
    /// @notice Error when max percentage is lower than current percentage
    error MaxPercentageTooLow(uint256 maxPercentage, uint256 percentage);
    
    /// @notice Error when specific token address is invalid
    error InvalidSpecificToken();
    
    /// @notice Error when savings amount exceeds input amount
    error SavingsTooHigh(uint256 saveAmount, uint256 inputAmount);
    
    /// @notice Error when module is already initialized
    error AlreadyInitialized();
    
    /// @notice Error when caller is not authorized for user operations
    error OnlyUserOrHook();
    
    /// @notice Error when caller is not the hook contract
    error OnlyHook();
    
    /// @notice Error when caller is not the owner
    error OnlyOwner();
    
    /// @notice Error when caller is not authorized
    error UnauthorizedCaller();
    
    /// @notice Error when module is not properly initialized
    error ModuleNotInitialized(string moduleName);
    
    /// @notice Error when module is not initialized
    error NotInitialized();
    
    /// @notice Error when percentage value is invalid
    error InvalidPercentage();
    
    /// @notice Error when module address is invalid
    error InvalidModule();

    // ==================== ACCESS CONTROL MODIFIERS ====================
    
    /// @notice Restricts access to authorized users or hook contract
    modifier onlyAuthorized(address user) {
        if (msg.sender != user && 
            msg.sender != address(storage_) && 
            msg.sender != storage_.spendSaveHook()) {
            revert UnauthorizedCaller();
        }
        _;
    }
    
    /// @notice Restricts access to storage contract only
    modifier onlyStorage() {
        if (msg.sender != address(storage_)) revert UnauthorizedCaller();
        _;
    }
    
    /// @notice Restricts access to hook contract only
    modifier onlyHook() {
        if (msg.sender != storage_.spendSaveHook()) revert UnauthorizedCaller();
        _;
    }
    
    /// @notice Ensures module is properly initialized before operation
    modifier onlyInitialized() {
        if (address(storage_) == address(0)) revert NotInitialized();
        _;
    }

    // ==================== CONSTRUCTOR ====================
    
    /**
     * @notice Initialize the SavingStrategy module
     * @dev Constructor is empty since module will be initialized via initialize() function
     */
    constructor() {}

    // ==================== MODULE INITIALIZATION ====================
    
    /**
     * @notice Initialize the module with storage reference
     * @param _storage The SpendSaveStorage contract address
     * @dev Implements the ISpendSaveModule interface for consistent initialization
     */
    function initialize(SpendSaveStorage _storage) external override nonReentrant {
        if (address(storage_) != address(0)) revert AlreadyInitialized();
        if (address(_storage) == address(0)) revert InvalidModule();
        
        storage_ = _storage;
        emit ModuleInitialized(address(_storage));
    }
    
    /**
     * @notice Set references to other modules for cross-module operations (interface-compliant)
     * @param savingStrategyModule Address of the saving strategy module (self-reference)
     * @param newSavingsModule Address of the savings module
     * @param dcaModule Address of the DCA module
     * @param slippageModule Address of the slippage control module
     * @param tokenModule Address of the token module
     * @param dailySavingsModule Address of the daily savings module
     * @dev Only owner can set module references to maintain security
     */
    function setModuleReferences(
        address savingStrategyModule,
        address newSavingsModule,
        address dcaModule,
        address slippageModule,
        address tokenModule,
        address dailySavingsModule
    ) external override nonReentrant {
        if (msg.sender != storage_.owner()) revert OnlyOwner();
        
        _savingStrategyModule = savingStrategyModule;
        _savingsModule = newSavingsModule;
        _dcaModule = dcaModule;
        _slippageModule = slippageModule;
        _tokenModule = tokenModule;
        _dailySavingsModule = dailySavingsModule;
        
        // Set the typed reference for backward compatibility
        if (newSavingsModule != address(0)) {
            savingsModule = ISavingsModule(newSavingsModule);
        }
        
        emit ModuleReferencesSet(address(savingsModule));
    }

    // ==================== CORE STRATEGY MANAGEMENT FUNCTIONS ====================
    
    /**
     * @notice Set comprehensive saving strategy for a user with gas-optimized storage
     * @param user The user address to configure strategy for
     * @param percentage Savings percentage in basis points (0-10000)
     * @param autoIncrement Auto-increment value in basis points (0-10000)
     * @param maxPercentage Maximum percentage cap in basis points (0-10000)
     * @param roundUpSavings Whether to round up fractional savings amounts
     * @param savingsTokenType Type of token to save (INPUT, OUTPUT, or SPECIFIC)
     * @param specificSavingsToken Specific token address (required if tokenType is SPECIFIC)
     * @dev Uses packed storage patterns for gas efficiency while maintaining full validation
     */
    function setSavingStrategy(
        address user,
        uint256 percentage,
        uint256 autoIncrement,
        uint256 maxPercentage,
        bool roundUpSavings,
        SpendSaveStorage.SavingsTokenType savingsTokenType,
        address specificSavingsToken
    ) external override onlyAuthorized(user) onlyInitialized {
        // Comprehensive input validation
        if (percentage > MAX_PERCENTAGE) revert PercentageTooHigh(percentage, MAX_PERCENTAGE);
        if (autoIncrement > MAX_PERCENTAGE) revert PercentageTooHigh(autoIncrement, MAX_PERCENTAGE);
        if (maxPercentage > MAX_PERCENTAGE) revert PercentageTooHigh(maxPercentage, MAX_PERCENTAGE);
        if (maxPercentage > 0 && maxPercentage < percentage) revert MaxPercentageTooLow(maxPercentage, percentage);
        
        // Validate specific token requirements
        if (savingsTokenType == SpendSaveStorage.SavingsTokenType.SPECIFIC) {
            if (specificSavingsToken == address(0)) revert InvalidSpecificToken();
        }
        
        // Convert to uint16 for packed storage (safe after validation)
        uint16 percentage16 = uint16(percentage);
        uint16 autoIncrement16 = uint16(autoIncrement);
        uint16 maxPercentage16 = uint16(maxPercentage);
        
        // Store using gas-optimized packed format
        storage_.setPackedUserConfig(
            user,
            percentage16,
            autoIncrement16,
            maxPercentage16,
            roundUpSavings,
            false, // enableDCA - managed separately by DCA module
            uint8(savingsTokenType)
        );
        
        // Handle specific token storage (using legacy interface for compatibility)
        if (savingsTokenType == SpendSaveStorage.SavingsTokenType.SPECIFIC && specificSavingsToken != address(0)) {
            // Store comprehensive strategy using legacy interface for specific token functionality
            SpendSaveStorage.SavingStrategy memory legacyStrategy = SpendSaveStorage.SavingStrategy({
                percentage: percentage,
                autoIncrement: autoIncrement,
                maxPercentage: maxPercentage,
                goalAmount: 0, // Set separately via setSavingsGoal
                roundUpSavings: roundUpSavings,
                enableDCA: false, // Managed by DCA module
                savingsTokenType: savingsTokenType,
                specificSavingsToken: specificSavingsToken
            });
            
            storage_.setSavingStrategy(user, legacyStrategy);
            emit SpecificSavingsTokenSet(user, specificSavingsToken);
        }
        
        // Emit comprehensive event for frontend integration
        emit SavingStrategySet(user, percentage, autoIncrement, maxPercentage, savingsTokenType);
    }
    
    /**
     * @notice Set savings goal for a user and specific token
     * @param user The user address
     * @param token The target token address
     * @param amount The goal amount to save
     * @dev Enables goal-based savings tracking and completion notifications
     */
    function setSavingsGoal(address user, address token, uint256 amount) external override onlyAuthorized(user) onlyInitialized {
        // Store goal in the storage contract
        // Note: This would require implementation of a setSavingsGoal function in SpendSaveStorage
        // For now, emitting event for frontend tracking
        emit GoalSet(user, token, amount);
    }

    // ==================== SWAP EXECUTION OPTIMIZED FUNCTIONS ====================
    
    /**
     * @notice Process beforeSwap hook logic with gas optimization
     * @param actualUser The actual user performing the swap
     * @param key The pool key for the swap
     * @param params The swap parameters
     * @return delta The before swap delta (now optimized to return zero as calculations moved to hook)
     * @dev Logic moved to SpendSaveHook for gas efficiency, this function maintains interface compatibility
     */
    function beforeSwap(
        address actualUser,
        PoolKey calldata key,
        SwapParams calldata params
    ) external override onlyHook onlyInitialized returns (BeforeSwapDelta) {
        // Get user strategy from optimized packed storage
        (uint256 percentage, bool roundUpSavings, uint8 savingsTokenType, bool enableDCA) = 
            storage_.getPackedUserConfig(actualUser);
        
        // Emit preparation event for tracking
        if (percentage > 0) {
            emit SwapPrepared(actualUser, percentage, SpendSaveStorage.SavingsTokenType(savingsTokenType));
        }
        
        // All calculation logic now handled in SpendSaveHook for gas efficiency
        // Return zero delta as hook handles delta calculation directly
        return toBeforeSwapDelta(0, 0);
    }
    
    /**
     * @notice Update saving strategy based on auto-increment configuration
     * @param user The user address
     * @param context The swap context containing current strategy state
     * @dev Called by hook after successful swap to apply auto-increment logic
     */
    function updateSavingStrategy(address user, SpendSaveStorage.SwapContext memory context) external override onlyHook onlyInitialized {
        if (!context.hasStrategy) {
            emit InputTokenSavingsSkipped(user, "No active strategy");
            return;
        }
        
        // Get current packed configuration for gas-efficient access
        (uint256 currentPercentage, , , ) = storage_.getPackedUserConfig(user);
        
        // Use context data if available, otherwise use current config
        uint256 percentage = context.currentPercentage > 0 ? context.currentPercentage : currentPercentage;
        
        // Get full strategy for auto-increment logic
        SpendSaveStorage.SavingStrategy memory strategy = storage_.getUserSavingStrategy(user);
        
        // Apply auto-increment if configured and not at maximum
        if (strategy.autoIncrement > 0 && percentage < strategy.maxPercentage) {
            uint256 newPercentage = percentage + strategy.autoIncrement;
            
            // Cap at maximum percentage
            if (newPercentage > strategy.maxPercentage) {
                newPercentage = strategy.maxPercentage;
            }
            
            // Update strategy with new percentage while preserving other settings
            storage_.setPackedUserConfig(
                user,
                uint16(newPercentage),
                uint16(strategy.autoIncrement),
                uint16(strategy.maxPercentage),
                strategy.roundUpSavings,
                strategy.enableDCA,
                uint8(strategy.savingsTokenType)
            );
            
            emit SavingStrategyUpdated(user, newPercentage);
        }
    }
    
    /**
     * @notice Process input savings after swap execution
     * @param actualUser The user who performed the swap
     * @param context The swap context containing pending save amount and token details
     * @return success Whether the savings processing was successful
     * @dev Maintains interface compatibility while delegating heavy lifting to optimized hook
     */
    function processInputSavingsAfterSwap(
        address actualUser,
        SpendSaveStorage.SwapContext memory context
    ) external override onlyHook onlyInitialized returns (bool success) {
        emit ProcessInputSavingsAfterSwapCalled(actualUser, context.inputToken, context.pendingSaveAmount);
        
        // Early return if no savings to process
        if (context.pendingSaveAmount == 0) {
            emit InputTokenSavingsSkipped(actualUser, "No pending save amount");
            return true;
        }
        
        // Processing now handled directly in SpendSaveHook for gas efficiency
        // This function maintains compatibility and provides detailed event emission
        if (context.pendingSaveAmount > 0) {
            emit SavingsProcessedSuccessfully(actualUser, context.inputToken, context.pendingSaveAmount);
            return true;
        } else {
            emit SavingsProcessingFailed(actualUser, context.inputToken, "Processing failed");
            return false;
        }
    }

    // ==================== CALCULATION UTILITIES ====================
    
    /**
     * @notice Calculate savings amount with precision and rounding options
     * @param amount The base amount to calculate savings from
     * @param percentage The savings percentage in basis points (0-10000)
     * @param roundUp Whether to round up fractional amounts
     * @return saveAmount The calculated savings amount
     * @dev Pure function for gas-efficient calculations, used by UI and testing
     */
    function calculateSavingsAmount(
        uint256 amount,
        uint256 percentage,
        bool roundUp
    ) external pure override returns (uint256 saveAmount) {
        if (percentage == 0 || amount == 0) return 0;
        
        // Calculate base savings amount
        saveAmount = (amount * percentage) / PERCENTAGE_DENOMINATOR;
        
        // Apply rounding logic if enabled
        if (roundUp && (amount * percentage) % PERCENTAGE_DENOMINATOR > 0) {
            saveAmount += 1;
        }
        
        // Ensure we don't save more than the input amount
        return saveAmount > amount ? amount : saveAmount;
    }

    // ==================== VIEW FUNCTIONS FOR FRONTEND INTEGRATION ====================
    
    /**
     * @notice Get user's complete saving strategy from optimized storage
     * @param user The user address to query
     * @return percentage Current savings percentage in basis points
     * @return autoIncrement Auto-increment value in basis points
     * @return maxPercentage Maximum percentage cap in basis points
     * @return roundUpSavings Whether rounding up is enabled
     * @return savingsTokenType The type of token being saved
     * @dev Optimized to read from packed storage for gas efficiency
     */
    function getUserStrategy(address user) external view returns (
        uint256 percentage,
        uint256 autoIncrement,
        uint256 maxPercentage,
        bool roundUpSavings,
        SpendSaveStorage.SavingsTokenType savingsTokenType
    ) {
        // Try packed storage first for gas efficiency
        (uint256 packedPercentage, bool packedRoundUp, uint8 packedTokenType, ) = 
            storage_.getPackedUserConfig(user);
        
        if (packedPercentage > 0) {
            // Get additional data from legacy storage if needed
            SpendSaveStorage.SavingStrategy memory strategy = storage_.getUserSavingStrategy(user);
            
            return (
                packedPercentage,
                strategy.autoIncrement,
                strategy.maxPercentage,
                packedRoundUp,
                SpendSaveStorage.SavingsTokenType(packedTokenType)
            );
        } else {
            // Fall back to legacy storage for complete compatibility
            SpendSaveStorage.SavingStrategy memory strategy = storage_.getUserSavingStrategy(user);
            return (
                strategy.percentage,
                strategy.autoIncrement,
                strategy.maxPercentage,
                strategy.roundUpSavings,
                strategy.savingsTokenType
            );
        }
    }
    
    /**
     * @notice Get user's savings goal for a specific token
     * @param user The user address
     * @param token The token address
     * @return goalAmount The savings goal amount (0 if not set)
     * @dev Provides goal tracking for frontend display and notifications
     */
    function getUserSavingsGoal(address user, address token) external view returns (uint256 goalAmount) {
        // This would require implementation in SpendSaveStorage
        // For now, return the general goal from the strategy
        SpendSaveStorage.SavingStrategy memory strategy = storage_.getUserSavingStrategy(user);
        return strategy.goalAmount;
    }
    
    /**
     * @notice Check if user has an active saving strategy
     * @param user The user address to check
     * @return hasStrategy True if user has configured a savings strategy
     * @dev Quick check for frontend conditional rendering
     */
    function hasActiveStrategy(address user) external view returns (bool hasStrategy) {
        (uint256 percentage, , , ) = storage_.getPackedUserConfig(user);
        return percentage > 0;
    }
    
    /**
     * @notice Preview savings amount for a given swap without executing
     * @param user The user address
     * @param swapAmount The proposed swap amount
     * @return saveAmount The amount that would be saved
     * @return remainingSwapAmount The amount that would proceed to swap
     * @dev Useful for frontend preview and simulation
     */
    function previewSavings(address user, uint256 swapAmount) external view returns (
        uint256 saveAmount, 
        uint256 remainingSwapAmount
    ) {
        (uint256 percentage, bool roundUpSavings, , ) = storage_.getPackedUserConfig(user);
        
        if (percentage == 0 || swapAmount == 0) {
            return (0, swapAmount);
        }
        
        saveAmount = this.calculateSavingsAmount(swapAmount, percentage, roundUpSavings);
        remainingSwapAmount = swapAmount - saveAmount;
        
        return (saveAmount, remainingSwapAmount);
    }

    // ==================== ADMINISTRATIVE FUNCTIONS ====================
    
    /**
     * @notice Emergency function to disable user's strategy
     * @param user The user address
     * @dev Only callable by owner in emergency situations
     */
    function emergencyDisableStrategy(address user) external {
        if (msg.sender != storage_.owner()) revert OnlyOwner();
        
        // Disable by setting percentage to zero
        storage_.setPackedUserConfig(user, 0, 0, 0, false, false, 0);
        
        emit SavingStrategySet(user, 0, 0, 0, SpendSaveStorage.SavingsTokenType.INPUT);
    }
    
    /**
     * @notice Get module version for compatibility checking
     * @return version The current module version
     * @dev Useful for deployment verification and upgrade management
     */
    function getModuleVersion() external pure returns (string memory version) {
        return "2.0.0-optimized";
    }
}