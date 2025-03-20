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

import "./SpendSaveStorage.sol";
import "./ISavingStrategyModule.sol";
import "./ISavingsModule.sol";
import "./IDCAModule.sol";
import "./ISlippageControlModule.sol";
import "./ITokenModule.sol";
import "./IDailySavingsModule.sol";

/**
 * @title SpendSaveHook
 * @dev Main contract that implements Uniswap V4 hooks and coordinates between modules
 */
contract SpendSaveHook is BaseHook {
    // Storage contract reference
    SpendSaveStorage public immutable storage_;
    
    // Module references
    ISavingStrategyModule public savingStrategyModule;
    ISavingsModule public savingsModule;
    IDCAModule public dcaModule;
    ISlippageControlModule public slippageControlModule;
    ITokenModule public tokenModule;
    IDailySavingsModule public dailySavingsModule;
    
    // Error definitions
    error ModuleNotInitialized(string moduleName);
    error InsufficientGas(uint256 available, uint256 required);
    error UnauthorizedAccess(address caller);
    
    // Events
    event DailySavingsExecuted(address indexed user, uint256 totalAmount);
    event DailySavingsExecutionFailed(address indexed user, address indexed token, string reason);
    event SingleTokenSavingsExecuted(address indexed user, address indexed token, uint256 amount);
    event ModulesInitialized(address strategyModule, address savingsModule, address dcaModule, address slippageModule, address tokenModule, address dailySavingsModule);
    
    // Gas configuration for daily savings
    uint256 private constant GAS_THRESHOLD = 500000;
    uint256 private constant INITIAL_GAS_PER_TOKEN = 150000;
    uint256 private constant MIN_GAS_TO_KEEP = 100000;

    struct DailySavingsProcessor {
        address[] tokens;
        uint256 gasLimit;
        uint256 totalSaved;
        uint256 minGasReserve;
    }
    
    constructor(
        IPoolManager _poolManager,
        SpendSaveStorage _storage
    ) BaseHook(_poolManager) {
        storage_ = _storage;
        
        // Register this contract with storage
        // _storage.setSpendSaveHook(address(this));
    }
    
    // Initialize modules - this should be called after all modules are deployed
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
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }
    
    // Verify all modules are initialized
    function _checkModulesInitialized() internal view {
        if (address(savingStrategyModule) == address(0)) revert ModuleNotInitialized("SavingStrategy");
        if (address(savingsModule) == address(0)) revert ModuleNotInitialized("Savings");
        if (address(dcaModule) == address(0)) revert ModuleNotInitialized("DCA");
        if (address(slippageControlModule) == address(0)) revert ModuleNotInitialized("SlippageControl");
        if (address(tokenModule) == address(0)) revert ModuleNotInitialized("Token");
    }
    
    // Hook into beforeSwap to capture swap details and prepare for savings
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        _checkModulesInitialized();
        
        // Let strategy module handle beforeSwap logic
        savingStrategyModule.beforeSwap(sender, key, params);
        
        return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    // Process savings based on token type - split into smaller functions
    function _processSavingsBasedOnType(
        address sender,
        SpendSaveStorage.SwapContext memory context,
        PoolKey calldata key,
        BalanceDelta delta
    ) internal {
        if (context.savingsTokenType == SpendSaveStorage.SavingsTokenType.INPUT) {
            // For INPUT token type, savings were already processed in beforeSwap
            savingStrategyModule.updateSavingStrategy(sender, context);
        } else {
            _processNonInputSavings(sender, context, key, delta);
        }
    }

    function _processNonInputSavings(
        address sender,
        SpendSaveStorage.SwapContext memory context,
        PoolKey calldata key,
        BalanceDelta delta
    ) internal {
        // Get output token and amount
        (address outputToken, uint256 outputAmount) = _getOutputTokenAndAmount(key, delta);
        
        // Skip if no positive output
        if (outputAmount == 0) return;
        
        // Handle different savings token types
        if (context.savingsTokenType == SpendSaveStorage.SavingsTokenType.OUTPUT) {
            _processOutputTokenSavings(sender, context, outputToken, outputAmount);
        } else if (context.savingsTokenType == SpendSaveStorage.SavingsTokenType.SPECIFIC) {
            _processSpecificTokenSavings(sender, context, outputToken, outputAmount);
        }
        
        // Update saving strategy if using auto-increment
        savingStrategyModule.updateSavingStrategy(sender, context);
    }

    // Helper for output token savings
    function _processOutputTokenSavings(
        address sender,
        SpendSaveStorage.SwapContext memory context,
        address outputToken,
        uint256 outputAmount
    ) internal {
        // Process savings from output token
        savingsModule.processSavingsFromOutput(sender, outputToken, outputAmount, context);
        
        // Handle DCA if enabled
        _processDCAIfEnabled(sender, context, outputToken);
    }

    // Helper for specific token savings
    function _processSpecificTokenSavings(
        address sender,
        SpendSaveStorage.SwapContext memory context,
        address outputToken,
        uint256 outputAmount
    ) internal {
        // Process savings to specific token
        savingsModule.processSavingsToSpecificToken(sender, outputToken, outputAmount, context);
    }

    // Helper function to handle DCA processing
    function _processDCAIfEnabled(
        address sender,
        SpendSaveStorage.SwapContext memory context,
        address outputToken
    ) internal {
        bool shouldProcessDCA = context.enableDCA && 
                               context.dcaTargetToken != address(0) && 
                               outputToken != context.dcaTargetToken;
                               
        if (shouldProcessDCA) {
            dcaModule.queueDCAFromSwap(sender, outputToken, context);
        }
    }

    // Hook into afterSwap to process savings and check for daily savings
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        _checkModulesInitialized();
        
        // Get current swap context from storage
        SpendSaveStorage.SwapContext memory context = storage_.getSwapContext(sender);
        
        // Only proceed if user has a saving strategy
        if (context.hasStrategy) {
            _processSavingsBasedOnType(sender, context, key, delta);
            storage_.deleteSwapContext(sender);
        }
        
        // Check for daily savings after processing swap-based savings
        _tryProcessDailySavings(sender);
        
        return (IHooks.afterSwap.selector, 0);
    }

    function _tryProcessDailySavings(address user) internal {
        // Exit early if conditions aren't met
        if (!_shouldProcessDailySavings(user)) return;
        
        // Process each token with a gas-efficient approach
        DailySavingsProcessor memory processor = _initDailySavingsProcessor(user);
        _processDailySavingsForAllTokens(user, processor);
    }

    function _shouldProcessDailySavings(address user) internal view returns (bool) {
        // Only proceed if there are pending daily savings and we have enough gas
        return _hasPendingDailySavings(user) && gasleft() > GAS_THRESHOLD;
    }

    function _processDailySavingsForAllTokens(
        address user, 
        DailySavingsProcessor memory processor
    ) internal {
        uint256 tokenCount = processor.tokens.length;
        
        for (uint256 i = 0; i < tokenCount; i++) {
            // Stop if we're running low on gas
            if (gasleft() < processor.gasLimit + processor.minGasReserve) break;
            
            address token = processor.tokens[i];
            uint256 gasStart = gasleft();
            
            (uint256 savedAmount, bool success) = _processSingleToken(user, token);
            processor.totalSaved += savedAmount;
            
            // Adjust gas estimate based on actual usage
            uint256 gasUsed = gasStart - gasleft();
            processor.gasLimit = _adjustGasLimit(processor.gasLimit, gasUsed);
        }
        
        if (processor.totalSaved > 0) {
            emit DailySavingsExecuted(user, processor.totalSaved);
        }
    }

    function _adjustGasLimit(
        uint256 currentLimit, 
        uint256 actualUsage
    ) internal pure returns (uint256) {
        // If actual usage was higher, adjust upward (with dampening)
        if (actualUsage > currentLimit) {
            return (currentLimit + actualUsage) / 2;
        }
        return currentLimit;
    }

    function _processSingleToken(address user, address token) internal returns (uint256 savedAmount, bool success) {
        try dailySavingsModule.executeDailySavingsForToken(user, token) returns (uint256 amount) {
            if (amount > 0) {
                emit SingleTokenSavingsExecuted(user, token, amount);
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
        address user
    ) internal view returns (DailySavingsProcessor memory) {
        return DailySavingsProcessor({
            tokens: storage_.getUserSavingsTokens(user),
            gasLimit: INITIAL_GAS_PER_TOKEN,
            totalSaved: 0,
            minGasReserve: MIN_GAS_TO_KEEP
        });
    }

    
    // Helper for input token savings
    function _handleInputTokenSavings(
        address sender, 
        SpendSaveStorage.SwapContext memory context
    ) internal {
        // For INPUT token type, savings were already processed in beforeSwap
        // Just update the saving strategy
        savingStrategyModule.updateSavingStrategy(sender, context);
    }
    
    // Helper for non-input token savings
    function _handleNonInputTokenSavings(
        address sender,
        SpendSaveStorage.SwapContext memory context,
        PoolKey calldata key,
        BalanceDelta delta
    ) internal {
        // Process the savings based on swap output
        // Extract output token and amount from delta
        (address outputToken, uint256 outputAmount) = _getOutputTokenAndAmount(key, delta);
        
        // Skip if no positive output
        if (outputAmount == 0) return;
        
        // Process savings based on token type
        _processSavingsBasedOnType(sender, context, key, delta);
        
        // Update saving strategy if using auto-increment
        savingStrategyModule.updateSavingStrategy(sender, context);
    }
    
    // Wrapper function to avoid variable stack issues
    function _checkAndProcessDailySavings(address user) internal {
        _tryExecuteDailySavings(user);
    }

    // Helper function to process a single token for daily savings
    function _processDailySavingForToken(
        address user,
        address token
    ) internal returns (uint256 savedAmount, uint256 gasUsed) {
        savedAmount = 0;
        gasUsed = 0;
        
        // Check if this token has pending daily savings
        (bool canExecute, , uint256 amountToSave) = _getDailyExecutionStatus(user, token);
        
        if (canExecute && amountToSave > 0) {
            // Set a gas limit for this specific token execution
            uint256 tokenGasStart = gasleft();
            
            // Try to execute daily savings and handle any errors
            (savedAmount, gasUsed) = _executeDailySavingsWithErrorHandling(user, token, tokenGasStart);
        }
        
        return (savedAmount, gasUsed);
    }

    // Helper to get daily execution status
    function _getDailyExecutionStatus(
        address user,
        address token
    ) internal view returns (bool canExecute, uint256 nextExecutionTime, uint256 amountToSave) {
        return dailySavingsModule.getDailyExecutionStatus(user, token);
    }

    // Helper to execute daily savings with error handling
    function _executeDailySavingsWithErrorHandling(
        address user,
        address token,
        uint256 tokenGasStart
    ) internal returns (uint256 savedAmount, uint256 gasUsed) {
        savedAmount = 0;
        
        try dailySavingsModule.executeDailySavingsForToken(user, token) returns (uint256 _savedAmount) {
            if (_savedAmount > 0) {
                savedAmount = _savedAmount;
                
                // Emit per-token event if needed
                emit SingleTokenSavingsExecuted(user, token, _savedAmount);
            }
        } catch Error(string memory reason) {
            // Log the error but continue with other tokens
            emit DailySavingsExecutionFailed(user, token, reason);
        } catch {
            // Handle any other exceptions
            emit DailySavingsExecutionFailed(user, token, "Unknown error");
        }
        
        // Calculate gas used
        gasUsed = tokenGasStart - gasleft();
        
        return (savedAmount, gasUsed);
    }

    // Check if there are pending daily savings
    function _hasPendingDailySavings(address user) internal view returns (bool) {
        // First, check if the module is initialized
        if (address(dailySavingsModule) == address(0)) return false;
        
        return dailySavingsModule.hasPendingDailySavings(user);
    }

    // Check if we have enough gas to execute daily savings
    function _hasEnoughGasForDailySavings() internal view returns (bool) {
        uint256 gasStart = gasleft();
        return gasStart > GAS_THRESHOLD;
    }

    // Get user's savings tokens
    function _getUserSavingsTokens(address user) internal view returns (address[] memory) {
        return storage_.getUserSavingsTokens(user);
    }

    // Helper function to efficiently handle daily savings execution
    function _tryExecuteDailySavings(address user) internal {
        // Only proceed if there are pending daily savings and we have enough gas
        if (!_hasPendingDailySavings(user) || !_hasEnoughGasForDailySavings()) return;
        
        // Process daily savings for each token
        _executeDailySavingsForTokens(user);
    }

    // Process daily savings for all user tokens
    function _executeDailySavingsForTokens(address user) internal {
        // Get user's savings tokens
        address[] memory tokens = _getUserSavingsTokens(user);
        
        // Set initial gas parameters
        uint256 gasPerTokenLimit = INITIAL_GAS_PER_TOKEN;
        uint256 totalSaved = 0;
        
        // Process each token
        (totalSaved, ) = _processDailySavingsLoop(user, tokens, gasPerTokenLimit);
        
        // Emit event if any savings were executed
        if (totalSaved > 0) {
            emit DailySavingsExecuted(user, totalSaved);
        }
    }

    // Process daily savings loop for all tokens
    function _processDailySavingsLoop(
        address user,
        address[] memory tokens,
        uint256 gasPerTokenLimit
    ) internal returns (uint256 totalSaved, uint256 adjustedGasLimit) {
        totalSaved = 0;
        adjustedGasLimit = gasPerTokenLimit;
        
        for (uint256 i = 0; i < tokens.length; i++) {
            // Check if we still have enough gas to process another token
            if (!_hasEnoughGasForToken(adjustedGasLimit)) break;
            
            address token = tokens[i];
            
            // Process this token using the helper
            (uint256 savedAmount, uint256 gasUsed) = _processDailySavingForToken(user, token);
            
            totalSaved += savedAmount;
            
            // Update our gas estimate if needed
            if (gasUsed > adjustedGasLimit) {
                // We might want to adjust our estimate for future calls
                adjustedGasLimit = (adjustedGasLimit + gasUsed) / 2;
            }
        }
        
        return (totalSaved, adjustedGasLimit);
    }

    // Check if we have enough gas for processing another token
    function _hasEnoughGasForToken(uint256 gasPerTokenLimit) internal view returns (bool) {
        uint256 currentGas = gasleft();
        return currentGas >= MIN_GAS_TO_KEEP + gasPerTokenLimit;
    }

    // Helper function to get output token and amount from swap delta
    function _getOutputTokenAndAmount(
        PoolKey calldata key, 
        BalanceDelta delta
    ) private pure returns (address outputToken, uint256 outputAmount) {
        int256 amount0 = delta.amount0();
        int256 amount1 = delta.amount1();
        
        if (amount0 > 0) {
            return (Currency.unwrap(key.currency0), uint256(amount0));
        } else if (amount1 > 0) {
            return (Currency.unwrap(key.currency1), uint256(amount1));
        }
        return (address(0), 0);
    }
    
    // Callback function to receive tokens from the PoolManager
    function lockAcquired(
        bytes calldata data
    ) external returns (bytes memory) {
        return abi.encode(poolManager.unlock.selector);
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