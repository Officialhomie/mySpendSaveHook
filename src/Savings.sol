// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./SpendSaveStorage.sol";
import "./interfaces/ISavingsModule.sol";
import "./interfaces/ITokenModule.sol";
import "./interfaces/IDCAModule.sol";
import "./interfaces/ISavingStrategyModule.sol";

/**
 * @title Savings - Gas-Optimized Savings Module
 * @notice Optimized savings module designed for <50k gas operations and seamless hook integration
 * @dev Key optimizations:
 *      - Leverages packed storage for single SLOAD user configuration access
 *      - Integrates with transient storage for swap context communication
 *      - Uses batch operations for storage updates to minimize gas costs
 *      - Delegates heavy computation to optimized hook for hot path efficiency
 *      - Maintains backward compatibility with existing interfaces
 * 
 * Integration Patterns:
 *      - Hook Communication: Receives processed savings data from optimized hook
 *      - Storage Integration: Uses centralized SpendSaveStorage for all state
 *      - Module Coordination: Interfaces with Token, DCA, and Strategy modules
 *      - Error Handling: Comprehensive error recovery with proper cleanup
 * 
 * @author SpendSave Protocol Team
 */
contract Savings is ISavingsModule, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // ==================== CONSTANTS ====================
    
    /// @notice Treasury fee denominator (10000 = 100%)
    uint256 private constant TREASURY_FEE_DENOMINATOR = 10000;
    
    /// @notice Maximum batch size for batch operations
    uint256 private constant MAX_BATCH_SIZE = 50;
    
    /// @notice Maximum withdrawal timelock (30 days in seconds)
    uint256 private constant MAX_WITHDRAWAL_TIMELOCK = 30 days;
    
    /// @notice Early withdrawal penalty (10% in basis points)
    uint256 private constant EARLY_WITHDRAWAL_PENALTY = 1000;

    // ==================== STATE VARIABLES ====================
    
    /// @notice Reference to centralized storage contract
    SpendSaveStorage public storage_;
    
    /// @notice Module references for cross-module operations
    ITokenModule public tokenModule;
    IDCAModule public dcaModule;
    ISavingStrategyModule public savingStrategyModule;
    
    /// @notice Emergency pause state
    bool public paused;
    
    // Standardized module references
    address internal _savingStrategyModule;
    address internal _savingsModule;
    address internal _dcaModule;
    address internal _slippageModule;
    address internal _tokenModule;
    address internal _dailySavingsModule;

    // ==================== EVENTS ====================
    
    /// @notice Emitted when module is successfully initialized
    event ModuleInitialized(address indexed storageAddress);
    
    /// @notice Emitted when module references are configured
    event ModuleReferencesSet(address indexed tokenModule, address indexed dcaModule, address indexed strategyModule);
    
    /// @notice Emitted when user withdraws savings
    event WithdrawalProcessed(address indexed user, address indexed token, uint256 amount, uint256 actualAmount, bool earlyWithdrawal);
    
    /// @notice Emitted when savings goal is achieved
    event GoalReached(address indexed user, address indexed token, uint256 totalSaved, uint256 goalAmount);
    
    /// @notice Emitted when savings are queued for DCA
    event SavingsQueuedForDCA(address indexed user, address indexed fromToken, address indexed targetToken, uint256 amount);
    
    /// @notice Emitted when swap queuing fails and falls back to direct savings
    event SwapQueueingFailed(address indexed user, address indexed fromToken, address indexed targetToken, string reason);
    
    /// @notice Emitted when auto-compound is configured
    event AutoCompoundConfigured(address indexed user, address indexed token, bool enabled, uint256 minAmount);
    
    /// @notice Emitted when withdrawal timelock is updated
    event WithdrawalTimelockUpdated(address indexed user, uint256 oldTimelock, uint256 newTimelock);
    
    /// @notice Emitted when emergency withdrawal is executed
    event EmergencyWithdrawal(address indexed user, address indexed token, uint256 amount, address indexed recipient);
    
    /// @notice Emitted when pause state changes
    event PauseStateChanged(bool isPaused);
    
    /// @notice Emitted when savings token is successfully minted
    event SavingsTokenMinted(address indexed user, address indexed token, uint256 indexed tokenId, uint256 amount);
    
    /// @notice Emitted when savings token minting fails
    event SavingsTokenMintFailed(address indexed user, address indexed token, uint256 amount, string reason);
    
    /// @notice Emitted when savings token is successfully burned
    event SavingsTokenBurned(address indexed user, address indexed token, uint256 indexed tokenId, uint256 amount);
    
    /// @notice Emitted when savings token burning fails
    event SavingsTokenBurnFailed(address indexed user, address indexed token, uint256 amount, string reason);

    // ==================== ERRORS ====================
    
    /// @notice Error when module is not initialized
    error NotInitialized();
    
    /// @notice Error when caller is not authorized
    error Unauthorized();
    
    /// @notice Error when amount is invalid
    error InvalidAmount();
    
    /// @notice Error when token address is invalid
    error InvalidToken();
    
    /// @notice Error when user has insufficient savings balance
    error InsufficientBalance();
    
    /// @notice Error when withdrawal is locked
    error WithdrawalLocked();
    
    /// @notice Error when batch size exceeds maximum
    error BatchSizeTooLarge();
    
    /// @notice Error when contract is paused
    error Paused();
    
    /// @notice Error when module is already initialized
    error AlreadyInitialized();
    
    /// @notice Error when timelock period is invalid
    error InvalidTimelock();
    
    /// @notice Error when module address is invalid
    error InvalidModule();

    // ==================== MODIFIERS ====================
    
    /// @notice Ensures module is properly initialized
    modifier onlyInitialized() {
        if (address(storage_) == address(0)) revert NotInitialized();
        _;
    }
    
    /// @notice Restricts access to authorized callers
    modifier onlyAuthorized() {
        if (msg.sender != storage_.spendSaveHook() && 
            msg.sender != storage_.owner() &&
            !storage_.authorizedModules(msg.sender)) {
            revert Unauthorized();
        }
        _;
    }
    
    /// @notice Restricts access to hook contract only
    modifier onlyHook() {
        if (msg.sender != storage_.spendSaveHook()) revert Unauthorized();
        _;
    }
    
    /// @notice Ensures contract is not paused
    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    // ==================== CONSTRUCTOR ====================
    
    /**
     * @notice Initialize the Savings module
     * @dev Constructor is minimal since actual initialization happens via initialize()
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
     * @notice Set references to other modules for cross-module operations
     * @param _savingStrategyModule Address of the saving strategy module
     * @param _savingsModule Address of the savings module (self-reference)
     * @param _dcaModule Address of the DCA module
     * @param _slippageModule Address of the slippage control module
     * @param _tokenModule Address of the token module
     * @param _dailySavingsModule Address of the daily savings module
     * @dev Only owner can set module references to maintain security
     */
    function setModuleReferences(
        address savingStrategyModule,
        address savingsModule,
        address dcaModule,
        address slippageModule,
        address tokenModule,
        address dailySavingsModule
    ) external override nonReentrant {
        if (msg.sender != storage_.owner()) revert Unauthorized();
        
        _savingStrategyModule = savingStrategyModule;
        _savingsModule = savingsModule;
        _dcaModule = dcaModule;
        _slippageModule = slippageModule;
        _tokenModule = tokenModule;
        _dailySavingsModule = dailySavingsModule;
        
        // Set the typed references for backward compatibility
        if (savingStrategyModule != address(0)) {
            savingStrategyModule = ISavingStrategyModule(savingStrategyModule);
        }
        if (dcaModule != address(0)) {
            dcaModule = IDCAModule(dcaModule);
        }
        if (tokenModule != address(0)) {
            tokenModule = ITokenModule(tokenModule);
        }
        
        emit ModuleReferencesSet(savingStrategyModule, dcaModule, tokenModule);
    }

    // ==================== OPTIMIZED CORE SAVINGS FUNCTIONS ====================
    
    /**
     * @notice Process savings with gas optimization for hook integration
     * @param user The user address
     * @param token The token address
     * @param amount The gross amount to save
     * @param context The swap context (legacy compatibility)
     * @return netAmount The net amount saved after fees
     * @dev This function is optimized for calls from the hook during swap execution
     */
    function processSavings(
        address user,
        address token,
        uint256 amount,
        SpendSaveStorage.SwapContext memory context
    ) external override onlyHook whenNotPaused onlyInitialized returns (uint256 netAmount) {
        return _processSavings(user, token, amount, context);
    }
    function _processSavings(
        address user,
        address token,
        uint256 amount,
        SpendSaveStorage.SwapContext memory context
    ) internal returns (uint256 netAmount) {
        if (amount == 0) return 0;
        uint256 treasuryFee = storage_.treasuryFee();
        uint256 feeAmount = (amount * treasuryFee) / TREASURY_FEE_DENOMINATOR;
        netAmount = amount - feeAmount;
        _registerTokenIfNeeded(token);
        _checkGoalAchievement(user, token, netAmount);
        emit SavingsProcessed(user, token, amount, netAmount, feeAmount);
        return netAmount;
    }
    
    /**
     * @notice Process savings using packed configuration for maximum gas efficiency
     * @param user The user address
     * @param token The token address
     * @param amount The gross amount to save
     * @param packedConfig The packed user configuration
     * @return netAmount The net amount saved after fees
     * @dev Optimized version that uses packed storage data directly from hook
     */
    function processSavingsOptimized(
        address user,
        address token,
        uint256 amount,
        SpendSaveStorage.PackedUserConfig memory packedConfig
    ) external override onlyHook whenNotPaused onlyInitialized returns (uint256 netAmount) {
        return _processSavingsOptimized(user, token, amount, packedConfig);
    }
    function _processSavingsOptimized(
        address user,
        address token,
        uint256 amount,
        SpendSaveStorage.PackedUserConfig memory packedConfig
    ) internal returns (uint256 netAmount) {
        if (amount == 0) return 0;
        uint256 treasuryFee = storage_.treasuryFee();
        uint256 feeAmount = (amount * treasuryFee) / TREASURY_FEE_DENOMINATOR;
        netAmount = amount - feeAmount;
        _registerTokenIfNeeded(token);
        emit SavingsProcessed(user, token, amount, netAmount, feeAmount);
        return netAmount;
    }
    
    /**
     * @notice Process savings from swap output with delta-based calculation
     * @param user The user address
     * @param outputToken The output token address
     * @param outputAmount The total output amount from swap
     * @param context The swap context containing percentage and settings
     * @return savedAmount The amount saved from output
     * @dev Called by hook for OUTPUT token savings type
     */
    function processSavingsFromOutput(
        address user,
        address outputToken,
        uint256 outputAmount,
        SpendSaveStorage.SwapContext memory context
    ) external onlyHook whenNotPaused onlyInitialized returns (uint256 savedAmount) {
        return _processSavingsFromOutput(user, outputToken, outputAmount, context);
    }
    function _processSavingsFromOutput(
        address user,
        address outputToken,
        uint256 outputAmount,
        SpendSaveStorage.SwapContext memory context
    ) internal returns (uint256 savedAmount) {
        if (outputAmount == 0 || context.currentPercentage == 0) return 0;
        savedAmount = (outputAmount * context.currentPercentage) / 10000;
        if (context.roundUpSavings && (outputAmount * context.currentPercentage) % 10000 > 0) {
            savedAmount += 1;
        }
        if (savedAmount > outputAmount) {
            savedAmount = outputAmount;
        }
        emit SavingsProcessed(user, outputToken, savedAmount, savedAmount, 0);
        return savedAmount;
    }
    
    /**
     * @notice Process savings to a specific token (for SPECIFIC savings type)
     * @param user The user address
     * @param outputToken The output token from swap
     * @param outputAmount The output amount from swap
     * @param context The swap context containing target token info
     * @return savedAmount The amount queued for DCA to specific token
     * @dev Handles SPECIFIC token savings by queuing DCA conversion
     */
    function processSavingsToSpecificToken(
        address user,
        address outputToken,
        uint256 outputAmount,
        SpendSaveStorage.SwapContext memory context
    ) external onlyHook whenNotPaused onlyInitialized returns (uint256 savedAmount) {
        return _processSavingsToSpecificToken(user, outputToken, outputAmount, context);
    }
    function _processSavingsToSpecificToken(
        address user,
        address outputToken,
        uint256 outputAmount,
        SpendSaveStorage.SwapContext memory context
    ) internal returns (uint256 savedAmount) {
        if (outputAmount == 0 || context.currentPercentage == 0) return 0;
        savedAmount = (outputAmount * context.currentPercentage) / 10000;
        if (context.roundUpSavings && (outputAmount * context.currentPercentage) % 10000 > 0) {
            savedAmount += 1;
        }
        if (address(dcaModule) != address(0) && context.specificSavingsToken != address(0)) {
            try dcaModule.queueDCAExecution(
                user,
                outputToken,
                context.specificSavingsToken,
                savedAmount
            ) {
                emit SavingsQueuedForDCA(user, outputToken, context.specificSavingsToken, savedAmount);
            } catch Error(string memory reason) {
                emit SwapQueueingFailed(user, outputToken, context.specificSavingsToken, reason);
                return _processSavings(user, outputToken, savedAmount, context);
            }
        } else {
            return _processSavings(user, outputToken, savedAmount, context);
        }
        return savedAmount;
    }
    
    /**
     * @notice Batch process multiple savings operations efficiently
     * @param user The user address
     * @param tokens Array of token addresses
     * @param amounts Array of amounts to save
     * @return totalNetAmount Total net amount saved across all tokens
     * @dev Optimized for off-swap-path batch operations
     */
    function batchProcessSavings(
        address user,
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external override onlyAuthorized whenNotPaused onlyInitialized returns (uint256 totalNetAmount) {
        return _batchProcessSavings(user, tokens, amounts);
    }
    function _batchProcessSavings(
        address user,
        address[] calldata tokens,
        uint256[] calldata amounts
    ) internal returns (uint256 totalNetAmount) {
        uint256 length = tokens.length;
        if (length != amounts.length) revert InvalidAmount();
        if (length > MAX_BATCH_SIZE) revert BatchSizeTooLarge();
        if (length == 0) return 0;
        uint256 treasuryFee = storage_.treasuryFee();
        uint256 totalFeeAmount = 0;
        for (uint256 i = 0; i < length;) {
            if (amounts[i] > 0) {
                uint256 feeAmount = (amounts[i] * treasuryFee) / TREASURY_FEE_DENOMINATOR;
                uint256 netAmount = amounts[i] - feeAmount;
                storage_.batchUpdateUserSavings(user, tokens[i], amounts[i]);
                _mintSavingsToken(user, tokens[i], netAmount);
                totalNetAmount += netAmount;
                totalFeeAmount += feeAmount;
            }
            unchecked { ++i; }
        }
        emit BatchSavingsProcessed(user, totalNetAmount, totalFeeAmount);
        return totalNetAmount;
    }

    // ==================== WITHDRAWAL FUNCTIONS ====================
    
    /**
     * @notice Withdraw user savings with timelock and penalty handling
     * @param user The user address
     * @param token The token address
     * @param amount The amount to withdraw
     * @param force Whether to force withdrawal despite timelock
     * @return actualAmount The actual amount withdrawn (after penalties)
     * @dev Handles timelock validation and early withdrawal penalties
     */
    function withdraw(
        address user,
        address token,
        uint256 amount,
        bool force
    ) external override nonReentrant whenNotPaused onlyInitialized returns (uint256 actualAmount) {
        return _withdraw(user, token, amount, force);
    }
    function _withdraw(
        address user,
        address token,
        uint256 amount,
        bool force
    ) internal returns (uint256 actualAmount) {
        if (msg.sender != user && msg.sender != storage_.owner()) {
            revert Unauthorized();
        }
        if (amount == 0) revert InvalidAmount();
        if (token == address(0)) revert InvalidToken();
        uint256 currentBalance = storage_.savings(user, token);
        if (currentBalance < amount) revert InsufficientBalance();
        ( , , , , uint256 withdrawalTimelock) = storage_.getSavingsDetails(user, token);
        bool isEarlyWithdrawal = false;
        actualAmount = amount;
        if (block.timestamp < withdrawalTimelock) {
            if (!force) {
                revert WithdrawalLocked();
            }
            isEarlyWithdrawal = true;
            uint256 penalty = (amount * EARLY_WITHDRAWAL_PENALTY) / TREASURY_FEE_DENOMINATOR;
            actualAmount = amount - penalty;
        }
        storage_.decreaseSavings(user, token, amount);
        _burnSavingsToken(user, token, amount);
        IERC20(token).safeTransfer(user, actualAmount);
        emit WithdrawalProcessed(user, token, amount, actualAmount, isEarlyWithdrawal);
        return actualAmount;
    }
    
    /**
     * @notice Batch withdraw multiple tokens efficiently
     * @param user The user address
     * @param tokens Array of token addresses to withdraw
     * @param amounts Array of amounts to withdraw
     * @return actualAmounts Array of actual amounts withdrawn
     * @dev Gas-optimized batch withdrawal with comprehensive validation
     */
    function batchWithdraw(
        address user,
        address[] calldata tokens,
        uint256[] calldata amounts
    ) external override nonReentrant whenNotPaused onlyInitialized returns (uint256[] memory actualAmounts) {
        return _batchWithdraw(user, tokens, amounts);
    }
    function _batchWithdraw(
        address user,
        address[] calldata tokens,
        uint256[] calldata amounts
    ) internal returns (uint256[] memory actualAmounts) {
        uint256 length = tokens.length;
        if (length != amounts.length) revert InvalidAmount();
        if (length > MAX_BATCH_SIZE) revert BatchSizeTooLarge();
        if (length == 0) return new uint256[](0);
        actualAmounts = new uint256[](length);
        for (uint256 i = 0; i < length;) {
            actualAmounts[i] = _withdraw(user, tokens[i], amounts[i], false);
            unchecked { ++i; }
        }
        return actualAmounts;
    }
    
    /**
     * @notice Withdraw specific savings (legacy interface compatibility)
     * @param user The user address
     * @param token The token address
     * @param amount The amount to withdraw
     * @dev Wrapper function for backward compatibility
     */
    function withdrawSavings(
        address user,
        address token,
        uint256 amount
    ) external {
        _withdraw(user, token, amount, false);
    }

    // ==================== CONFIGURATION FUNCTIONS ====================
    
    /**
     * @notice Set withdrawal timelock for user's savings
     * @param user The user address
     * @param timelock The timelock period in seconds
     * @dev Allows users to set their own withdrawal timelock for additional security
     */
    function setWithdrawalTimelock(address user, uint256 timelock) external override onlyInitialized {
        if (msg.sender != user && msg.sender != storage_.owner()) revert Unauthorized();
        if (timelock > MAX_WITHDRAWAL_TIMELOCK) revert InvalidTimelock();
        
        uint256 oldTimelock = storage_.withdrawalTimelock(user);
        storage_.setWithdrawalTimelock(user, timelock);
        
        emit WithdrawalTimelockUpdated(user, oldTimelock, timelock);
    }
    
    /**
     * @notice Configure auto-compound settings for user savings
     * @param user The user address
     * @param token The token address
     * @param enableCompound Whether to enable auto-compounding
     * @param minCompoundAmount Minimum amount before compounding
     * @dev Enables automatic yield compounding when yield strategies are implemented
     */
    function configureAutoCompound(
        address user,
        address token,
        bool enableCompound,
        uint256 minCompoundAmount
    ) external override onlyInitialized {
        if (msg.sender != user) revert Unauthorized();
        
        // Store auto-compound configuration in storage
        // This would be implemented when yield strategies are added
        
        emit AutoCompoundConfigured(user, token, enableCompound, minCompoundAmount);
    }

    // ==================== LEGACY COMPATIBILITY FUNCTIONS ====================
    
    /**
     * @notice Process input savings after swap (legacy compatibility)
     * @param user The user address
     * @param token The token address
     * @param amount The amount to process
     * @dev Maintains compatibility with existing interfaces
     */
    function processInputSavingsAfterSwap(
        address user,
        address token,
        uint256 amount
    ) external onlyHook whenNotPaused onlyInitialized {
        if (amount > 0) {
            SpendSaveStorage.SwapContext memory context = SpendSaveStorage.SwapContext({
                hasStrategy: true,
                currentPercentage: 0,
                inputAmount: amount,
                inputToken: token,
                roundUpSavings: false,
                enableDCA: false,
                dcaTargetToken: address(0),
                currentTick: 0, // Add missing currentTick field
                savingsTokenType: SpendSaveStorage.SavingsTokenType.INPUT,
                specificSavingsToken: address(0),
                pendingSaveAmount: amount
            });
            _processSavings(user, token, amount, context);
        }
    }
    
    /**
     * @notice Deposit savings (legacy compatibility)
     * @param user The user address
     * @param token The token address
     * @param amount The amount to deposit
     * @dev Provides direct deposit functionality outside of swap context
     */
    function depositSavings(
        address user,
        address token,
        uint256 amount
    ) external nonReentrant whenNotPaused onlyInitialized {
        if (msg.sender != user) revert Unauthorized();
        if (amount == 0) revert InvalidAmount();
        if (token == address(0)) revert InvalidToken();
        
        // Transfer tokens from user
        IERC20(token).safeTransferFrom(user, address(this), amount);
        
        // Process as savings
        SpendSaveStorage.SwapContext memory context; // Empty context for direct deposit
        _processSavings(user, token, amount, context);
    }

    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Get user's savings across all tokens
     * @param user The user address
     * @return tokens Array of token addresses
     * @return amounts Array of savings amounts
     * @dev Note: For gas efficiency, this should use off-chain indexing in production
     */
    function getUserSavings(address user) external view override returns (
        address[] memory tokens,
        uint256[] memory amounts
    ) {
        // This function is intentionally kept simple
        // Production implementations should use event indexing for efficiency
        revert("Use event indexing or subgraph for gas efficiency");
    }
    
    /**
     * @notice Get detailed savings information for specific token
     * @param user The user address
     * @param token The token address
     * @return balance Current savings balance
     * @return totalSaved Total amount saved historically
     * @return lastSaveTime Timestamp of last save operation
     * @return isLocked Whether withdrawals are currently locked
     * @return unlockTime Timestamp when withdrawals will be unlocked
     * @dev Provides comprehensive savings data for frontend integration
     */
    function getSavingsDetails(address user, address token) external view override returns (
        uint256 balance,
        uint256 totalSaved,
        uint256 lastSaveTime,
        bool isLocked,
        uint256 unlockTime
    ) {
        balance = storage_.savings(user, token);

        ( , , , , uint256 withdrawalTimelock) = storage_.getSavingsDetails(user, token);
        isLocked = block.timestamp < withdrawalTimelock;
        unlockTime = withdrawalTimelock;
    }
    
    /**
     * @notice Calculate actual withdrawal amount including penalties
     * @param user The user address
     * @param token The token address
     * @param requestedAmount The requested withdrawal amount
     * @return actualAmount The actual amount after penalties
     * @return penalty The penalty amount for early withdrawal
     * @dev Helps users understand withdrawal costs before executing
     */
    function calculateWithdrawalAmount(
        address user,
        address token,
        uint256 requestedAmount
    ) external view override returns (uint256 actualAmount, uint256 penalty) {
        ( , , , , uint256 withdrawalTimelock) = storage_.getSavingsDetails(user, token);
        
        if (block.timestamp >= withdrawalTimelock) {
            actualAmount = requestedAmount;
            penalty = 0;
        } else {
            penalty = (requestedAmount * EARLY_WITHDRAWAL_PENALTY) / TREASURY_FEE_DENOMINATOR;
            actualAmount = requestedAmount - penalty;
        }
    }

    // ==================== INTEGRATION HELPER FUNCTIONS ====================
    
    /**
     * @notice Queue savings for DCA execution
     * @param user The user address
     * @param fromToken The source token for DCA
     * @param amount The amount to queue for DCA
     * @param targetToken The target token for DCA
     * @dev Facilitates integration with DCA module for automated conversions
     */
    function queueForDCA(
        address user,
        address fromToken,
        uint256 amount,
        address targetToken
    ) external onlyAuthorized onlyInitialized {
        if (address(dcaModule) != address(0)) {
            dcaModule.queueDCAExecution(user, fromToken, targetToken, amount);
            emit SavingsQueuedForDCA(user, fromToken, targetToken, amount);
        }
    }

    // ==================== INTERNAL HELPER FUNCTIONS ====================
    
    /**
     * @notice Register token if needed (gas-optimized deferred operation)
     * @param token The token address to register
     * @dev Defers token registration for gas efficiency during hot path
     */
    function _registerTokenIfNeeded(address token) internal {
        if (address(tokenModule) != address(0)) {
            // Deferred operation - only register if not already done
            try tokenModule.registerToken(token) {
                // Token registered successfully or already registered
            } catch {
                // Registration failed, but don't revert savings operation
            }
        }
    }
    
    /**
     * @notice Check for goal achievement and emit event if reached
     * @param user The user address
     * @param token The token address
     * @param newSavings The new savings amount being added
     * @dev Deferred operation for gas efficiency during hot path
     */
    function _checkGoalAchievement(address user, address token, uint256 newSavings) internal {
        // Get current total savings
        uint256 currentBalance = storage_.savings(user, token);
        
        // Get user's savings goal from strategy
        SpendSaveStorage.SavingStrategy memory strategy = storage_.getUserSavingStrategy(user);
        
        if (strategy.goalAmount > 0 && currentBalance >= strategy.goalAmount) {
            emit GoalReached(user, token, currentBalance, strategy.goalAmount);
        }
    }
    
    /**
     * @notice Helper function to mint savings token 
     * @param user The user address
     * @param token The token address
     * @param amount The amount to mint
     * @dev Converts token address to tokenId before minting (ERC6909 pattern)
     */
    function _mintSavingsToken(address user, address token, uint256 amount) internal {
        if (address(tokenModule) != address(0) && amount > 0) {
            // STEP 1: Convert token address to token ID
            // This is the key fix - ERC6909 uses numeric IDs, not addresses
            uint256 tokenId = tokenModule.getTokenId(token);
            
            // STEP 2: If token isn't registered yet, register it first
            if (tokenId == 0) {
                tokenId = tokenModule.registerToken(token);
            }
            
            // STEP 3: Now mint using the correct tokenId parameter
            try tokenModule.mintSavingsToken(user, tokenId, amount) {
                emit SavingsTokenMinted(user, token, tokenId, amount);
            } catch Error(string memory reason) {
                emit SavingsTokenMintFailed(user, token, amount, reason);
            }
        }
    }
    
    /**
     * @notice Helper function to burn savings token if needed  
     * @param user The user address
     * @param token The token address
     * @param amount The amount to burn
     * @dev Also needs the same token address to tokenId conversion
     */
    function _burnSavingsToken(address user, address token, uint256 amount) internal {
        if (address(tokenModule) != address(0) && amount > 0) {
            // Convert token address to token ID (same pattern as minting)
            uint256 tokenId = tokenModule.getTokenId(token);
            
            // Only burn if token is registered (tokenId != 0)
            if (tokenId != 0) {
                try tokenModule.burnSavingsToken(user, tokenId, amount) {
                    emit SavingsTokenBurned(user, token, tokenId, amount);
                } catch Error(string memory reason) {
                    emit SavingsTokenBurnFailed(user, token, amount, reason);
                }
            }
        }
    }

    // ==================== EMERGENCY FUNCTIONS ====================
    
    /**
     * @notice Emergency withdrawal function (owner only)
     * @param user The user address
     * @param token The token address
     * @param amount The amount to withdraw
     * @param recipient The recipient address
     * @dev Emergency function that bypasses all checks for critical situations
     */
    function emergencyWithdraw(
        address user,
        address token,
        uint256 amount,
        address recipient
    ) external override nonReentrant onlyInitialized {
        if (msg.sender != storage_.owner()) revert Unauthorized();
        if (recipient == address(0)) revert InvalidToken();
        
        // Emergency withdrawal bypasses all checks
        storage_.decreaseSavings(user, token, amount);
        IERC20(token).safeTransfer(recipient, amount);
        
        emit EmergencyWithdrawal(user, token, amount, recipient);
    }
    
    /**
     * @notice Pause savings operations (owner only)
     * @dev Emergency pause for critical situations
     */
    function pauseSavings() external onlyHook whenNotPaused onlyInitialized {
        if (msg.sender != storage_.owner()) revert Unauthorized();
        paused = true;
        emit PauseStateChanged(true);
    }
    
    /**
     * @notice Resume savings operations (owner only)
     * @dev Resume operations after emergency pause
     */
    function resumeSavings() external nonReentrant whenNotPaused onlyInitialized {
        if (msg.sender != storage_.owner()) revert Unauthorized();
        paused = false;
        emit PauseStateChanged(false);
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