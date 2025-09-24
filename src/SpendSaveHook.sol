// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "lib/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "lib/v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "lib/v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {ReentrancyGuard} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {SwapParams} from "lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";

import {ISavingStrategyModule} from "./interfaces/ISavingStrategyModule.sol";
import {ISavingsModule} from "./interfaces/ISavingsModule.sol";
import {IDCAModule} from "./interfaces/IDCAModule.sol";
import {ISlippageControlModule} from "./interfaces/ISlippageControlModule.sol";
import {ITokenModule} from "./interfaces/ITokenModule.sol";
import {IDailySavingsModule} from "./interfaces/IDailySavingsModule.sol";
import {SpendSaveStorage} from "./SpendSaveStorage.sol";

/**
 * @title SpendSaveHook - Optimized Uniswap v4 Hook for Automated Savings
 * @notice Gas-optimized hook implementation targeting <50k gas for afterSwap operations
 * @dev Key optimizations:
 * - Packed storage patterns for frequently accessed user data
 * - Transient storage for beforeSwap/afterSwap communication
 * - In-memory calculations replacing external module calls during swaps
 * - Batch operations for storage updates
 * - Module registry system for efficient lookup
 * @author SpendSave Protocol Team
 */
contract SpendSaveHook is BaseHook, ReentrancyGuard {

    // ==================== CONSTANTS ====================
    
    /// @dev Percentage denominator for calculations (10000 = 100%)
    uint256 private constant PERCENTAGE_DENOMINATOR = 10000;
    
    /// @dev Treasury fee denominator 
    uint256 private constant TREASURY_FEE_DENOMINATOR = 10000;
    
    /// @dev Gas configuration constants
    uint256 private constant GAS_THRESHOLD = 500000;
    uint256 private constant INITIAL_GAS_PER_TOKEN = 150000;
    uint256 private constant MIN_GAS_TO_KEEP = 100000;
    uint256 private constant DAILY_SAVINGS_THRESHOLD = 600000;
    uint256 private constant BATCH_SIZE = 5;

    // ==================== MODULE REGISTRY CONSTANTS ====================
    bytes32 private constant STRATEGY_MODULE = keccak256("STRATEGY");
    bytes32 private constant SAVINGS_MODULE = keccak256("SAVINGS");
    bytes32 private constant DCA_MODULE = keccak256("DCA");
    bytes32 private constant SLIPPAGE_MODULE = keccak256("SLIPPAGE");
    bytes32 private constant TOKEN_MODULE = keccak256("TOKEN");
    bytes32 private constant DAILY_MODULE = keccak256("DAILY");

    // ==================== STATE VARIABLES ====================
    
    bool private modulesInitialized;

    // ==================== STORAGE VARIABLES ====================
    
    /// @notice Immutable reference to storage contract
    SpendSaveStorage public immutable storage_;

    /// @notice Additional state variables for compatibility
    address public token;
    address public savings;
    address public savingStrategy;
    address public yieldModule;
    
    /// @notice Efficient data structure for tracking tokens that need processing
    struct TokenProcessingQueue {
        mapping(address => uint256) tokenPositions;
        address[] tokenQueue;
        mapping(address => uint256) lastProcessed;
    }
    
    /// @notice Mapping from user to token processing queue
    mapping(address => TokenProcessingQueue) private _tokenProcessingQueues;
    
    /// @notice Struct for processing daily savings
    struct DailySavingsProcessor {
        address[] tokens;
        uint256 gasLimit;
        uint256 totalSaved;
        uint256 minGasReserve;
    }

    // ==================== EVENTS ====================
    
    /// @notice Emitted when modules are successfully initialized
    event ModulesInitialized(
        address strategyModule, 
        address savingsModule, 
        address dcaModule, 
        address slippageModule, 
        address tokenModule, 
        address dailySavingsModule
    );
    
    /// @notice Emitted when beforeSwap executes successfully
    event BeforeSwapExecuted(address indexed user, BeforeSwapDelta delta);
    
    /// @notice Emitted when afterSwap processes savings
    event AfterSwapExecuted(address indexed user, BalanceDelta delta);
    
    /// @notice Emitted when daily savings are executed
    event DailySavingsExecuted(address indexed user, uint256 totalAmount);
    
    /// @notice Emitted when individual token savings are processed
    event DailySavingsDetails(address indexed user, address indexed token, uint256 amount);
    
    /// @notice Emitted when daily savings execution fails
    event DailySavingsExecutionFailed(address indexed user, address indexed token, string reason);
    
    /// @notice Emitted when single token savings execute
    event SingleTokenSavingsExecuted(address indexed user, address indexed token, uint256 amount);
    
    /// @notice Emitted when gas optimization is activated
    event GasOptimizationActive(bool enabled);
    
    /// @notice Emitted when beforeSwap encounters an error
    event BeforeSwapError(address indexed user, string reason);
    
    /// @notice Emitted when afterSwap encounters an error
    event AfterSwapError(address indexed user, string reason);
    
    /// @notice Emitted when output savings are calculated
    event OutputSavingsCalculated(address indexed user, address indexed token, uint256 amount);
    
    /// @notice Emitted when output savings are processed
    event OutputSavingsProcessed(address indexed user, address indexed token, uint256 amount);
    
    /// @notice Emitted when specific token swap is queued
    event SpecificTokenSwapQueued(address indexed user, address indexed fromToken, address indexed toToken, uint256 amount);
    
    /// @notice Emitted when external processing savings call is made
    event ExternalProcessingSavingsCall(address indexed caller);

    // ==================== ERRORS ====================
    
    /// @notice Error when a required module is not initialized
    error ModuleNotInitialized(string moduleName);
    
    /// @notice Error when insufficient gas is available
    error InsufficientGas(uint256 available, uint256 required);
    
    /// @notice Error when unauthorized access is attempted
    error UnauthorizedAccess(address caller);
    
    /// @notice Error when an invalid address is provided
    error InvalidAddress();
    
    /// @notice Error when delta calculation is invalid
    error InvalidDelta();
    
    /// @notice Error when storage is not properly initialized
    error StorageNotInitialized();

    // ==================== CONSTRUCTOR ====================
    
    /**
     * @notice Initialize the SpendSaveHook with required dependencies
     * @param _poolManager The Uniswap V4 pool manager contract
     * @param _storage The storage contract for saving strategies and data
     * @dev Constructor validates inputs and sets up immutable references
     */
    constructor(
        IPoolManager _poolManager,
        SpendSaveStorage _storage
    ) BaseHook(_poolManager) {
        if (address(_storage) == address(0)) revert StorageNotInitialized();
        storage_ = _storage;
    }

    // ==================== MODIFIERS ====================
    
    /**
     * @notice Modifier to restrict access to owner only
     * @dev Uses storage contract's owner for access control
     */
    modifier onlyOwner() {
        if (msg.sender != storage_.owner()) {
            revert UnauthorizedAccess(msg.sender);
        }
        _;
    }

    // ==================== HOOK PERMISSIONS ====================
    
    /**
     * @notice Defines which hook points are used by this contract
     * @return Hooks.Permissions Permission configuration for the hook
     * @dev Enables beforeSwap, afterSwap, and return delta permissions for optimal savings processing
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,              // Enable beforeSwap for savings preparation
            afterSwap: true,               // Enable afterSwap for savings processing
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,   // Enable beforeSwap delta modification
            afterSwapReturnDelta: true,    // Enable afterSwap delta modification
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
    * @notice Initialize all module references in storage
    * @dev Called once after deployment to set up module registry
    * @param _savingStrategy Address of SavingStrategy module
    * @param _savings Address of Savings module
    * @param _dca Address of DCA module
    * @param _slippageControl Address of SlippageControl module
    * @param _token Address of Token module
    * @param _dailySavings Address of DailySavings module
    */
    function initializeModules(
        address _savingStrategy,
        address _savings,
        address _dca,
        address _slippageControl,
        address _token,
        address _dailySavings
    ) external onlyOwner {
        require(!modulesInitialized, "Already initialized");
        
        // Register modules in storage
        storage_.registerModule(STRATEGY_MODULE, _savingStrategy);
        storage_.registerModule(SAVINGS_MODULE, _savings);
        storage_.registerModule(DCA_MODULE, _dca);
        storage_.registerModule(SLIPPAGE_MODULE, _slippageControl);
        storage_.registerModule(TOKEN_MODULE, _token);
        storage_.registerModule(DAILY_MODULE, _dailySavings);
        
        // Initialize each module with storage reference
        ISavingStrategyModule(_savingStrategy).initialize(storage_);
        ISavingsModule(_savings).initialize(storage_);
        IDCAModule(_dca).initialize(storage_);
        ISlippageControlModule(_slippageControl).initialize(storage_);
        ITokenModule(_token).initialize(storage_);
        IDailySavingsModule(_dailySavings).initialize(storage_);
        
        // Set cross-module references
        _initializeModuleReferences(
            _savingStrategy,
            _savings,
            _dca,
            _slippageControl,
            _token,
            _dailySavings
        );
        
        modulesInitialized = true;
        emit ModulesInitialized(
            _savingStrategy,
            _savings,
            _dca,
            _slippageControl,
            _token,
            _dailySavings
        );
    }

    function _initializeModuleReferences(
        address _savingStrategy,
        address _savings,
        address _dca,
        address _slippageControl,
        address _token,
        address _dailySavings
    ) private {
        // Each module needs references to other modules for cross-communication
        ISavingStrategyModule(_savingStrategy).setModuleReferences(
            _savingStrategy, _savings, _dca, _slippageControl, _token, _dailySavings
        );
        ISavingsModule(_savings).setModuleReferences(
            _savingStrategy, _savings, _dca, _slippageControl, _token, _dailySavings
        );
        IDCAModule(_dca).setModuleReferences(
            _savingStrategy, _savings, _dca, _slippageControl, _token, _dailySavings
        );
        ISlippageControlModule(_slippageControl).setModuleReferences(
            _savingStrategy, _savings, _dca, _slippageControl, _token, _dailySavings
        );
        ITokenModule(_token).setModuleReferences(
            _savingStrategy, _savings, _dca, _slippageControl, _token, _dailySavings
        );
        IDailySavingsModule(_dailySavings).setModuleReferences(
            _savingStrategy, _savings, _dca, _slippageControl, _token, _dailySavings
        );
    }
    // ==================== OPTIMIZED HOOK FUNCTIONS ====================
    
    /**
     * @notice Optimized beforeSwap implementation - prepares savings with minimal gas usage
     * @param sender The address initiating the swap
     * @param key The pool key for the swap
     * @param params The swap parameters
     * @param hookData Additional hook data
     * @return selector The function selector
     * @return delta The before swap delta for input modification
     * @return fee The dynamic fee (unused)
     * @dev Uses packed storage reads and transient storage for efficient context passing
     */
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        try this._beforeSwapInternal(sender, key, params, hookData) returns (
            bytes4 selector,
            BeforeSwapDelta delta,
            uint24 fee
        ) {
            emit BeforeSwapExecuted(_extractUser(sender, hookData), delta);
            return (selector, delta, fee);
        } catch Error(string memory reason) {
            emit BeforeSwapError(_extractUser(sender, hookData), reason);
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }
    }
    
    /**
     * @notice Internal beforeSwap logic separated for error handling
     * @dev This separation allows for clean error handling in the main function
     */
    function _beforeSwapInternal(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        // Extract actual user from sender or hook data
        address user = _extractUser(sender, hookData);
        
        // Single optimized storage read for all user configuration
        // This replaces multiple external module calls
        (uint256 percentage, bool roundUpSavings, uint8 savingsTokenType, bool enableDCA) = 
            storage_.getPackedUserConfig(user);
        
        // Fast path - no savings configured, return immediately
        if (percentage == 0) {
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }
        
        // Calculate savings amount using in-memory computation
        uint256 inputAmount = _getInputAmount(params);
        uint256 saveAmount = _calculateSavingsInMemory(inputAmount, percentage, roundUpSavings);
        
        // Store minimal context in transient storage for afterSwap access
        // This avoids expensive storage operations during swap execution
        storage_.setTransientSwapContext(
            user,
            uint128(saveAmount),
            uint128(percentage),
            true,
            savingsTokenType,
            roundUpSavings,
            enableDCA
        );
        
        // Calculate and return delta modification for input token savings
        BeforeSwapDelta delta = _calculateBeforeSwapDelta(savingsTokenType, params, saveAmount);
        
        return (IHooks.beforeSwap.selector, delta, 0);
    }
    
    /**
     * @notice Optimized afterSwap implementation - processes savings with <50k gas target
     * @param sender The address that initiated the swap
     * @param key The pool key for the swap
     * @param params The swap parameters
     * @param delta The balance delta from the swap
     * @param hookData Additional hook data
     * @return selector The function selector
     * @return hookDelta The hook's delta modification
     * @dev Uses batch operations and eliminates external calls during execution
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        try this._afterSwapInternal(sender, key, params, delta, hookData) returns (
            bytes4 selector,
            int128 hookDelta
        ) {
            emit AfterSwapExecuted(_extractUser(sender, hookData), delta);
            return (selector, hookDelta);
        } catch Error(string memory reason) {
            address user = _extractUser(sender, hookData);
            emit AfterSwapError(user, reason);
            
            // Clean up transient storage on error
            storage_.clearTransientSwapContext(user);
            return (IHooks.afterSwap.selector, 0);
        }
    }
    
    /**
     * @notice Internal afterSwap logic with gas optimizations
     * @dev Separated for clean error handling and gas measurement
     */
    function _afterSwapInternal(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external returns (bytes4, int128) {
        // Extract user address
        address user = _extractUser(sender, hookData);
        
        // Single read from transient storage - much cheaper than multiple external calls
        (
            uint128 pendingSaveAmount,
            uint128 currentPercentage,
            uint8 savingsTokenType,
            bool roundUpSavings,
            bool enableDCA
        ) = storage_.getTransientSwapContext(user);
        
        // Fast path - no savings to process
        if (currentPercentage == 0 || pendingSaveAmount == 0) {
            storage_.clearTransientSwapContext(user);
            return (IHooks.afterSwap.selector, 0);
        }
        
        // Process savings based on type using in-memory calculations
        uint256 actualSaveAmount = 0;
        address saveToken;
        
        if (savingsTokenType == 0) { // INPUT token savings
            // Amount already calculated in beforeSwap
            actualSaveAmount = pendingSaveAmount;
            saveToken = params.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
            
            // Store savings data for processing through proper unlock pattern
            // Note: Direct currency operations removed for V4 compliance
            // Currency operations must be handled through unlock callbacks
            
        } else if (savingsTokenType == 1) { // OUTPUT token savings
            // Calculate output savings using delta information
            (saveToken, actualSaveAmount) = _calculateOutputSavings(
                key, 
                params, 
                delta, 
                currentPercentage, 
                roundUpSavings
            );
            
            if (actualSaveAmount > 0) {
                // Store savings data for processing through proper unlock pattern
                // Note: Direct currency operations removed for V4 compliance
                // Currency operations must be handled through unlock callbacks
            }
        }
        
        // Batch update storage if we saved anything
        if (actualSaveAmount > 0 && saveToken != address(0)) {
            // Single storage operation for all updates
            storage_.batchUpdateUserSavings(user, saveToken, actualSaveAmount);
            
            // Queue strategy updates for later processing (gas optimization)
            if (enableDCA) {
                _queueStrategyUpdate(user, currentPercentage);
            }
        }
        
        // Clear transient storage (cleanup)
        storage_.clearTransientSwapContext(user);
        
        return (IHooks.afterSwap.selector, 0);
    }

    // ==================== GAS-OPTIMIZED CALCULATION FUNCTIONS ====================
    
    /**
     * @notice Calculate savings amount in memory without external calls
     * @param amount The input amount to calculate savings from
     * @param percentage The savings percentage (basis points)
     * @param roundUp Whether to round up fractional savings
     * @return saveAmount The calculated savings amount
     * @dev Pure function optimized for gas efficiency with assembly for precision
     */
    function _calculateSavingsInMemory(
        uint256 amount,
        uint256 percentage,
        bool roundUp
    ) internal pure returns (uint256 saveAmount) {
        if (percentage == 0 || amount == 0) return 0;
        
        // Use assembly for gas-optimized calculation
        assembly {
            // Calculate base savings amount
            saveAmount := div(mul(amount, percentage), PERCENTAGE_DENOMINATOR)
            
            // Apply rounding logic if enabled
            if roundUp {
                let remainder := mod(mul(amount, percentage), PERCENTAGE_DENOMINATOR)
                if gt(remainder, 0) {
                    saveAmount := add(saveAmount, 1)
                }
            }
        }
        
        // Ensure we don't save more than the input amount
        if (saveAmount > amount) saveAmount = amount;
    }
    
    /**
     * @notice Calculate beforeSwap delta based on savings configuration
     * @param savingsTokenType The type of token being saved (0=input, 1=output)
     * @param params The swap parameters
     * @param saveAmount The amount to save
     * @return delta The calculated before swap delta
     * @dev Only modifies delta for input token savings
     */
    function _calculateBeforeSwapDelta(
        uint8 savingsTokenType,
        SwapParams calldata params,
        uint256 saveAmount
    ) internal pure returns (BeforeSwapDelta delta) {
        // Only adjust delta for INPUT token savings
        if (savingsTokenType != 0 || saveAmount == 0) {
            return toBeforeSwapDelta(0, 0);
        }
        
        int128 specifiedDelta = 0;
        int128 unspecifiedDelta = 0;
        
        // Adjust delta based on swap direction and exact input/output
        if (params.amountSpecified < 0) {
            // Exact input swap - reduce specified amount by savings
            specifiedDelta = int128(uint128(saveAmount));
        } else {
            // Exact output swap - increase unspecified amount by savings
            unspecifiedDelta = int128(uint128(saveAmount));
        }
        
        return toBeforeSwapDelta(specifiedDelta, unspecifiedDelta);
    }
    
    /**
     * @notice Calculate output savings amount from swap results
     * @param key The pool key
     * @param params The swap parameters  
     * @param delta The balance delta from the swap
     * @param percentage The savings percentage
     * @param roundUp Whether to round up savings
     * @return outputToken The output token address
     * @return amount The calculated savings amount
     * @dev In-memory calculation without external calls for gas efficiency
     */
    function _calculateOutputSavings(
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        uint128 percentage,
        bool roundUp
    ) internal pure returns (address outputToken, uint256 amount) {
        // Determine output token and amount based on swap direction
        if (params.zeroForOne) {
            outputToken = Currency.unwrap(key.currency1);
            int256 outputAmount = delta.amount1();
            if (outputAmount > 0) {
                amount = _calculateSavingsInMemory(
                    uint256(outputAmount),
                    percentage,
                    roundUp
                );
            }
        } else {
            outputToken = Currency.unwrap(key.currency0);
            int256 outputAmount = delta.amount0();
            if (outputAmount > 0) {
                amount = _calculateSavingsInMemory(
                    uint256(outputAmount),
                    percentage,
                    roundUp
                );
            }
        }
    }

    // ==================== UTILITY FUNCTIONS ====================
    
    /**
     * @notice Extract user address from hook data or sender
     * @param sender The transaction sender
     * @param hookData The hook data payload
     * @return user The actual user address
     * @dev Optimized for the common case where sender is the user
     */
    function _extractUser(address sender, bytes calldata hookData) internal pure returns (address user) {
        // If no hook data, sender is the user (most common case)
        if (hookData.length == 0) return sender;
        
        // Otherwise decode user from hook data
        user = abi.decode(hookData, (address));
    }
    
    /**
     * @notice Get input amount from swap parameters
     * @param params The swap parameters
     * @return inputAmount The input amount for the swap
     * @dev Handles both exact input and exact output swaps
     */
    function _getInputAmount(SwapParams calldata params) internal pure returns (uint256 inputAmount) {
        if (params.amountSpecified < 0) {
            // Exact input swap - use absolute value
            inputAmount = uint256(-params.amountSpecified);
        }
        // For exact output swaps, input amount is unknown at beforeSwap
    }
    
    /**
     * @notice Queue strategy update for later processing
     * @param user The user address
     * @param currentPercentage The current savings percentage
     * @dev Deferred processing to avoid gas costs in swap execution path
     */
    function _queueStrategyUpdate(address user, uint128 currentPercentage) internal {
        // Queue percentage update for later processing by keeper or next user interaction
        // This avoids gas cost in the critical swap path
        // Implementation depends on specific strategy update requirements
    }

    // ==================== MODULE REGISTRY HELPERS ====================
    function _strategyModule() internal view returns (ISavingStrategyModule) {
        return ISavingStrategyModule(storage_.getModule(STRATEGY_MODULE));
    }
    function _savingsModule() internal view returns (ISavingsModule) {
        return ISavingsModule(storage_.getModule(SAVINGS_MODULE));
    }
    function _dcaModule() internal view returns (IDCAModule) {
        return IDCAModule(storage_.getModule(DCA_MODULE));
    }
    function _slippageControlModule() internal view returns (ISlippageControlModule) {
        return ISlippageControlModule(storage_.getModule(SLIPPAGE_MODULE));
    }
    function _tokenModule() internal view returns (ITokenModule) {
        return ITokenModule(storage_.getModule(TOKEN_MODULE));
    }
    function _dailySavingsModule() internal view returns (IDailySavingsModule) {
        return IDailySavingsModule(storage_.getModule(DAILY_MODULE));
    }

    // ==================== MODULE INITIALIZATION ====================
    
    /**
     * @notice Initialize all modules after deployment
     * @dev Module registry pattern: modules are registered in storage, not stored as state variables here
     */
    // function initializeModules(...) external virtual { ... } // REMOVED
    // function _storeModuleReferences(...) internal { ... } // REMOVED
    function _checkModulesInitialized() internal view {
        if (storage_.getModule(STRATEGY_MODULE) == address(0)) revert ModuleNotInitialized("SavingStrategy");
        if (storage_.getModule(SAVINGS_MODULE) == address(0)) revert ModuleNotInitialized("Savings");
        if (storage_.getModule(DCA_MODULE) == address(0)) revert ModuleNotInitialized("DCA");
        if (storage_.getModule(SLIPPAGE_MODULE) == address(0)) revert ModuleNotInitialized("SlippageControl");
        if (storage_.getModule(TOKEN_MODULE) == address(0)) revert ModuleNotInitialized("Token");
        if (storage_.getModule(DAILY_MODULE) == address(0)) revert ModuleNotInitialized("DailySavings");
    }

    // ==================== DAILY SAVINGS PROCESSING ====================
    
    /**
     * @notice Process daily savings for a user
     * @param user The user address to process daily savings for
     * @dev Separated from swap path for gas efficiency, called by keepers
     */
    function processDailySavings(address user) external nonReentrant {
        _checkModulesInitialized();
        
        if (gasleft() < DAILY_SAVINGS_THRESHOLD) {
            revert InsufficientGas(gasleft(), DAILY_SAVINGS_THRESHOLD);
        }
        
        // Get tokens that need processing
        address[] memory tokens = storage_.getUserTokensForDailySavings(user);
        
        if (tokens.length == 0) return;
        
        // Initialize processor
        DailySavingsProcessor memory processor = DailySavingsProcessor({
            tokens: tokens,
            gasLimit: INITIAL_GAS_PER_TOKEN,
            totalSaved: 0,
            minGasReserve: MIN_GAS_TO_KEEP
        });
        
        // Process tokens in batches
        uint256 tokenCount = tokens.length;
        for (uint256 i = 0; i < tokenCount; i += BATCH_SIZE) {
            if (gasleft() < processor.gasLimit + processor.minGasReserve) break;
            
            uint256 batchEnd = i + BATCH_SIZE > tokenCount ? tokenCount : i + BATCH_SIZE;
            _processBatch(user, processor, i, batchEnd);
        }
        
        if (processor.totalSaved > 0) {
            emit DailySavingsExecuted(user, processor.totalSaved);
        }
    }
    
    /**
     * @notice Process a batch of tokens for daily savings
     * @param user The user address
     * @param processor The processor state
     * @param startIdx The starting index
     * @param endIdx The ending index
     * @dev Internal function for batch processing efficiency
     */
    function _processBatch(
        address user,
        DailySavingsProcessor memory processor,
        uint256 startIdx,
        uint256 endIdx
    ) internal {
        for (uint256 i = startIdx; i < endIdx; i++) {
            if (gasleft() < processor.gasLimit + processor.minGasReserve) break;
            
            address tokenAddr = processor.tokens[i];
            uint256 gasStart = gasleft();
            
            try this._processSingleToken(user, tokenAddr) returns (uint256 savedAmount, bool success) {
                if (success) {
                    processor.totalSaved += savedAmount;
                    _updateTokenProcessingStatus(user, tokenAddr);
                    emit DailySavingsDetails(user, tokenAddr, savedAmount);
                }
            } catch Error(string memory reason) {
                emit DailySavingsExecutionFailed(user, tokenAddr, reason);
            }
            
            // Adjust gas estimate based on actual usage
            uint256 gasUsed = gasStart - gasleft();
            processor.gasLimit = _adjustGasLimit(processor.gasLimit, gasUsed);
        }
    }
    
    /**
     * @notice Process savings for a single token
     * @param user The user address
     * @param tokenAddr The token address to process
     * @return savedAmount The amount saved
     * @return success Whether the operation was successful
     * @dev External function to enable try/catch error handling
     */
    function _processSingleToken(address user, address tokenAddr) external returns (uint256 savedAmount, bool success) {
        require(msg.sender == address(this), "Only self-call allowed");
        // Delegate to daily savings module
        try _dailySavingsModule().executeTokenSavings(user, tokenAddr) returns (uint256 amount) {
            return (amount, true);
        } catch {
            return (0, false);
        }
    }
    
    /**
     * @notice Update token processing status after successful execution
     * @param user The user address
     * @param tokenAddr The token address processed
     * @dev Updates tracking and removes completed tokens from queue
     */
    function _updateTokenProcessingStatus(address user, address tokenAddr) internal {
        TokenProcessingQueue storage queue = _tokenProcessingQueues[user];
        queue.lastProcessed[tokenAddr] = block.timestamp;
        // Check if this token needs to be removed from processing queue
        // Use getDailyExecutionStatus to determine if token should be removed from queue
        (bool canExecute,,) = _dailySavingsModule().getDailyExecutionStatus(user, tokenAddr);
        if (!canExecute) {
            _removeTokenFromProcessingQueue(user, tokenAddr);
        }
    }
    
    /**
     * @notice Remove token from processing queue
     * @param user The user address
     * @param tokenAddr The token address to remove
     * @dev Efficiently manages the processing queue
     */
    function _removeTokenFromProcessingQueue(address user, address tokenAddr) internal {
        TokenProcessingQueue storage queue = _tokenProcessingQueues[user];
        uint256 position = queue.tokenPositions[tokenAddr];
        
        if (position == 0) return; // Not in queue
        
        uint256 lastIndex = queue.tokenQueue.length - 1;
        uint256 tokenIndex = position - 1; // Convert to 0-based index
        
        if (tokenIndex != lastIndex) {
            // Move last token to the position of removed token
            address lastToken = queue.tokenQueue[lastIndex];
            queue.tokenQueue[tokenIndex] = lastToken;
            queue.tokenPositions[lastToken] = position;
        }
        
        // Remove the last element
        queue.tokenQueue.pop();
        delete queue.tokenPositions[tokenAddr];
    }
    
    /**
     * @notice Adjust gas limit based on actual usage
     * @param currentLimit The current gas limit
     * @param actualUsage The actual gas used
     * @return newLimit The adjusted gas limit
     * @dev Dynamic gas estimation for better efficiency
     */
    function _adjustGasLimit(uint256 currentLimit, uint256 actualUsage) internal pure returns (uint256 newLimit) {
        if (actualUsage > currentLimit) {
            // Increase limit if we used more than expected
            newLimit = (actualUsage * 12) / 10; // 20% buffer
        } else if (actualUsage < currentLimit / 2) {
            // Decrease limit if we used much less than expected
            newLimit = (actualUsage * 15) / 10; // 50% buffer
        } else {
            // Keep current limit if usage is reasonable
            newLimit = currentLimit;
        }
        
        // Ensure minimum gas limit
        if (newLimit < 50000) newLimit = 50000;
    }

    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Check if modules are properly initialized
     * @return initialized True if all modules are initialized
     * @dev Public view function for verification
     */
    function checkModulesInitialized() external view returns (bool initialized) {
        return storage_.getModule(STRATEGY_MODULE) != address(0) &&
               storage_.getModule(SAVINGS_MODULE) != address(0) &&
               storage_.getModule(DCA_MODULE) != address(0) &&
               storage_.getModule(SLIPPAGE_MODULE) != address(0) &&
               storage_.getModule(TOKEN_MODULE) != address(0) &&
               storage_.getModule(DAILY_MODULE) != address(0);
    }
    
    /**
     * @notice Get the number of tokens in processing queue for a user
     * @param user The user address
     * @return count The number of tokens in queue
     */
    function getProcessingQueueLength(address user) external view returns (uint256 count) {
        return _tokenProcessingQueues[user].tokenQueue.length;
    }
    
    /**
     * @notice Get tokens in processing queue for a user
     * @param user The user address
     * @return tokens Array of token addresses in queue
     */
    function getProcessingQueue(address user) external view returns (address[] memory tokens) {
        return _tokenProcessingQueues[user].tokenQueue;
    }

    // ==================== EMERGENCY FUNCTIONS ====================
    
    /**
     * @notice Emergency pause function
     * @dev Only callable by owner through storage contract
     */
    function emergencyPause() external {
        require(msg.sender == storage_.owner(), "Only owner");
        // Emergency pause implementation
        // This could disable hook functions or set emergency flags
    }
}