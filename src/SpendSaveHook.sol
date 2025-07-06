// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "lib/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "lib/v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {IHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {BeforeSwapDelta} from "lib/v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IERC20} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {
    BeforeSwapDelta,
    toBeforeSwapDelta
    } from "lib/v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencySettler} from "lib/v4-periphery/lib/v4-core/test/utils/CurrencySettler.sol";
import {StateLibrary} from "lib/v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";

import "./SpendSaveStorage.sol";
import "./ISavingStrategyModule.sol";
import "./ISavingsModule.sol";
import "./IDCAModule.sol";
import "./ISlippageControlModule.sol";
import "./ITokenModule.sol";
import "./IDailySavingsModule.sol";

/**
 * @title SpendSaveHook - Gas Optimized Implementation
 * @author OneTrueHomie.sol
 * @notice Main contract that implements Uniswap V4 hooks with gas optimizations
 * @dev This contract handles savings strategies, DCA, slippage control and daily savings
 *      with optimized gas usage using packed storage and transient storage
 */
contract SpendSaveHook is BaseHook, ReentrancyGuard {
    using CurrencySettler for Currency;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    // Constants for gas optimization
    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant PACKED_DATA_VERSION = 1;
    
    // Transient storage slots for beforeSwap/afterSwap coordination
    bytes32 private constant SLOT_PENDING_SAVE_AMOUNT = keccak256("SpendSave.pendingSaveAmount");
    bytes32 private constant SLOT_SAVINGS_TOKEN_TYPE = keccak256("SpendSave.savingsTokenType");
    bytes32 private constant SLOT_USER_ADDRESS = keccak256("SpendSave.userAddress");
    bytes32 private constant SLOT_SWAP_CONTEXT = keccak256("SpendSave.swapContext");
    
    // Packed user data structure (single storage slot for gas optimization)
    struct PackedUserData {
        uint128 savingsPercentage;      // Basis points (0-10000)
        uint64 lastUpdateTimestamp;     // Unix timestamp
        uint32 autoIncrement;           // Basis points per period
        uint16 maxPercentage;           // Basis points max
        uint8 savingsTokenType;         // 0=NONE, 1=INPUT, 2=OUTPUT, 3=SPECIFIC
        uint8 roundUpEnabled;           // 0=false, 1=true
        uint8 dcaEnabled;               // 0=false, 1=true
        uint8 dailySavingsEnabled;      // 0=false, 1=true
    }

    /// @notice Storage contract reference
    SpendSaveStorage public immutable storage_;
    
    /// @notice Module references
    ISavingStrategyModule public savingStrategyModule;
    ISavingsModule public savingsModule;
    IDCAModule public dcaModule;
    ISlippageControlModule public slippageControlModule;
    ITokenModule public tokenModule;
    IDailySavingsModule public dailySavingsModule;

    /// @notice Additional state variables
    address public token;
    address public savings;
    address public savingStrategy;
    address public yieldModule;
    
    /// @notice Error definitions
    error ModuleNotInitialized(string moduleName);
    error InsufficientGas(uint256 available, uint256 required);
    error UnauthorizedAccess(address caller);
    error InvalidAddress();
    error InvalidPercentage(uint256 percentage);
    
    /// @notice Events
    event DailySavingsExecuted(address indexed user, uint256 totalAmount);
    event DailySavingsDetails(address indexed user, address indexed token, uint256 amount);
    event DailySavingsExecutionFailed(address indexed user, address indexed token, string reason);
    event SingleTokenSavingsExecuted(address indexed user, address indexed token, uint256 amount);
    event ModulesInitialized(address strategyModule, address savingsModule, address dcaModule, address slippageModule, address tokenModule, address dailySavingsModule);
    event BeforeSwapError(address indexed user, string reason);
    event AfterSwapError(address indexed user, string reason);
    event AfterSwapExecuted(address indexed user, BalanceDelta delta);
    event OutputSavingsCalculated(
        address indexed user, 
        address indexed token, 
        uint256 amount
    );
    event OutputSavingsProcessed(
        address indexed user, 
        address indexed token, 
        uint256 amount
    );
    event SpecificTokenSwapQueued(
        address indexed user, 
        address indexed fromToken, 
        address indexed toToken, 
        uint256 amount
    );
    event ExternalProcessingSavingsCall(address indexed caller);
    event GasOptimizationApplied(uint256 gasUsed);
    event BeforeSwapExecuted(address indexed user, BeforeSwapDelta delta);
    
    /// @notice Gas configuration for daily savings
    uint256 private constant GAS_THRESHOLD = 500000;
    uint256 private constant INITIAL_GAS_PER_TOKEN = 150000;
    uint256 private constant MIN_GAS_TO_KEEP = 100000;
    uint256 private constant DAILY_SAVINGS_THRESHOLD = 600000;
    uint256 private constant BATCH_SIZE = 5;

    /// @notice Struct for processing daily savings
    struct DailySavingsProcessor {
        address[] tokens;
        uint256 gasLimit;
        uint256 totalSaved;
        uint256 minGasReserve;
    }

    /// @notice Efficient data structure for tracking tokens that need processing
    struct TokenProcessingQueue {
        /// @dev Mapping from token address to position in the queue (1-based index, 0 means not in queue)
        mapping(address => uint256) tokenPositions;
        /// @dev Array of tokens in processing queue
        address[] tokenQueue;
        /// @dev Last processing timestamp for each token
        mapping(address => uint256) lastProcessed;
    }
    
    /// @notice Mapping from user to token processing queue
    mapping(address => TokenProcessingQueue) private _tokenProcessingQueues;
    
    /**
     * @notice Contract constructor
     * @param _poolManager The Uniswap V4 pool manager contract
     * @param _storage The storage contract for saving strategies
     */
    constructor(
        IPoolManager _poolManager,
        SpendSaveStorage _storage
    ) BaseHook(_poolManager) {
        if (address(_storage) == address(0)) revert InvalidAddress();
        storage_ = _storage;
    }

    /**
     * @notice Initialize all modules after deployment
     * @param _strategyModule Address of the saving strategy module
     * @param _savingsModule Address of the savings module
     * @param _dcaModule Address of the DCA module
     * @param _slippageModule Address of the slippage control module
     * @param _tokenModule Address of the token module
     * @param _dailySavingsModule Address of the daily savings module
     */
    function initializeModules(
        address _strategyModule,
        address _savingsModule,
        address _dcaModule,
        address _slippageModule,
        address _tokenModule,
        address _dailySavingsModule
    ) external virtual {
        require(msg.sender == storage_.owner(), "Only owner can initialize modules");
        
        // Only cache the references locally inside the hook. Registration in storage must be
        // carried out beforehand by the owner (deployment script) to avoid the onlyOwner
        // restriction inside SpendSaveStorage.
        _storeModuleReferences(
            _strategyModule,
            _savingsModule,
            _dcaModule,
            _slippageModule,
            _tokenModule,
            _dailySavingsModule
        );

        emit ModulesInitialized(
            _strategyModule,
            _savingsModule,
            _dcaModule,
            _slippageModule,
            _tokenModule,
            _dailySavingsModule
        );
    }
    
    // Separate helper to store module references
    function _storeModuleReferences(
        address _strategyModule,
        address _savingsModule,
        address _dcaModule,
        address _slippageModule,
        address _tokenModule,
        address _dailySavingsModule
    ) internal {
        savingStrategyModule = ISavingStrategyModule(_strategyModule);
        savingsModule = ISavingsModule(_savingsModule);
        dcaModule = IDCAModule(_dcaModule);
        slippageControlModule = ISlippageControlModule(_slippageModule);
        tokenModule = ITokenModule(_tokenModule);
        dailySavingsModule = IDailySavingsModule(_dailySavingsModule);
    }
    
    /// @notice Load packed user data from storage (single SLOAD for gas optimization)
    function _loadPackedUserData(address user) internal view returns (PackedUserData memory) {
        bytes32 slot = keccak256(abi.encode(user, "SpendSave.PackedUserData"));
        uint256 packed;
        assembly {
            packed := sload(slot)
        }
        
        return PackedUserData({
            savingsPercentage: uint128(packed),
            lastUpdateTimestamp: uint64(packed >> 128),
            autoIncrement: uint32(packed >> 192),
            maxPercentage: uint16(packed >> 224),
            savingsTokenType: uint8(packed >> 240),
            roundUpEnabled: uint8(packed >> 248),
            dcaEnabled: uint8(packed >> 252),
            dailySavingsEnabled: uint8(packed >> 254)
        });
    }
    
    /// @notice Save packed user data to storage (single SSTORE for gas optimization)
    function _savePackedUserData(address user, PackedUserData memory data) internal {
        bytes32 slot = keccak256(abi.encode(user, "SpendSave.PackedUserData"));
        uint256 packed = uint256(data.savingsPercentage) |
                        (uint256(data.lastUpdateTimestamp) << 128) |
                        (uint256(data.autoIncrement) << 192) |
                        (uint256(data.maxPercentage) << 224) |
                        (uint256(data.savingsTokenType) << 240) |
                        (uint256(data.roundUpEnabled) << 248) |
                        (uint256(data.dcaEnabled) << 252) |
                        (uint256(data.dailySavingsEnabled) << 254);
        
        assembly {
            sstore(slot, packed)
        }
    }
    
    /// @notice Calculate savings amount in memory (no external calls for gas optimization)
    function _calculateSavingsInMemory(
        uint256 amount,
        uint256 percentage,
        bool roundUp
    ) internal pure returns (uint256) {
        if (percentage == 0 || amount == 0) return 0;
        
        uint256 savingsAmount = (amount * percentage) / BASIS_POINTS;
        
        if (roundUp && (amount * percentage) % BASIS_POINTS > 0) {
            savingsAmount += 1;
        }
        
        return savingsAmount;
    }
    
    /// @notice Batch update savings in storage (single SSTORE for gas optimization)
    function _batchUpdateSavings(
        address user,
        address tokenAddr,
        uint256 amount
    ) internal {
        // Pack the update data
        bytes memory updateData = abi.encode(user, token, amount, block.timestamp);
        
        // Single storage write through optimized storage function
        storage_.batchUpdateUserSavings(updateData);
    }
    
    /// @notice Update user statistics with auto-increment
    function _updateUserStats(address user) internal {
        PackedUserData memory userData = _loadPackedUserData(user);
        
        // Apply auto-increment if configured
        if (userData.autoIncrement > 0 && 
            block.timestamp > userData.lastUpdateTimestamp + 1 days) {
            
            uint256 newPercentage = userData.savingsPercentage + userData.autoIncrement;
            if (newPercentage > userData.maxPercentage) {
                newPercentage = userData.maxPercentage;
            }
            
            userData.savingsPercentage = uint128(newPercentage);
            userData.lastUpdateTimestamp = uint64(block.timestamp);
            
            _savePackedUserData(user, userData);
        }
    }
    
    /// @notice Public function to set user strategy (updates packed data)
    function setUserStrategy(
        address user,
        uint256 percentage,
        uint256 autoIncrement,
        uint256 maxPercentage,
        bool roundUp,
        uint8 savingsTokenType
    ) external {
        if (msg.sender != address(savingStrategyModule) && msg.sender != user) {
            revert UnauthorizedAccess(msg.sender);
        }
        
        if (percentage > BASIS_POINTS) revert InvalidPercentage(percentage);
        
        PackedUserData memory userData = _loadPackedUserData(user);
        userData.savingsPercentage = uint128(percentage);
        userData.autoIncrement = uint32(autoIncrement);
        userData.maxPercentage = uint16(maxPercentage);
        userData.roundUpEnabled = roundUp ? 1 : 0;
        userData.savingsTokenType = savingsTokenType;
        userData.lastUpdateTimestamp = uint64(block.timestamp);
        
        _savePackedUserData(user, userData);
    }
    
    /**
    * @notice Defines which hook points are used by this contract
    * @return Hooks.Permissions Permission configuration for the hook
    * @dev Enables beforeSwap, afterSwap, and beforeSwapReturnDelta
    */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,  // Enable beforeSwap
            afterSwap: true,  // Enable afterSwap
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // Enable beforeSwapReturnsDelta
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
    
    /**
    * @notice Verifies that all modules are initialized - only when needed
    * @dev Reverts if any module is not initialized
    */
    function _checkModulesInitialized() internal view {
        if (address(savingStrategyModule) == address(0)) revert ModuleNotInitialized("SavingStrategy");
        if (address(savingsModule) == address(0)) revert ModuleNotInitialized("Savings");
        if (address(dcaModule) == address(0)) revert ModuleNotInitialized("DCA");
        if (address(slippageControlModule) == address(0)) revert ModuleNotInitialized("SlippageControl");
        if (address(tokenModule) == address(0)) revert ModuleNotInitialized("Token");
        if (address(dailySavingsModule) == address(0)) revert ModuleNotInitialized("DailySavings");
        // Also check the yieldModule if it's used in any functions
        // if (address(yieldModule) == address(0)) revert ModuleNotInitialized("Yield");
    }

    /// @notice Extract user address from hook data (gas optimized)
    function _extractUserFromHookData(
        address sender,
        bytes calldata hookData
    ) internal pure returns (address) {
        if (hookData.length >= 20) {
            return address(bytes20(hookData[0:20]));
        }
        return sender;
    }

    /**
    * @notice Implements the beforeSwap hook
    * @param sender The address of the sender
    * @param key The pool key
    * @param params The swap parameters
    * @param hookData Additional data for the hook
    * @return bytes4 The selector for the hook
    * @return BeforeSwapDelta The delta before the swap
    * @return uint24 The custom slippage tolerance
    */
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal virtual override nonReentrant returns (bytes4, BeforeSwapDelta, uint24) {
        // Extract actual user from hookData if available
        address actualUser = _extractUserFromHookData(sender, hookData);
        
        // Default to no adjustment (zero delta)
        BeforeSwapDelta deltaBeforeSwap = toBeforeSwapDelta(0, 0);
        
        // Only check modules if user has a strategy
        if (_hasUserStrategy(actualUser)) {
            _checkModulesInitialized();
            
            // Try to execute beforeSwap and get the adjustment delta
            try savingStrategyModule.beforeSwap(actualUser, key, params) returns (BeforeSwapDelta delta) {
                deltaBeforeSwap = delta;
            } catch Error(string memory reason) {
                emit BeforeSwapError(actualUser, reason);
            } catch {
                emit BeforeSwapError(actualUser, "Unknown error in beforeSwap");
            }
        }
        
        return (IHooks.beforeSwap.selector, deltaBeforeSwap, 0);
    }
    
    /// @notice Gas-optimized beforeSwap with transient storage
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        address actualUser = _extractUserFromHookData(sender, hookData);
        
        // Load packed user data in single SLOAD
        PackedUserData memory userData = _loadPackedUserData(actualUser);
        
        // Skip if no active strategy
        if (userData.savingsPercentage == 0) {
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(0, 0), 0);
        }
        
        // Calculate savings amount in memory
        uint256 savingsAmount = _calculateSavingsInMemory(
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified),
            userData.savingsPercentage,
            userData.roundUpEnabled == 1
        );
        
        // Store in transient storage for afterSwap
        assembly {
            tstore(SLOT_PENDING_SAVE_AMOUNT, savingsAmount)
            tstore(SLOT_SAVINGS_TOKEN_TYPE, userData.savingsTokenType)
            tstore(SLOT_USER_ADDRESS, actualUser)
        }
        
        // Apply delta if saving from input token
        BeforeSwapDelta delta = toBeforeSwapDelta(0, 0);
        if (userData.savingsTokenType == 1) { // INPUT token
            int256 deltaAmount = -int256(savingsAmount);
            delta = params.zeroForOne 
                ? toBeforeSwapDelta(deltaAmount, 0)
                : toBeforeSwapDelta(0, deltaAmount);
        }
        
        emit BeforeSwapExecuted(actualUser, delta);
        return (IHooks.beforeSwap.selector, delta, 0);
    }

    // Try to execute beforeSwap with error handling
    function _tryBeforeSwap(
        address actualUser, 
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params
    ) internal returns (bool) {
        try savingStrategyModule.beforeSwap(actualUser, key, params) {
            return true;
        } catch Error(string memory reason) {
            emit BeforeSwapError(actualUser, reason);
            return false;
        } catch {
            emit BeforeSwapError(actualUser, "Unknown error in beforeSwap");
            return false;
        }
    }
    
    // Check if user has a saving strategy
    function _hasUserStrategy(address user) internal view returns (bool) {
        (uint256 percentage,,,,,,, ) = storage_.getUserSavingStrategy(user);
        return percentage > 0;
    }
    
    /// @notice Check if user has a saving strategy using packed data (gas optimized)
    function _hasUserStrategyOptimized(address user) internal view returns (bool) {
        PackedUserData memory userData = _loadPackedUserData(user);
        return userData.savingsPercentage > 0;
    }

    // Process savings based on token type - properly organized helper functions
    function _processSavings(
        address actualUser,
        SpendSaveStorage.SwapContext memory context,
        PoolKey calldata key,
        BalanceDelta delta
    ) internal virtual {
        if (!context.hasStrategy) return;
        
        // Input token savings type handling - already processed in _afterSwap
        if (context.savingsTokenType == SpendSaveStorage.SavingsTokenType.INPUT && 
            context.pendingSaveAmount > 0) {
            
            // Tokens have already been taken in _afterSwap via take()
            try savingStrategyModule.processInputSavingsAfterSwap(actualUser, context) {
                // Success
            } catch Error(string memory reason) {
                emit AfterSwapError(actualUser, reason);
            } catch {
                emit AfterSwapError(actualUser, "Failed to process input savings");
            }
            
            // Update saving strategy
            savingStrategyModule.updateSavingStrategy(actualUser, context);
            return;
        }
        
        // Output token or specific token savings are handled by _processOutputSavings
        // This is a fallback in case they weren't already processed
        (address outputToken, uint256 outputAmount, bool isToken0) = _getOutputTokenAndAmount(key, delta);
        
        // Skip if no positive output
        if (outputAmount == 0) return;
        
        // Process based on token type - only if not already processed
        if (context.savingsTokenType == SpendSaveStorage.SavingsTokenType.OUTPUT) {
            _processOutputTokenSavings(actualUser, context, outputToken, outputAmount);
        } else if (context.savingsTokenType == SpendSaveStorage.SavingsTokenType.SPECIFIC) {
            _processSpecificTokenSavings(actualUser, context, outputToken, outputAmount);
        }
        
        // Update saving strategy if using auto-increment
        savingStrategyModule.updateSavingStrategy(actualUser, context);
    }

    // Helper for output token savings
    function _processOutputTokenSavings(
        address actualUser,
        SpendSaveStorage.SwapContext memory context,
        address outputToken,
        uint256 outputAmount
    ) internal {
        // Process savings from output token
        savingsModule.processSavingsFromOutput(actualUser, outputToken, outputAmount, context);
        
        // Handle DCA if enabled
        _processDCAIfEnabled(actualUser, context, outputToken);
        
        // Add token to processing queue for future daily savings
        _addTokenToProcessingQueue(actualUser, outputToken);
    }

    // Helper for specific token savings
    function _processSpecificTokenSavings(
        address actualUser,
        SpendSaveStorage.SwapContext memory context,
        address outputToken,
        uint256 outputAmount
    ) internal {
        // Process savings to specific token
        savingsModule.processSavingsToSpecificToken(actualUser, outputToken, outputAmount, context);
        
        // Add specific token to processing queue
        _addTokenToProcessingQueue(actualUser, context.specificSavingsToken);
    }

    // Helper function to handle DCA processing
    function _processDCAIfEnabled(
        address actualUser,
        SpendSaveStorage.SwapContext memory context,
        address outputToken
    ) internal {
        bool shouldProcessDCA = context.enableDCA && 
                               context.dcaTargetToken != address(0) && 
                               outputToken != context.dcaTargetToken;
                               
        if (shouldProcessDCA) {
            dcaModule.queueDCAFromSwap(actualUser, outputToken, context);
        }
    }

    /**
     * @notice Hook function called after a Uniswap V4 swap to process savings and check daily savings
     * @dev This function handles saving input tokens, output tokens, and specific token savings
     * @param sender The address initiating the swap
     * @param key The Uniswap V4 pool key containing token and fee information
     * @param params The Uniswap V4 swap parameters containing amounts and direction
     * @param delta The balance changes from the swap
     * @param hookData Additional data passed to the hook, may contain actual user address
     * @return bytes4 The function selector to indicate successful hook execution
     * @return int128 The delta adjustment to apply to output amounts for savings
     * @custom:security nonReentrant Only one execution at a time
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal virtual override nonReentrant returns (bytes4, int128) {
        // Extract actual user from hookData if available
        address actualUser = _extractUserFromHookData(sender, hookData);

        // Get swap context
        SpendSaveStorage.SwapContext memory context = storage_.getSwapContext(actualUser);

        // HANDLE INPUT TOKEN SAVINGS
        if (context.hasStrategy && 
            context.savingsTokenType == SpendSaveStorage.SavingsTokenType.INPUT && 
            context.pendingSaveAmount > 0) {
            
            // Take the tokens that were saved from the swap
            if (params.zeroForOne) {
                // For zeroForOne swaps, input token is token0
                key.currency0.take(
                    storage_.poolManager(),
                    address(this),
                    context.pendingSaveAmount,
                    false  // Do not mint claim tokens to the hook
                );
            } else {
                // For oneForZero swaps, input token is token1
                key.currency1.take(
                    storage_.poolManager(),
                    address(this),
                    context.pendingSaveAmount,
                    false  // Do not mint claim tokens to the hook
                );
            }
        }
        
        // HANDLE OUTPUT TOKEN SAVINGS 
        if (context.hasStrategy && 
            (context.savingsTokenType == SpendSaveStorage.SavingsTokenType.OUTPUT || 
            context.savingsTokenType == SpendSaveStorage.SavingsTokenType.SPECIFIC)) {
            
            // Get output token based on swap direction
            Currency outputCurrency;
            address outputToken;
            int256 outputAmount;
            bool isToken0;
            
            if (params.zeroForOne) {
                // If swapping token0 → token1, output is token1
                outputCurrency = key.currency1;
                outputToken = Currency.unwrap(key.currency1);
                outputAmount = delta.amount1();
                isToken0 = false;
            } else {
                // If swapping token1 → token0, output is token0
                outputCurrency = key.currency0;
                outputToken = Currency.unwrap(key.currency0);
                outputAmount = delta.amount0();
                isToken0 = true;
            }
            
            // Only proceed if output is positive
            if (outputAmount > 0) {
                // Calculate savings amount (10% of output)
                uint256 saveAmount = savingStrategyModule.calculateSavingsAmount(
                    uint256(outputAmount),
                    context.currentPercentage,
                    context.roundUpSavings
                );
                
                if (saveAmount > 0 && saveAmount <= uint256(outputAmount)) {
                    // Store saveAmount in context
                    context.pendingSaveAmount = saveAmount;
                    storage_.setSwapContext(actualUser, context);
                    
                    // CRITICAL FIX 1: Enable claim tokens when taking currency
                    outputCurrency.take(
                        poolManager,
                        address(this),
                        saveAmount,
                        true  // ENABLE claim tokens for proper settlement
                    );
                    
                    // Process savings
                    _processOutputSavings(actualUser, context, key, outputToken, isToken0);
                    
                    // CRITICAL FIX 2: Return POSITIVE delta to properly account for taken tokens
                    // This tells Uniswap we're taking these tokens from the user's output
                    return (IHooks.afterSwap.selector, int128(int256(saveAmount)));
                }
            }
        }
        
        // Handle other logic without using try/catch
        bool success = _executeAfterSwapLogic(actualUser, key, params, delta);
        
        if (!success) {
            emit AfterSwapError(actualUser, "Error in afterSwap execution");
        }
        
        return (IHooks.afterSwap.selector, 0);
    }
    
    /// @notice Gas-optimized afterSwap implementation (<50k gas)
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        uint256 gasStart = gasleft();
        
        // Load from transient storage
        uint256 pendingSaveAmount;
        uint8 savingsTokenType;
        address actualUser;
        assembly {
            pendingSaveAmount := tload(SLOT_PENDING_SAVE_AMOUNT)
            savingsTokenType := tload(SLOT_SAVINGS_TOKEN_TYPE)
            actualUser := tload(SLOT_USER_ADDRESS)
        }
        
        // Clear transient storage
        assembly {
            tstore(SLOT_PENDING_SAVE_AMOUNT, 0)
            tstore(SLOT_SAVINGS_TOKEN_TYPE, 0)
            tstore(SLOT_USER_ADDRESS, 0)
        }
        
        // Skip if no savings to process
        if (pendingSaveAmount == 0) {
            return (IHooks.afterSwap.selector, 0);
        }
        
        int128 deltaAdjustment = 0;
        
        // Process based on savings token type
        if (savingsTokenType == 1) { // INPUT token
            // Take tokens that were already accounted for in beforeSwap
            Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
            inputCurrency.take(poolManager, address(this), pendingSaveAmount, false);
            
            // Update storage in single batch operation
            _batchUpdateSavings(actualUser, Currency.unwrap(inputCurrency), pendingSaveAmount);
            
        } else if (savingsTokenType == 2 || savingsTokenType == 3) { // OUTPUT or SPECIFIC token
            // Calculate actual output amount from delta
            int256 outputAmount = params.zeroForOne ? delta.amount1() : delta.amount0();
            if (outputAmount > 0) {
                uint256 actualSavings = uint256(outputAmount) >= pendingSaveAmount 
                    ? pendingSaveAmount 
                    : uint256(outputAmount);
                
                deltaAdjustment = -int128(int256(actualSavings));
                
                Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
                _batchUpdateSavings(actualUser, Currency.unwrap(outputCurrency), actualSavings);
            }
        }
        
        // Update user statistics if needed (single storage write)
        _updateUserStats(actualUser);
        
        emit AfterSwapExecuted(actualUser, delta, pendingSaveAmount);
        emit GasOptimizationApplied(gasStart - gasleft());
        
        return (IHooks.afterSwap.selector, deltaAdjustment);
    }

    // NEW HELPER: Process output savings tokens that were kept by afterSwapReturnDelta
    function _processOutputSavings(
        address actualUser,
        SpendSaveStorage.SwapContext memory context,
        PoolKey calldata key,
        address outputToken,
        bool isToken0
    ) internal virtual {
        uint256 saveAmount = context.pendingSaveAmount;
        
        // For SPECIFIC token savings type
        address tokenToSave = outputToken;
        bool swapQueued = false;
        
        // Check if we need to swap to a specific token
        if (context.savingsTokenType == SpendSaveStorage.SavingsTokenType.SPECIFIC && 
            context.specificSavingsToken != address(0) &&
            context.specificSavingsToken != outputToken) {
            
            // Approve DCA module to spend our tokens
            IERC20(outputToken).approve(address(dcaModule), saveAmount);
            
            // Create a pool key for the swap from output token to specific token
            PoolKey memory poolKeyForDCA = storage_.createPoolKey(outputToken, context.specificSavingsToken);
            
            // Get current tick for the pool
            int24 currentTick = dcaModule.getCurrentTick(poolKeyForDCA);
            
            // Try to queue a DCA execution for this token with proper pool key and tick
            try dcaModule.queueDCAExecution(
                actualUser,
                outputToken,
                context.specificSavingsToken,
                saveAmount,
                poolKeyForDCA,
                currentTick,
                0  // Default custom slippage tolerance
            ) {
                // Mark that we've queued a swap
                swapQueued = true;
                emit SpecificTokenSwapQueued(
                    actualUser, 
                    outputToken, 
                    context.specificSavingsToken, 
                    saveAmount
                );
                
                // The DCA module now has the tokens and will process savings after swap
            } catch Error(string memory reason) {
                emit AfterSwapError(actualUser, reason);
            } catch {
                emit AfterSwapError(actualUser, "Failed to queue specific token swap");
            }
        }
        
        // Only process savings if we didn't queue a swap
        if (!swapQueued) {
            // Process the saved tokens directly
            try savingsModule.processSavings(actualUser, tokenToSave, saveAmount) {
                emit OutputSavingsProcessed(actualUser, tokenToSave, saveAmount);
                
                // Add token to processing queue for future daily savings
                _addTokenToProcessingQueue(actualUser, tokenToSave);
                
                // Handle regular DCA if enabled (separate from specific token swap)
                if (context.enableDCA && context.dcaTargetToken != address(0) && 
                    tokenToSave != context.dcaTargetToken) {
                    _processDCAIfEnabled(actualUser, context, tokenToSave);
                }
            } catch Error(string memory reason) {
                emit AfterSwapError(actualUser, reason);
            } catch {
                emit AfterSwapError(actualUser, "Failed to process output savings");
            }
        }
        
        // Update saving strategy regardless of whether we queued a swap
        savingStrategyModule.updateSavingStrategy(actualUser, context);
    }
    
    // Execute afterSwap logic with proper error handling
    function _executeAfterSwapLogic(
        address actualUser, 
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta
    ) internal returns (bool) {
        // Only perform work if necessary - skip for savings already processed by _processOutputSavings
        SpendSaveStorage.SwapContext memory context = storage_.getSwapContext(actualUser);
        
        if (!_shouldProcessSwap(actualUser) || 
            ((context.savingsTokenType == SpendSaveStorage.SavingsTokenType.OUTPUT || 
              context.savingsTokenType == SpendSaveStorage.SavingsTokenType.SPECIFIC) && 
             context.pendingSaveAmount > 0)) {
            // Clean up context and return success
            storage_.deleteSwapContext(actualUser);
            return true;
        }
        
        // Check modules only if needed
        try this.checkModulesInitialized() {
            // Process swap savings for INPUT token type
            bool savingsProcessed = _trySavingsProcessing(actualUser, context, key, delta);
            
            // Clean up context from storage regardless of processing result
            storage_.deleteSwapContext(actualUser);
            
            // Only process daily savings if conditions are met
            if (savingsProcessed && _shouldProcessDailySavings(actualUser)) {
                _tryProcessDailySavings(actualUser);
            }
            
            return true;
        } catch Error(string memory reason) {
            emit AfterSwapError(actualUser, reason);
            return false;
        } catch {
            emit AfterSwapError(actualUser, "Module initialization failed");
            return false;
        }
    }
    
    // External function to allow try/catch on module initialization
    function checkModulesInitialized() external view {
        _checkModulesInitialized();
    }
    
    // Try to process savings with error handling
    function _trySavingsProcessing(
        address actualUser, 
        SpendSaveStorage.SwapContext memory context,
        PoolKey calldata key,
        BalanceDelta delta
    ) internal returns (bool) {
        try this.processSavingsExternal(actualUser, context, key, delta) {
            return true;
        } catch Error(string memory reason) {
            emit AfterSwapError(actualUser, reason);
            return false;
        } catch {
            emit AfterSwapError(actualUser, "Unknown error processing savings");
            return false;
        }
    }
    
    // External function to allow try/catch on savings processing
    function processSavingsExternal(
        address actualUser, 
        SpendSaveStorage.SwapContext memory context,
        PoolKey calldata key,
        BalanceDelta delta
    ) external {
        if (msg.sender != address(this)) {
            // Allow authorized callers with appropriate warning
            if (msg.sender == storage_.owner() || msg.sender == storage_.spendSaveHook()) {
                emit ExternalProcessingSavingsCall(msg.sender);
            } else {
                revert UnauthorizedAccess(msg.sender);
            }
        }
        _processSavings(actualUser, context, key, delta);
    }
    
    // Check if we should process this swap
    function _shouldProcessSwap(address actualUser) internal view returns (bool) {
        return storage_.getSwapContext(actualUser).hasStrategy;
    }
    
    // Determine if daily savings should be processed
    function _shouldProcessDailySavings(address actualUser) internal view returns (bool) {
        return _hasPendingDailySavings(actualUser) && gasleft() > DAILY_SAVINGS_THRESHOLD;
    }

    // Efficient token processing queue management
    function _addTokenToProcessingQueue(address user, address tokenAddr) internal {
        if (tokenAddr == address(0)) return;
        
        TokenProcessingQueue storage queue = _tokenProcessingQueues[user];
        
        // If token is not in queue, add it
        if (queue.tokenPositions[tokenAddr] == 0) {
            queue.tokenQueue.push(tokenAddr);
            queue.tokenPositions[tokenAddr] = queue.tokenQueue.length;
        }
    }
    
    // Remove token from processing queue
    function _removeTokenFromProcessingQueue(address user, address tokenAddr) internal {
        TokenProcessingQueue storage queue = _tokenProcessingQueues[user];
        uint256 position = queue.tokenPositions[tokenAddr];
        
        // If token is in queue
        if (position > 0) {
            uint256 index = position - 1;
            uint256 lastIndex = queue.tokenQueue.length - 1;
            
            // If not the last element, swap with last element
            if (index != lastIndex) {
                address lastToken = queue.tokenQueue[lastIndex];
                queue.tokenQueue[index] = lastToken;
                queue.tokenPositions[lastToken] = position;
            }
            
            // Remove last element
            queue.tokenQueue.pop();
            queue.tokenPositions[tokenAddr] = 0;
        }
    }
    
    // Get tokens due for processing
    function _getTokensDueForProcessing(address user) internal view returns (address[] memory) {
        TokenProcessingQueue storage queue = _tokenProcessingQueues[user];
        address[] memory dueTokens = new address[](queue.tokenQueue.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < queue.tokenQueue.length; i++) {
            address tokenAddr = queue.tokenQueue[i];
            (bool canExecute, , ) = _getDailyExecutionStatus(user, tokenAddr);
            
            if (canExecute) {
                dueTokens[count] = tokenAddr;
                count++;
            }
        }
        
        // Resize array to actual number of due tokens
        assembly {
            mstore(dueTokens, count)
        }
        
        return dueTokens;
    }

    // Public function to process daily savings - can be called separately
    function processDailySavings(address user) external nonReentrant {
        _checkModulesInitialized();
        require(_hasPendingDailySavings(user), "No pending savings");
        
        // Get eligible tokens and process them
        address[] memory eligibleTokens = _getTokensDueForProcessing(user);
        DailySavingsProcessor memory processor = _initDailySavingsProcessor(user, eligibleTokens);
        _processDailySavingsForTokens(user, processor);
    }
    
    /// @notice Process daily savings (called by automation) - gas optimized version
    function processDailySavingsOptimized(address user) external nonReentrant {
        if (msg.sender != address(dailySavingsModule) && 
            msg.sender != user && 
            msg.sender != storage_.owner()) {
            revert UnauthorizedAccess(msg.sender);
        }
        
        // Delegate to daily savings module for complex logic
        dailySavingsModule.executeDailySavings(user);
    }

    function _tryProcessDailySavings(address user) internal {
        // Exit early if conditions aren't met
        if (!_hasPendingDailySavings(user) || gasleft() < DAILY_SAVINGS_THRESHOLD) return;
        
        // Get eligible tokens and process them
        address[] memory eligibleTokens = _getTokensDueForProcessing(user);
        DailySavingsProcessor memory processor = _initDailySavingsProcessor(user, eligibleTokens);
        _processDailySavingsForTokens(user, processor);
    }

    function _processDailySavingsForTokens(
        address user, 
        DailySavingsProcessor memory processor
    ) internal {
        uint256 tokenCount = processor.tokens.length;
        
        // Process in batches for gas efficiency
        for (uint256 i = 0; i < tokenCount; i += BATCH_SIZE) {
            // Stop if we're running low on gas
            if (gasleft() < processor.gasLimit + processor.minGasReserve) break;
            
            uint256 batchEnd = i + BATCH_SIZE > tokenCount ? tokenCount : i + BATCH_SIZE;
            _processBatch(user, processor, i, batchEnd);
        }
        
        if (processor.totalSaved > 0) {
            emit DailySavingsExecuted(user, processor.totalSaved);
        }
    }

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
            
            (uint256 savedAmount, bool success) = _processSingleToken(user, tokenAddr);
            processor.totalSaved += savedAmount;
            
            // If successful, update last processed timestamp and maybe remove from queue
            if (success) {
                _updateTokenProcessingStatus(user, tokenAddr);
            }
            
            // Adjust gas estimate based on actual usage
            uint256 gasUsed = gasStart - gasleft();
            processor.gasLimit = _adjustGasLimit(processor.gasLimit, gasUsed);
        }
    }
    
    function _updateTokenProcessingStatus(address user, address tokenAddr) internal {
        TokenProcessingQueue storage queue = _tokenProcessingQueues[user];
        queue.lastProcessed[tokenAddr] = block.timestamp;
        
        // Check if this token is done with daily savings
        (bool canExecuteAgain, , ) = _getDailyExecutionStatus(user, tokenAddr);
        
        // If it can't be executed again (completed or no longer eligible), remove from queue
        if (!canExecuteAgain) {
            _removeTokenFromProcessingQueue(user, tokenAddr);
        }
    }

    function _adjustGasLimit(
        uint256 currentLimit, 
        uint256 actualUsage
    ) internal pure returns (uint256) {
        // More sophisticated algorithm that responds to both increases and decreases
        if (actualUsage > currentLimit) {
            // Increase gas estimate, but don't overreact
            return currentLimit + ((actualUsage - currentLimit) / 4);
        } else if (actualUsage < currentLimit * 8 / 10) {
            // Decrease gas estimate if we used significantly less (below 80%)
            return (currentLimit + actualUsage) / 2;
        }
        return currentLimit; // Keep same limit if usage is close to estimate
    }

    function _processSingleToken(address user, address tokenAddr) internal returns (uint256 savedAmount, bool success) {
        try dailySavingsModule.executeDailySavingsForToken(user, tokenAddr) returns (uint256 amount) {
            if (amount > 0) {
                emit DailySavingsDetails(user, tokenAddr, amount);
                return (amount, true);
            }
        } catch Error(string memory reason) {
            emit DailySavingsExecutionFailed(user, tokenAddr, reason);
        } catch {
            emit DailySavingsExecutionFailed(user, tokenAddr, "Unknown error");
        }
        return (0, false);
    }

    function _initDailySavingsProcessor(
        address user,
        address[] memory eligibleTokens
    ) internal view returns (DailySavingsProcessor memory) {
        return DailySavingsProcessor({
            tokens: eligibleTokens,
            gasLimit: INITIAL_GAS_PER_TOKEN,
            totalSaved: 0,
            minGasReserve: MIN_GAS_TO_KEEP
        });
    }

    // Helper to get daily execution status
    function _getDailyExecutionStatus(
        address user,
        address tokenAddr
    ) internal view returns (bool canExecute, uint256 nextExecutionTime, uint256 amountToSave) {
        return dailySavingsModule.getDailyExecutionStatus(user, tokenAddr);
    }

    // Check if there are pending daily savings
    function _hasPendingDailySavings(address user) internal view returns (bool) {
        // First, check if the module is initialized
        if (address(dailySavingsModule) == address(0)) return false;
        
        return dailySavingsModule.hasPendingDailySavings(user);
    }

    // Helper function to get output token and amount from swap delta
    function _getOutputTokenAndAmount(
        PoolKey calldata key, 
        BalanceDelta delta
    ) internal virtual pure returns (address outputToken, uint256 outputAmount, bool isToken0) {
        int256 amount0 = delta.amount0();
        int256 amount1 = delta.amount1();
        
        if (amount0 > 0) {
            return (Currency.unwrap(key.currency0), uint256(amount0), true);
        } else if (amount1 > 0) {
            return (Currency.unwrap(key.currency1), uint256(amount1), false);
        }
        return (address(0), 0, false);
    }
    
    // Callback function to receive tokens from the PoolManager
    function lockAcquired(
        bytes calldata data
    ) external returns (bytes memory) {
        return abi.encode(poolManager.unlock.selector);
    }
    
    /// @notice Lock acquired for flash operations (gas optimized)
    function lockAcquiredOptimized(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
        // Decode and process flash operations if needed
        return "";
    }
    
    // Public methods to interact with token processing queue
    function getUserProcessingQueueLength(address user) external view returns (uint256) {
        return _tokenProcessingQueues[user].tokenQueue.length;
    }
    
    function getUserProcessingQueueTokens(address user) external view returns (address[] memory) {
        return _tokenProcessingQueues[user].tokenQueue;
    }
    
    function getTokenLastProcessed(address user, address tokenAddr) external view returns (uint256) {
        return _tokenProcessingQueues[user].lastProcessed[tokenAddr];
    }
    
    // Token module proxy functions
    function balanceOf(address owner, uint256 id) external view returns (uint256) {
        return tokenModule.balanceOf(owner, id);
    }
    
    function allowance(address owner, address spender, uint256 id) external view returns (uint256) {
        return tokenModule.allowance(owner, spender, id);
    }
    
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool) {
        return tokenModule.transfer(msg.sender, receiver, id, amount);
    }
    
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) external returns (bool) {
        return tokenModule.transferFrom(msg.sender, sender, receiver, id, amount);
    }
    
    function approve(address spender, uint256 id, uint256 amount) external returns (bool) {
        return tokenModule.approve(msg.sender, spender, id, amount);
    }
    
    function safeTransfer(address receiver, uint256 id, uint256 amount, bytes calldata data) external returns (bool) {
        return tokenModule.safeTransfer(msg.sender, receiver, id, amount, data);
    }
    
    function safeTransferFrom(address sender, address receiver, uint256 id, uint256 amount, bytes calldata data) external returns (bool) {
        return tokenModule.safeTransferFrom(msg.sender, sender, receiver, id, amount, data);
    }

    function _setToken(address token_) internal {
        if (token_ == address(0)) revert InvalidAddress();
        token = token_;
    }

    function _setSavings(address savings_) internal {
        if (savings_ == address(0)) revert InvalidAddress();
        savings = savings_;
    }

    function _setSavingStrategy(address savingStrategy_) internal {
        if (savingStrategy_ == address(0)) revert InvalidAddress();
        savingStrategy = savingStrategy_;
    }

    function _setDcaModule(address dcaModule_) internal {
        if (dcaModule_ == address(0)) revert InvalidAddress();
        dcaModule = IDCAModule(dcaModule_);
    }

    function _setDailySavingsModule(address dailySavingsModule_) internal {
        if (dailySavingsModule_ == address(0)) revert InvalidAddress();
        dailySavingsModule = IDailySavingsModule(dailySavingsModule_);
    }

    function _setYieldModule(address yieldModule_) internal {
        if (yieldModule_ == address(0)) revert InvalidAddress();
        yieldModule = yieldModule_;
    }

    function _setSlippageControlModule(address slippageControlModule_) internal {
        if (slippageControlModule_ == address(0)) revert InvalidAddress();
        slippageControlModule = ISlippageControlModule(slippageControlModule_);
    }
}