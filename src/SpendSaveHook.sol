// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "lib/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "lib/v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {IHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {BeforeSwapDelta} from "lib/v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IERC20} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {
    BeforeSwapDelta,
    toBeforeSwapDelta
    } from "lib/v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";


import "./SpendSaveStorage.sol";
import "./ISavingStrategyModule.sol";
import "./ISavingsModule.sol";
import "./IDCAModule.sol";
import "./ISlippageControlModule.sol";
import "./ITokenModule.sol";
import "./IDailySavingsModule.sol";

/**
 * @title SpendSaveHook
 * @author Uniswap Labs
 * @notice Main contract that implements Uniswap V4 hooks and coordinates between modules
 * @dev This contract handles savings strategies, DCA, slippage control and daily savings
 */
contract SpendSaveHook is BaseHook, ReentrancyGuard {
    using CurrencySettler for Currency;

    /// @notice Storage contract reference
    SpendSaveStorage public immutable storage_;
    
    /// @notice Module references
    ISavingStrategyModule public savingStrategyModule;
    ISavingsModule public savingsModule;
    IDCAModule public dcaModule;
    ISlippageControlModule public slippageControlModule;
    ITokenModule public tokenModule;
    IDailySavingsModule public dailySavingsModule;
    
    /// @notice Error definitions
    error ModuleNotInitialized(string moduleName);
    error InsufficientGas(uint256 available, uint256 required);
    error UnauthorizedAccess(address caller);
    
    /// @notice Events
    event DailySavingsExecuted(address indexed user, uint256 totalAmount);
    event DailySavingsDetails(address indexed user, address indexed token, uint256 amount);
    event DailySavingsExecutionFailed(address indexed user, address indexed token, string reason);
    event SingleTokenSavingsExecuted(address indexed user, address indexed token, uint256 amount);
    event ModulesInitialized(address strategyModule, address savingsModule, address dcaModule, address slippageModule, address tokenModule, address dailySavingsModule);
    event BeforeSwapError(address indexed user, string reason);
    event AfterSwapError(address indexed user, string reason);
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
        _storeModuleReferences(
            _strategyModule, 
            _savingsModule, 
            _dcaModule, 
            _slippageModule, 
            _tokenModule, 
            _dailySavingsModule
        );
        _registerModulesWithStorage(
            _strategyModule, 
            _savingsModule, 
            _dcaModule, 
            _slippageModule, 
            _tokenModule, 
            _dailySavingsModule
        );
        
        emit ModulesInitialized(_strategyModule, _savingsModule, _dcaModule, _slippageModule, _tokenModule, _dailySavingsModule);
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
    
    // Separate helper to register modules with storage
    function _registerModulesWithStorage(
        address _strategyModule,
        address _savingsModule,
        address _dcaModule,
        address _slippageModule,
        address _tokenModule,
        address _dailySavingsModule
    ) internal {
        storage_.setSavingStrategyModule(_strategyModule);
        storage_.setSavingsModule(_savingsModule);
        storage_.setDCAModule(_dcaModule);
        storage_.setSlippageControlModule(_slippageModule);
        storage_.setTokenModule(_tokenModule);
        storage_.setDailySavingsModule(_dailySavingsModule);
    }
    
    // Implement hook permissions
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
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
    
    // Verify modules are initialized - only when needed
    function _checkModulesInitialized() internal view {
        if (address(savingStrategyModule) == address(0)) revert ModuleNotInitialized("SavingStrategy");
        if (address(savingsModule) == address(0)) revert ModuleNotInitialized("Savings");
        if (address(dcaModule) == address(0)) revert ModuleNotInitialized("DCA");
        if (address(slippageControlModule) == address(0)) revert ModuleNotInitialized("SlippageControl");
        if (address(tokenModule) == address(0)) revert ModuleNotInitialized("Token");
    }

    // helper function to extract user identity
    function _extractUserFromHookData(address sender, bytes calldata hookData) internal pure returns (address) {
        // If hook data contains at least 20 bytes (address size), try to decode it
        if (hookData.length >= 32) { // Need at least 32 bytes for an address in ABI encoding
            // Basic validation that it's likely an address
            address potentialUser = address(uint160(uint256(bytes32(hookData[:32]))));
            if (potentialUser != address(0)) {
                return potentialUser;
            }
        }
        return sender;
    }

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

    // function _afterSwapReturnDelta(
    //     address sender,
    //     PoolKey calldata key,
    //     IPoolManager.SwapParams calldata params,
    //     BalanceDelta delta,
    //     bytes calldata hookData
    // ) internal virtual nonReentrant returns (bytes4, int128, int128) {
    //     // Extract actual user from hookData if available
    //     address actualUser = _extractUserFromHookData(sender, hookData);
        
    //     // Get the swap context
    //     SpendSaveStorage.SwapContext memory context = storage_.getSwapContext(actualUser);
        
    //     // Early return if no strategy or not applicable to output savings
    //     if (!context.hasStrategy || 
    //         (context.savingsTokenType != SpendSaveStorage.SavingsTokenType.OUTPUT && 
    //          context.savingsTokenType != SpendSaveStorage.SavingsTokenType.SPECIFIC)) {
    //         return (IHooks.afterSwapReturnDelta.selector, 0, 0);
    //     }
        
    //     // Determine which token is the output, amount, and whether it's token0
    //     (address outputToken, uint256 outputAmount, bool isToken0) = _getOutputTokenAndAmount(key, delta);
        
    //     // Skip if no output
    //     if (outputAmount == 0) {
    //         return (IHooks.afterSwapReturnDelta.selector, 0, 0);
    //     }
        
    //     // Calculate how much to save based on strategy percentage
    //     uint256 saveAmount = savingStrategyModule.calculateSavingsAmount(
    //         outputAmount,
    //         context.currentPercentage,
    //         context.roundUpSavings
    //     );
        
    //     if (saveAmount == 0) {
    //         return (IHooks.afterSwapReturnDelta.selector, 0, 0);
    //     }
        
    //     // Store saveAmount in context for afterSwap to use
    //     context.pendingSaveAmount = saveAmount;
    //     storage_.setSwapContext(actualUser, context);
        
    //     emit OutputSavingsCalculated(actualUser, outputToken, saveAmount);
        
    //     // Return delta that reduces user's output by the savings amount
    //     // A negative delta means the hook keeps these tokens
    //     if (isToken0) {
    //         return (IHooks.afterSwapReturnDelta.selector, -int128(int256(saveAmount)), 0);
    //     } else {
    //         return (IHooks.afterSwapReturnDelta.selector, 0, -int128(int256(saveAmount)));
    //     }
    // }

    
    
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

    // Process savings based on token type - properly organized helper functions
    // function _processSavings(
    //     address actualUser,
    //     SpendSaveStorage.SwapContext memory context,
    //     PoolKey calldata key,
    //     BalanceDelta delta
    // ) internal virtual {
    //     if (!context.hasStrategy) return;
        
    //     // Input token savings type handling
    //     if (context.savingsTokenType == SpendSaveStorage.SavingsTokenType.INPUT && 
    //         context.pendingSaveAmount > 0) {
            
    //         // UPDATED: Tokens have already been taken in _afterSwap via take()
    //         try savingStrategyModule.processInputSavingsAfterSwap(actualUser, context) {
    //             // Success
    //         } catch Error(string memory reason) {
    //             emit AfterSwapError(actualUser, reason);
    //         } catch {
    //             emit AfterSwapError(actualUser, "Failed to process input savings");
    //         }
            
    //         // Update saving strategy
    //         savingStrategyModule.updateSavingStrategy(actualUser, context);
    //         return;
    //     }
        
    //     // Get output token and amount
    //     (address outputToken, uint256 outputAmount) = _getOutputTokenAndAmount(key, delta);
        
    //     // Skip if no positive output
    //     if (outputAmount == 0) return;
        
    //     // Process based on token type
    //     if (context.savingsTokenType == SpendSaveStorage.SavingsTokenType.OUTPUT) {
    //         _processOutputTokenSavings(actualUser, context, outputToken, outputAmount);
    //     } else if (context.savingsTokenType == SpendSaveStorage.SavingsTokenType.SPECIFIC) {
    //         _processSpecificTokenSavings(actualUser, context, outputToken, outputAmount);
    //     }
        
    //     // Update saving strategy if using auto-increment
    //     savingStrategyModule.updateSavingStrategy(actualUser, context);
    // }


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

    // Hook into afterSwap to process savings and check for daily savings
    // function _afterSwap(
    //     address sender,
    //     PoolKey calldata key,
    //     IPoolManager.SwapParams calldata params,
    //     BalanceDelta delta,
    //     bytes calldata hookData
    // ) internal virtual override nonReentrant returns (bytes4, int128) {
    //     // Extract actual user from hookData if available
    //     address actualUser = _extractUserFromHookData(sender, hookData);

    //     // Get swap context
    //     SpendSaveStorage.SwapContext memory context = storage_.getSwapContext(actualUser);
        
    //     // IMPORTANT NEW CODE: Handle token taking in afterSwap for INPUT savings type
    //     if (context.hasStrategy && 
    //         context.savingsTokenType == SpendSaveStorage.SavingsTokenType.INPUT && 
    //         context.pendingSaveAmount > 0) {
            
    //         // Take the tokens that were saved from the swap
    //         if (params.zeroForOne) {
    //             // For zeroForOne swaps, input token is token0
    //             key.currency0.take(
    //                 poolManager,
    //                 address(this),
    //                 context.pendingSaveAmount,
    //                 true  // Mint claim tokens to the hook
    //             );
    //         } else {
    //             // For oneForZero swaps, input token is token1
    //             key.currency1.take(
    //                 poolManager,
    //                 address(this),
    //                 context.pendingSaveAmount,
    //                 true  // Mint claim tokens to the hook
    //             );
    //         }
    //     }
        
    //     // Handle errors without using try/catch at the top level
    //     bool success = _executeAfterSwapLogic(actualUser, key, params, delta);
        
    //     if (!success) {
    //         // We still return the selector to allow the swap to complete
    //         emit AfterSwapError(actualUser, "Error in afterSwap execution");
    //     }
        
    //     return (IHooks.afterSwap.selector, 0);
    // }

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
                    poolManager,
                    address(this),
                    context.pendingSaveAmount,
                    true  // Mint claim tokens to the hook
                );
            } else {
                // For oneForZero swaps, input token is token1
                key.currency1.take(
                    poolManager,
                    address(this),
                    context.pendingSaveAmount,
                    true  // Mint claim tokens to the hook
                );
            }
        }
        
        // HANDLE OUTPUT TOKEN SAVINGS 
        if (context.hasStrategy && 
            (context.savingsTokenType == SpendSaveStorage.SavingsTokenType.OUTPUT || 
            context.savingsTokenType == SpendSaveStorage.SavingsTokenType.SPECIFIC)) {
            
            // Get output token information
            (address outputToken, uint256 outputAmount, bool isToken0) = _getOutputTokenAndAmount(key, delta);
            
            if (outputToken != address(0) && outputAmount > 0) {
                // Calculate how much to save based on strategy percentage
                uint256 saveAmount = savingStrategyModule.calculateSavingsAmount(
                    outputAmount,
                    context.currentPercentage,
                    context.roundUpSavings
                );
                
                if (saveAmount > 0 && saveAmount <= outputAmount) {
                    // Store saveAmount in context for processing
                    context.pendingSaveAmount = saveAmount;
                    storage_.setSwapContext(actualUser, context);
                    
                    // Take the tokens directly from the pool
                    Currency outputCurrency = isToken0 ? key.currency0 : key.currency1;
                    
                    // Note: We need to take these tokens first before returning the delta
                    outputCurrency.take(
                        poolManager,
                        address(this),
                        saveAmount,
                        true  // Mint claim tokens to the hook
                    );
                    
                    // Process the output token savings immediately
                    _processOutputSavings(actualUser, context, key, outputToken, isToken0);
                    
                    // Return a negative delta to reduce the user's output by the save amount
                    // This ensures the pool knows these tokens have been taken
                    return (IHooks.afterSwap.selector, isToken0 ? -int128(int256(saveAmount)) : -int128(int256(saveAmount)));
                }
            }
        }
        
        // Handle other logic without using try/catch at the top level
        bool success = _executeAfterSwapLogic(actualUser, key, params, delta);
        
        if (!success) {
            // We still return the selector to allow the swap to complete
            emit AfterSwapError(actualUser, "Error in afterSwap execution");
        }
        
        return (IHooks.afterSwap.selector, 0);
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
    // function _executeAfterSwapLogic(
    //     address actualUser, 
    //     PoolKey calldata key,
    //     IPoolManager.SwapParams calldata params,
    //     BalanceDelta delta
    // ) internal returns (bool) {
    //     // Only perform work if necessary
    //     if (!_shouldProcessSwap(actualUser)) {
    //         return true;
    //     }
        
    //     // Check modules only if needed
    //     try this.checkModulesInitialized() {
    //         // Process swap savings
    //         SpendSaveStorage.SwapContext memory context = storage_.getSwapContext(actualUser);
            
    //         bool savingsProcessed = _trySavingsProcessing(actualUser, context, key, delta);
            
    //         // Clean up context from storage regardless of processing result
    //         storage_.deleteSwapContext(actualUser);
            
    //         // Only process daily savings if conditions are met
    //         if (savingsProcessed && _shouldProcessDailySavings(actualUser)) {
    //             _tryProcessDailySavings(actualUser);
    //         }
            
    //         return true;
    //     } catch Error(string memory reason) {
    //         emit AfterSwapError(actualUser, reason);
    //         return false;
    //     } catch {
    //         emit AfterSwapError(actualUser, "Module initialization failed");
    //         return false;
    //     }
    // }

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
        require(msg.sender == address(this), "Only self-call allowed");
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
    function _addTokenToProcessingQueue(address user, address token) internal {
        if (token == address(0)) return;
        
        TokenProcessingQueue storage queue = _tokenProcessingQueues[user];
        
        // If token is not in queue, add it
        if (queue.tokenPositions[token] == 0) {
            queue.tokenQueue.push(token);
            queue.tokenPositions[token] = queue.tokenQueue.length;
        }
    }
    
    // Remove token from processing queue
    function _removeTokenFromProcessingQueue(address user, address token) internal {
        TokenProcessingQueue storage queue = _tokenProcessingQueues[user];
        uint256 position = queue.tokenPositions[token];
        
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
            queue.tokenPositions[token] = 0;
        }
    }
    
    // Get tokens due for processing
    function _getTokensDueForProcessing(address user) internal view returns (address[] memory) {
        TokenProcessingQueue storage queue = _tokenProcessingQueues[user];
        address[] memory dueTokens = new address[](queue.tokenQueue.length);
        uint256 count = 0;
        
        for (uint256 i = 0; i < queue.tokenQueue.length; i++) {
            address token = queue.tokenQueue[i];
            (bool canExecute, , ) = _getDailyExecutionStatus(user, token);
            
            if (canExecute) {
                dueTokens[count] = token;
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
            
            address token = processor.tokens[i];
            uint256 gasStart = gasleft();
            
            (uint256 savedAmount, bool success) = _processSingleToken(user, token);
            processor.totalSaved += savedAmount;
            
            // If successful, update last processed timestamp and maybe remove from queue
            if (success) {
                _updateTokenProcessingStatus(user, token);
            }
            
            // Adjust gas estimate based on actual usage
            uint256 gasUsed = gasStart - gasleft();
            processor.gasLimit = _adjustGasLimit(processor.gasLimit, gasUsed);
        }
    }
    
    function _updateTokenProcessingStatus(address user, address token) internal {
        TokenProcessingQueue storage queue = _tokenProcessingQueues[user];
        queue.lastProcessed[token] = block.timestamp;
        
        // Check if this token is done with daily savings
        (bool canExecuteAgain, , ) = _getDailyExecutionStatus(user, token);
        
        // If it can't be executed again (completed or no longer eligible), remove from queue
        if (!canExecuteAgain) {
            _removeTokenFromProcessingQueue(user, token);
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

    function _processSingleToken(address user, address token) internal returns (uint256 savedAmount, bool success) {
        try dailySavingsModule.executeDailySavingsForToken(user, token) returns (uint256 amount) {
            if (amount > 0) {
                emit DailySavingsDetails(user, token, amount);
                return (amount, true);
            }
        } catch Error(string memory reason) {
            emit DailySavingsExecutionFailed(user, token, reason);
        } catch {
            emit DailySavingsExecutionFailed(user, token, "Unknown error");
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
        address token
    ) internal view returns (bool canExecute, uint256 nextExecutionTime, uint256 amountToSave) {
        return dailySavingsModule.getDailyExecutionStatus(user, token);
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
    
    // Public methods to interact with token processing queue
    function getUserProcessingQueueLength(address user) external view returns (uint256) {
        return _tokenProcessingQueues[user].tokenQueue.length;
    }
    
    function getUserProcessingQueueTokens(address user) external view returns (address[] memory) {
        return _tokenProcessingQueues[user].tokenQueue;
    }
    
    function getTokenLastProcessed(address user, address token) external view returns (uint256) {
        return _tokenProcessingQueues[user].lastProcessed[token];
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
}