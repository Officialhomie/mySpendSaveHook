// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {ReentrancyGuard} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/ITokenModule.sol";
import {ERC6909} from "lib/v4-periphery/lib/v4-core/lib/solmate/src/tokens/ERC6909.sol";
import {IHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {PoolId} from "lib/v4-periphery/lib/v4-core/src/types/PoolId.sol";
/**
 * @title SpendSaveStorage - Optimized Centralized Storage with Gas-Efficient Packed Storage
 * @notice Centralized storage contract serving as the single source of truth for all SpendSave protocol state
 * @dev Key optimizations:
 * - Packed storage structs to minimize SLOAD/SSTORE operations
 * - Transient storage for temporary swap context (EIP-1153 compatible)
 * - Batch operations for multiple state updates
 * - Module registry system for efficient address lookup
 * - Complete ERC6909 multi-token standard implementation
 * @author SpendSave Protocol Team
 */
contract SpendSaveStorage is ERC6909, ReentrancyGuard {

    // ==================== CONSTANTS ====================
    
    /// @notice Default fee tier for pool creation (0.3%)
    uint24 private constant DEFAULT_FEE_TIER = 3000;
    
    /// @notice Default tick spacing for pool creation
    int24 private constant DEFAULT_TICK_SPACING = 60;

    // ==================== PACKED STORAGE OPTIMIZATION STRUCTS ====================
    
    /**
     * @notice Packed user configuration optimized for single storage slot access
     * @dev Layout fits exactly in 256 bits for gas efficiency:
     * - percentage: 16 bits (0-65535, supports 0-655.35% with precision)
     * - autoIncrement: 16 bits (auto-increment value in basis points)
     * - maxPercentage: 16 bits (maximum percentage cap)
     * - roundUpSavings: 8 bits (boolean flag for rounding up)
     * - enableDCA: 8 bits (boolean flag for DCA enable)
     * - savingsTokenType: 8 bits (enum: INPUT, OUTPUT, SPECIFIC)
     * - reserved: 184 bits (future expansion space)
     */
    struct PackedUserConfig {
        uint16 percentage;        // Savings percentage in basis points (0-10000)
        uint16 autoIncrement;     // Auto-increment value in basis points
        uint16 maxPercentage;     // Maximum percentage cap in basis points
        uint8 roundUpSavings;     // Round up flag (0 or 1)
        uint8 enableDCA;          // DCA enabled flag (0 or 1)
        uint8 savingsTokenType;   // Token type: 0=INPUT, 1=OUTPUT, 2=SPECIFIC
        uint184 reserved;         // Reserved for future use
    }
    
    /**
     * @notice Packed swap context for transient storage optimization
     * @dev Used for efficient communication between beforeSwap and afterSwap
     * Designed to minimize gas costs during swap execution
     */
    struct PackedSwapContext {
        uint128 pendingSaveAmount;    // Amount pending to be saved (128 bits sufficient for most tokens)
        uint16 currentPercentage;     // Active percentage for this specific swap
        uint8 hasStrategy;            // Strategy active flag (0 or 1)
        uint8 savingsTokenType;       // Token type for this swap
        uint8 roundUpSavings;         // Round up flag for this swap
        uint8 enableDCA;              // DCA flag for this swap
        uint96 reserved;              // Future expansion space
    }

    // ==================== CORE STATE VARIABLES ====================
    
    /// @notice Immutable reference to Uniswap V4 pool manager
    address public immutable poolManager;
    
    /// @notice Core protocol contract addresses
    address public spendSaveHook;
    address public owner;
    address public treasury;
    
    /// @notice Treasury fee in basis points (0-10000, where 10000 = 100%)
    uint256 public treasuryFee;

    // ==================== OPTIMIZED STORAGE MAPPINGS ====================
    
    /// @notice Packed user configurations for gas-efficient access
    mapping(address => PackedUserConfig) private _packedUserConfigs;
    
    /// @notice User savings balances by token address (user => token => amount)
    mapping(address => mapping(address => uint256)) public _savings;
    
    /// @notice Specific savings token per user (for SPECIFIC token type)
    mapping(address => address) public specificSavingsToken;
    
    /// @notice Savings goals per user
    mapping(address => uint256) public savingsGoals;

    /// @notice Daily savings amounts per user per token
    mapping(address => mapping(address => uint256)) public dailySavingsAmounts;

    /// @notice Daily savings configuration parameters per user per token  
    mapping(address => mapping(address => DailySavingsConfigParams)) public dailySavingsConfigParams;
    
    /// @notice Transient storage for swap contexts (EIP-1153 compatible)
    mapping(address => PackedSwapContext) private _transientSwapContexts;

    // ==================== MODULE MANAGEMENT ====================
    
    /// @notice Authorized modules for access control
    mapping(address => bool) public authorizedModules;
    
    /// @notice Module registry for efficient lookup by ID
    mapping(bytes32 => address) public moduleRegistry;

    // ==================== ERC6909 TOKEN IMPLEMENTATION ====================
    
    /// @notice ERC6909 balances mapping (owner => id => balance)
    mapping(address => mapping(uint256 => uint256)) private _balances;
    
    /// @notice ERC6909 allowances mapping (owner => spender => id => allowance)
    mapping(address => mapping(address => mapping(uint256 => uint256))) private _allowances;
    
    /// @notice Token information storage
    mapping(address => TokenInfo) private _tokenInfo;
    
    /// @notice Token ID to address mapping
    mapping(uint256 => address) private _tokenIdToAddress;
    
    /// @notice Address to token ID mapping
    mapping(address => uint256) private _tokenToId;
    
    /// @notice Next available token ID counter
    uint256 private _nextTokenId = 1;

    // ==================== COMPREHENSIVE DATA STRUCTURES ====================
    
    // LEGACY - Removed:
    // mapping(address => SavingStrategy) public userSavingStrategies;
    // mapping(address => SwapContext) private _swapContexts;
    // mapping(address => DCAQueue) public dcaQueues;
    // mapping(address => mapping(uint256 => DCAExecution)) public dcaExecutions;
    // mapping(address => DailySavingsConfig) public dailySavingsConfigs;
    
    /// @notice User slippage tolerance settings
    mapping(address => uint256) public userSlippageTolerance;

    
    /// @notice Token-specific slippage tolerance
    mapping(address => mapping(address => uint256)) public tokenSlippageTolerance;
    
    /// @notice Slippage exceeded action per user
    mapping(address => SlippageAction) public slippageExceededAction;
    
    /// @notice Default slippage tolerance
    uint256 public defaultSlippageTolerance;
    
    /// @notice Daily savings configuration per user
    mapping(address => DailySavingsConfig) public dailySavingsConfigs;
    
    /// @notice Daily execution records
    mapping(address => mapping(address => DailySavingsExecution)) public dailyExecutions;
    
    /// @notice Pool keys for trading pair management
    mapping(bytes32 => PoolKey) private _poolKeys;
    
    /// @notice Pool initialization status
    mapping(bytes32 => bool) public poolInitialized;

    // Add new mappings to track totalSaved and lastSaveTime for each user/token
    mapping(address => mapping(address => uint256)) public totalSaved;
    mapping(address => mapping(address => uint256)) public lastSaveTime;

    // Add mapping for withdrawal timelock if not present
    mapping(address => uint256) public withdrawalTimelock;

    /// @notice User withdrawal timelock timestamps
    mapping(address => uint256) public userWithdrawalTimelocks;

    /// @notice DCA Queue for users
    mapping(address => DCAQueue) public dcaQueues;

    // ==================== DCA MANAGEMENT MAPPINGS ====================
    
    /// @notice DCA tick strategies per user
    mapping(address => DCATickStrategy) public dcaTickStrategies;
    
    /// @notice DCA target tokens per user
    mapping(address => address) public dcaTargetTokens;
    
    /// @notice Enhanced DCA queues with detailed information
    mapping(address => EnhancedDCAQueue) private enhancedDcaQueues;
    
    /// @notice Pool ticks for price tracking
    mapping(PoolId => int24) private _poolTicks;

    // ==================== ENUMS AND STRUCTS ====================
    
    /// @notice Token types for savings strategy
    enum SavingsTokenType { INPUT, OUTPUT, SPECIFIC }
    
    /// @notice Yield strategy options
    enum YieldStrategy { NONE, COMPOUND, AAVE, COMPOUND_V3 }
    
    /// @notice Slippage exceeded actions
    enum SlippageAction { REVERT, SKIP, REDUCE }

    /// @notice Daily savings configuration parameters
    struct DailySavingsConfigParams {
        bool enabled;             // Configuration enabled status
        uint256 goalAmount;       // Target goal amount
        uint256 currentAmount;    // Current accumulated amount
        uint256 penaltyBps;       // Penalty in basis points
        uint256 endTime;          // End time for the savings period
    }
    
    /// @notice Token information structure
    struct TokenInfo {
        uint256 tokenId;          // ERC6909 token ID
        bool isRegistered;        // Registration status
    }
    
    /// @notice Complete saving strategy configuration
    struct SavingStrategy {
        uint256 percentage;                    // Savings percentage (0-10000)
        uint256 autoIncrement;                 // Auto increment value
        uint256 maxPercentage;                 // Maximum percentage cap
        uint256 goalAmount;                    // Savings goal amount
        bool roundUpSavings;                   // Round up flag
        bool enableDCA;                        // DCA enabled flag
        SavingsTokenType savingsTokenType;     // Token type for savings
        address specificSavingsToken;          // Specific token address (if applicable)
    }
    
    /// @notice Swap context for transaction processing
    struct SwapContext {
        bool hasStrategy;                      // Strategy exists flag
        uint256 currentPercentage;             // Current active percentage
        uint256 inputAmount;                   // Input amount for swap
        address inputToken;                    // Input token address
        bool roundUpSavings;                   // Round up flag
        bool enableDCA;                        // DCA enabled flag
        address dcaTargetToken;                // DCA target token
        int24 currentTick;                     // Current pool tick
        SavingsTokenType savingsTokenType;     // Savings token type
        address specificSavingsToken;          // Specific savings token
        uint256 pendingSaveAmount;             // Pending save amount
    }
    
    /// @notice DCA queue structure
    struct DCAQueue {
        uint256[] amounts;        // Amounts to DCA
        address[] tokens;         // Target tokens
        uint256[] executionTimes; // Execution timestamps
        bool isActive;            // Queue active status
    }
    
    /// @notice DCA execution record
    struct DCAExecution {
        uint256 amount;           // Executed amount
        address token;            // Target token
        uint256 executionTime;    // Execution timestamp
        uint256 price;            // Execution price
        bool successful;          // Execution success flag
    }
    
    /// @notice Daily savings configuration
    struct DailySavingsConfig {
        uint256 dailyAmount;      // Daily savings amount
        address[] tokens;         // Target tokens
        uint256 lastExecution;    // Last execution timestamp
        bool isActive;            // Configuration active status
    }
    
    /// @notice Daily savings execution record
    struct DailySavingsExecution {
        uint256 amount;           // Executed amount
        uint256 timestamp;        // Execution timestamp
        bool successful;          // Execution success flag
    }

    // ==================== DCA STRUCTURES ====================
    
    /// @notice DCA tick strategy configuration
    struct DCATickStrategy {
        int24 tickDelta;              // Tick movement threshold
        uint256 tickExpiryTime;       // Strategy expiry timestamp
        bool onlyImprovePrice;        // Only execute on price improvement
        int24 minTickImprovement;     // Minimum tick improvement required
        bool dynamicSizing;           // Enable dynamic DCA sizing
        uint256 customSlippageTolerance; // Custom slippage tolerance
    }
    
    /// @notice DCA queue item with detailed information
    struct DCAQueueItem {
        address fromToken;            // Source token
        address toToken;              // Target token
        uint256 amount;               // DCA amount
        int24 executionTick;          // Target execution tick
        uint256 deadline;             // Execution deadline
        uint256 customSlippageTolerance; // Custom slippage
        bool executed;                // Execution status
    }
    
    /// @notice Enhanced DCA queue with detailed tracking
    struct EnhancedDCAQueue {
        DCAQueueItem[] items;         // Queue items
        mapping(uint256 => bool) executed; // Execution tracking
        bool isActive;                // Queue active status
    }

    // ==================== EVENTS ====================
    
    /// @notice Emitted when storage is initialized
    event StorageInitialized(address indexed poolManager, address indexed spendSaveHook);
    
    /// @notice Emitted when user configuration is updated
    event UserConfigUpdated(address indexed user, PackedUserConfig config);
    
    /// @notice Emitted when savings amount is increased
    event SavingsIncreased(address indexed user, address indexed token, uint256 amount);
    
    /// @notice Emitted when module is registered
    event ModuleRegistered(bytes32 indexed moduleId, address indexed moduleAddress);
    
    /// @notice Emitted when saving strategy is set
    event SavingStrategySet(address indexed user, SavingStrategy strategy);
    
    /// @notice Emitted when DCA is added to queue
    event DCAQueued(address indexed user, uint256 amount, address indexed token, uint256 executionTime);
    
    /// @notice Emitted when slippage tolerance is updated
    event SlippageToleranceUpdated(address indexed user, uint256 tolerance);
    
    /// @notice Emitted when daily savings are configured
    event DailySavingsConfigured(address indexed user, DailySavingsConfig config);
    
    /// @notice Emitted when DCA tick strategy is set
    event DCATickStrategySet(address indexed user, int24 tickDelta, uint256 tickExpiryTime, bool onlyImprovePrice);
    
    /// @notice Emitted when DCA target token is set
    event DCATargetTokenSet(address indexed user, address indexed token);
    
    /// @notice Emitted when DCA order is executed
    event DCAExecuted(address indexed user, uint256 indexed index);
    
    /// @notice Emitted when pool tick is updated
    event PoolTickUpdated(PoolId indexed poolId, int24 tick);

    // ==================== ERRORS ====================
    
    /// @notice Error when insufficient balance for operation
    error InsufficientBalance();
    
    /// @notice Error when unauthorized access is attempted
    error Unauthorized();
    
    /// @notice Error when invalid input is provided
    error InvalidInput();
    
    /// @notice Error when module is not found
    error ModuleNotFound();
    
    /// @notice Error when already initialized
    error AlreadyInitialized();
    
    /// @notice Error when index is out of bounds
    error IndexOutOfBounds();

    // ==================== MODIFIERS ====================
    
    /// @notice Restricts access to contract owner
    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }
    
    /// @notice Restricts access to authorized modules
    modifier onlyModule() {
        if (!authorizedModules[msg.sender]) revert Unauthorized();
        _;
    }
    
    /// @notice Restricts access to the hook contract
    modifier onlyHook() {
        if (msg.sender != spendSaveHook) revert Unauthorized();
        _;
    }

    // ==================== CONSTRUCTOR ====================
    
    /**
     * @notice Initialize the storage contract with required dependencies
     * @param _poolManager The Uniswap V4 pool manager address
     * @dev Sets up initial state and validates input parameters
     */
    constructor(address _poolManager) {
        if (_poolManager == address(0)) revert InvalidInput();
        
        poolManager = _poolManager;
        owner = msg.sender;
        treasury = msg.sender;
        treasuryFee = 10; // 0.1% default treasury fee
    }

    // ==================== INITIALIZATION ====================
    
    /**
     * @notice Initialize the hook contract reference
     * @param _spendSaveHook The SpendSaveHook contract address
     * @dev Can only be called once by owner
     */
    function initialize(address _spendSaveHook) external onlyOwner {
        if (_spendSaveHook == address(0)) revert InvalidInput();
        if (spendSaveHook != address(0)) revert AlreadyInitialized();
        
        spendSaveHook = _spendSaveHook;
        emit StorageInitialized(poolManager, _spendSaveHook);
    }

    // ==================== OPTIMIZED STORAGE FUNCTIONS ====================
    
    /**
     * @notice Get packed user configuration in a single storage read
     * @param user The user address to query
     * @return percentage Savings percentage in basis points
     * @return roundUpSavings Whether to round up savings
     * @return savingsTokenType Type of token for savings (0=INPUT, 1=OUTPUT, 2=SPECIFIC)
     * @return enableDCA Whether DCA is enabled
     * @dev This function enables the gas optimization by reading all user config in one SLOAD
     */
    function getPackedUserConfig(address user) 
        external 
        view 
        returns (uint256 percentage, bool roundUpSavings, uint8 savingsTokenType, bool enableDCA) 
    {
        PackedUserConfig memory config = _packedUserConfigs[user];
        return (
            config.percentage,
            config.roundUpSavings == 1,
            config.savingsTokenType,
            config.enableDCA == 1
        );
    }
    
    /**
     * @notice Set packed user configuration with single storage write
     * @param user The user address
     * @param percentage Savings percentage (0-10000 basis points)
     * @param autoIncrement Auto increment value (0-10000 basis points)
     * @param maxPercentage Maximum percentage cap (0-10000 basis points)
     * @param roundUpSavings Whether to round up savings
     * @param enableDCA Whether DCA is enabled
     * @param savingsTokenType Type of token to save (0=INPUT, 1=OUTPUT, 2=SPECIFIC)
     * @dev Optimized for single SSTORE operation to minimize gas costs
     */
    function setPackedUserConfig(
        address user,
        uint16 percentage,
        uint16 autoIncrement,
        uint16 maxPercentage,
        bool roundUpSavings,
        bool enableDCA,
        uint8 savingsTokenType
    ) public onlyModule {
        // Validate input parameters
        if (percentage > 10000 || autoIncrement > 10000 || maxPercentage > 10000) {
            revert InvalidInput();
        }
        if (savingsTokenType > 2) revert InvalidInput(); // 0, 1, or 2 only
        
        // Pack configuration into single storage slot
        PackedUserConfig memory config = PackedUserConfig({
            percentage: percentage,
            autoIncrement: autoIncrement,
            maxPercentage: maxPercentage,
            roundUpSavings: roundUpSavings ? 1 : 0,
            enableDCA: enableDCA ? 1 : 0,
            savingsTokenType: savingsTokenType,
            reserved: 0
        });
        
        _packedUserConfigs[user] = config;
        emit UserConfigUpdated(user, config);
    }
    
    /**
     * @notice Store swap context in transient storage for gas efficiency
     * @param user The user address
     * @param pendingSaveAmount The amount pending to be saved
     * @param currentPercentage The active percentage for this swap
     * @param hasStrategy Whether user has an active strategy
     * @param savingsTokenType The token type for savings
     * @param roundUpSavings Whether to round up savings
     * @param enableDCA Whether DCA is enabled
     * @dev Uses transient storage (EIP-1153 compatible) for temporary data between beforeSwap and afterSwap
     */
    function setTransientSwapContext(
        address user,
        uint128 pendingSaveAmount,
        uint128 currentPercentage,
        bool hasStrategy,
        uint8 savingsTokenType,
        bool roundUpSavings,
        bool enableDCA
    ) external onlyHook {
        _transientSwapContexts[user] = PackedSwapContext({
            pendingSaveAmount: pendingSaveAmount,
            currentPercentage: uint16(currentPercentage), // Safe cast since percentage <= 10000
            hasStrategy: hasStrategy ? 1 : 0,
            savingsTokenType: savingsTokenType,
            roundUpSavings: roundUpSavings ? 1 : 0,
            enableDCA: enableDCA ? 1 : 0,
            reserved: 0
        });
    }
    
    /**
     * @notice Get swap context from transient storage
     * @param user The user address
     * @return pendingSaveAmount Amount pending to be saved
     * @return currentPercentage Active percentage for this swap
     * @return savingsTokenType Token type for savings
     * @return roundUpSavings Whether to round up savings
     * @return enableDCA Whether DCA is enabled
     * @dev Gas-efficient single read from transient storage
     */
    function getTransientSwapContext(address user) 
        external 
        view 
        returns (
            uint128 pendingSaveAmount,
            uint128 currentPercentage,
            uint8 savingsTokenType,
            bool roundUpSavings,
            bool enableDCA
        ) 
    {
        PackedSwapContext memory context = _transientSwapContexts[user];
        return (
            context.pendingSaveAmount,
            context.currentPercentage,
            context.savingsTokenType,
            context.roundUpSavings == 1,
            context.enableDCA == 1
        );
    }
    
    /**
     * @notice Clear swap context after processing
     * @param user The user address
     * @dev Cleanup function to prevent stale data and optimize storage
     */
    function clearTransientSwapContext(address user) external onlyHook {
        delete _transientSwapContexts[user];
    }
    
    /**
     * @notice Batch update user savings data in a single transaction
     * @param user The user address
     * @param token The token address
     * @param savingsAmount The gross savings amount
     * @return netSavings The net savings amount after fees
     * @dev Optimized function that performs multiple related updates in one call to minimize gas
     */
    function batchUpdateUserSavings(
        address user,
        address token,
        uint256 savingsAmount
    ) external onlyModule returns (uint256 netSavings) {
        // Calculate fee and net savings
        uint256 feeAmount = (savingsAmount * treasuryFee) / 10000;
        netSavings = savingsAmount - feeAmount;
        
        // Update user savings balance
        _savings[user][token] += netSavings;
        
        // Update treasury fees if applicable
        if (feeAmount > 0) {
            _savings[treasury][token] += feeAmount;
        }
        
        emit SavingsIncreased(user, token, netSavings);
        return netSavings;
    }
    
    /**
     * @notice Get user tokens eligible for daily savings processing
     * @param user The user address
     * @return tokens Array of token addresses that can be processed for daily savings
     * @dev Efficiently filters tokens based on user's daily savings configuration
     */
    function getUserTokensForDailySavings(address user) external view returns (address[] memory tokens) {
        DailySavingsConfig memory config = dailySavingsConfigs[user];
        if (!config.isActive) {
            return new address[](0);
        }
        return config.tokens;
    }

    // ==================== MODULE REGISTRY FUNCTIONS ====================
    
    /**
     * @notice Register a module in the registry with authorization
     * @param moduleId The unique module identifier (e.g., keccak256("STRATEGY"))
     * @param moduleAddress The module contract address
     * @dev Only owner can register modules to maintain security
     */
    function registerModule(bytes32 moduleId, address moduleAddress) external onlyOwner {
        if (moduleAddress == address(0)) revert InvalidInput();
        
        moduleRegistry[moduleId] = moduleAddress;
        authorizedModules[moduleAddress] = true;
        
        emit ModuleRegistered(moduleId, moduleAddress);
    }
    
    /**
     * @notice Get module address by identifier
     * @param moduleId The module identifier
     * @return moduleAddress The module contract address
     * @dev Gas-efficient lookup for module addresses
     */
    function getModule(bytes32 moduleId) external view returns (address moduleAddress) {
        moduleAddress = moduleRegistry[moduleId];
        if (moduleAddress == address(0)) revert ModuleNotFound();
    }

    // ==================== ERC6909 TOKEN IMPLEMENTATION ====================
    
    /**
     * @notice Get token balance for ERC6909 compliance
     * @param tokenOwner The token owner address
     * @param id The token ID
     * @return balance The token balance
     */
    function getBalance(address tokenOwner, uint256 id) external view returns (uint256 balance) {
        return _balances[owner][id];
    }
    
    /**
     * @notice Set token balance (module access only)
     * @param user The user address
     * @param id The token ID
     * @param amount The new balance amount
     * @dev Direct balance setting for module operations
     */
    function setBalance(address user, uint256 id, uint256 amount) external onlyModule {
        _balances[user][id] = amount;
    }
    
    /**
     * @notice Increase token balance (module access only)
     * @param user The user address
     * @param id The token ID
     * @param amount The amount to increase
     * @dev Gas-efficient balance increase operation
     */
    function increaseBalance(address user, uint256 id, uint256 amount) external onlyModule {
        _balances[user][id] += amount;
    }
    
    /**
     * @notice Decrease token balance with validation (module access only)
     * @param user The user address
     * @param id The token ID
     * @param amount The amount to decrease
     * @dev Includes balance validation to prevent underflow
     */
    function decreaseBalance(address user, uint256 id, uint256 amount) external onlyModule {
        if (_balances[user][id] < amount) revert InsufficientBalance();
        _balances[user][id] -= amount;
    }
    
    /**
     * @notice Get allowance for ERC6909 compliance
     * @param tokenOwner The token owner address
     * @param spender The spender address
     * @param id The token ID
     * @return allowance The current allowance amount
     */
    function getAllowance(address tokenOwner, address spender, uint256 id) external view returns (uint256 allowance) {
        return _allowances[tokenOwner][spender][id];
    }
    
    /**
     * @notice Set allowance for ERC6909 compliance (module access only)
     * @param tokenOwner The token owner address
     * @param spender The spender address
     * @param id The token ID
     * @param amount The allowance amount
     */
    function setAllowance(address tokenOwner, address spender, uint256 id, uint256 amount) external onlyModule {
        _allowances[tokenOwner][spender][id] = amount;
    }
    
    /**
     * @notice Get token address from ID
     * @param id The token ID
     * @return tokenAddress The corresponding token address
     */
    function idToToken(uint256 id) external view returns (address tokenAddress) {
        return _tokenIdToAddress[id];
    }
    
    /**
     * @notice Set token ID to address mapping (module access only)
     * @param id The token ID
     * @param token The token address
     */
    function setIdToToken(uint256 id, address token) external onlyModule {
        _tokenIdToAddress[id] = token;
    }
    
    /**
     * @notice Get token ID from address
     * @param token The token address
     * @return tokenId The corresponding token ID (0 if not registered)
     */
    function tokenToId(address token) external view returns (uint256 tokenId) {
        return _tokenToId[token];
    }
    
    /**
     * @notice Set token address to ID mapping (module access only)
     * @param token The token address
     * @param id The token ID
     */
    function setTokenToId(address token, uint256 id) external onlyModule {
        _tokenToId[token] = id;
    }
    
    /**
     * @notice Get next available token ID
     * @return nextId The next token ID to be assigned
     */
    function getNextTokenId() external view returns (uint256 nextId) {
        return _nextTokenId;
    }
    
    /**
     * @notice Increment and return the next token ID (module access only)
     * @return currentId The ID that was just incremented (old value)
     * @dev Returns the value before incrementing for immediate use
     */
    function incrementNextTokenId() external onlyModule returns (uint256 currentId) {
        currentId = _nextTokenId;
        _nextTokenId++;
        return currentId;
    }

    // ==================== SAVINGS MANAGEMENT FUNCTIONS ====================
    
    /**
     * @notice Set user saving strategy (comprehensive configuration)
     * @param user The user address
     * @param strategy The complete saving strategy configuration
     * @dev Maintains legacy compatibility while leveraging packed storage
     */
    function setSavingStrategy(address user, SavingStrategy memory strategy) external onlyModule {
        // userSavingStrategies[user] = strategy; // ⚠️ REMOVED LEGACY STORAGE WRITE
        // Also update packed configuration for gas optimization
        setPackedUserConfig(
            user,
            uint16(strategy.percentage),
            uint16(strategy.autoIncrement), 
            uint16(strategy.maxPercentage),
            strategy.roundUpSavings,
            strategy.enableDCA,
            uint8(strategy.savingsTokenType)
        );
        // Store specific token if applicable
        if (strategy.savingsTokenType == SavingsTokenType.SPECIFIC) {
            specificSavingsToken[user] = strategy.specificSavingsToken;
        }
        // Store savings goal
        savingsGoals[user] = strategy.goalAmount;
        emit SavingStrategySet(user, strategy);
    }
    
    /**
    * @notice Get user saving strategy
    * @param user The user address
    * @return strategy The complete saving strategy configuration
    * @dev Now uses only packed storage - no more legacy fallbacks
    */
    function getUserSavingStrategy(address user) external view returns (SavingStrategy memory strategy) {
        // Get from packed storage only
        PackedUserConfig memory packed = _packedUserConfigs[user];
        
        // Construct strategy from packed storage and individual mappings
        strategy = SavingStrategy({
            percentage: packed.percentage,
            autoIncrement: packed.autoIncrement,
            maxPercentage: packed.maxPercentage,
            goalAmount: savingsGoals[user],
            roundUpSavings: packed.roundUpSavings == 1,
            enableDCA: packed.enableDCA == 1,
            savingsTokenType: SavingsTokenType(packed.savingsTokenType),
            specificSavingsToken: specificSavingsToken[user]
        });
    }
    
    /**
     * @notice Increase savings balance with fee handling
     * @param user The user address
     * @param token The token address
     * @param amount The gross amount to save
     * @dev Legacy function maintained for compatibility
     */
    function increaseSavings(address user, address token, uint256 amount) external onlyModule {
        uint256 fee = (amount * treasuryFee) / 10000;
        uint256 netAmount = amount - fee;
        
        _savings[user][token] += netAmount;
        if (fee > 0) {
            _savings[treasury][token] += fee;
        }
        
        emit SavingsIncreased(user, token, netAmount);
    }

    /**
    * @notice Set daily savings amount for user and token
    * @param user The user address
    * @param token The token address
    * @param amount The daily savings amount
    */
    function setDailySavingsAmount(address user, address token, uint256 amount) external onlyModule {
        dailySavingsAmounts[user][token] = amount;
    }

    /**
    * @notice Set daily savings configuration parameters
    * @param user The user address
    * @param token The token address
    * @param params The configuration parameters
    */
    function setDailySavingsConfig(address user, address token, DailySavingsConfigParams memory params) external onlyModule {
        dailySavingsConfigParams[user][token] = params;
    }

    /**
    * @notice Get daily savings configuration parameters
    * @param user The user address
    * @param token The token address
    * @return params The configuration parameters
    */
    function getDailySavingsConfigParams(address user, address token) external view returns (DailySavingsConfigParams memory params) {
        return dailySavingsConfigParams[user][token];
    }
    
    /**
     * @notice Get user savings balance for a specific token
     * @param user The user address
     * @param token The token address
     * @return amount The savings balance
     */
    function savings(address user, address token) external view returns (uint256 amount) {
        return _savings[user][token];
    }

    /**
     * @notice Get detailed savings information for a user and token
     * @param user The user address
     * @param token The token address
     * @return balance Current savings balance
     * @return _totalSaved Total amount saved historically
     * @return _lastSaveTime Timestamp of last save operation
     * @return isLocked Whether withdrawals are currently locked
     * @return _withdrawalTimelock Timestamp when withdrawals will be unlocked
     */
    function getSavingsDetails(address user, address token) external view returns (
        uint256 balance,
        uint256 _totalSaved,
        uint256 _lastSaveTime,
        bool isLocked,
        uint256 _withdrawalTimelock
    ) {
        balance = _savings[user][token];
        _totalSaved = totalSaved[user][token];
        _lastSaveTime = lastSaveTime[user][token];
        _withdrawalTimelock = withdrawalTimelock[user];
        isLocked = block.timestamp < _withdrawalTimelock;
    }

    /**
     * @notice Decrease savings balance for a user and token
     * @param user The user address
     * @param token The token address
     * @param amount The amount to decrease
     * @dev Only callable by authorized modules
     */
    function decreaseSavings(address user, address token, uint256 amount) external onlyModule {
        if (_savings[user][token] < amount) revert InsufficientBalance();
        _savings[user][token] -= amount;
    }

    // ==================== SWAP CONTEXT MANAGEMENT ====================

    /**
     * @notice Set swap context for transaction processing
     * @param user The user address
     * @param context The swap context data
     * @dev CHANGE: external → public (to allow internal calls)
     */
    function setSwapContext(address user, SwapContext memory context) public onlyModule {
        // Convert to packed format for transient storage
        _transientSwapContexts[user] = PackedSwapContext({
            pendingSaveAmount: uint128(context.pendingSaveAmount),
            currentPercentage: uint16(context.currentPercentage),
            hasStrategy: context.hasStrategy ? 1 : 0,
            savingsTokenType: uint8(context.savingsTokenType),
            roundUpSavings: context.roundUpSavings ? 1 : 0,
            enableDCA: context.enableDCA ? 1 : 0,
            reserved: 0
        });
        
        // Store additional fields that don't fit in packed format
        if (context.dcaTargetToken != address(0)) {
            dcaTargetTokens[user] = context.dcaTargetToken;
        }
    }

    /**
     * @notice Set swap context with current tick for DCA operations
     * @param user The user address
     * @param context The swap context data
     * @param currentTick The current pool tick
     * @dev Extended version for DCA operations that need tick information
     */
    function setSwapContextWithTick(address user, SwapContext memory context, int24 currentTick) external onlyModule {
        // Set the basic swap context
        setSwapContext(user, context);
        
        // Store the current tick in a separate mapping for DCA operations
        // Note: This is a temporary solution - in a full implementation, 
        // you might want to store this in the transient context or pass it directly
    }

    /**
     * @notice Get swap context for legacy compatibility
     * @param user The user address
     * @return context The swap context data
     * @dev Converts from packed transient storage only
     */
    function getSwapContext(address user) external view returns (SwapContext memory context) {
        // Get from transient storage only
        PackedSwapContext memory packed = _transientSwapContexts[user];
        // Convert from packed transient storage
        context = SwapContext({
            hasStrategy: packed.hasStrategy == 1,
            currentPercentage: packed.currentPercentage,
            inputAmount: 0, // Not stored in packed format
            inputToken: address(0), // Not stored in packed format
            roundUpSavings: packed.roundUpSavings == 1,
            enableDCA: packed.enableDCA == 1,
            dcaTargetToken: address(0), // Retrieved separately if needed
            currentTick: 0, // Not stored in packed format, would need to be set separately
            savingsTokenType: SavingsTokenType(packed.savingsTokenType),
            specificSavingsToken: specificSavingsToken[user],
            pendingSaveAmount: packed.pendingSaveAmount
        });
    }

    // ==================== DCA MANAGEMENT FUNCTIONS ====================

    /**
     * @notice Add DCA order to user's queue
     * @param user The user address
     * @param amount The DCA amount
     * @param token The target token address
     * @param executionTime The scheduled execution time
     */
    function addToDcaQueue(address user, uint256 amount, address token, uint256 executionTime) external onlyModule {
        DCAQueue storage queue = dcaQueues[user];
        
        queue.amounts.push(amount);
        queue.tokens.push(token);
        queue.executionTimes.push(executionTime);
        queue.isActive = true;
        
        emit DCAQueued(user, amount, token, executionTime);
    }

    /**
     * @notice Get user's DCA queue
     * @param user The user address
     * @return queue The complete DCA queue data
     */
    function getDcaQueue(address user) external view returns (DCAQueue memory queue) {
        return dcaQueues[user];
    }

    // ==================== DCA TICK STRATEGY FUNCTIONS ====================

    /**
     * @notice Get DCA tick strategy for a user
     * @param user The user address
     * @return tickDelta Tick movement threshold
     * @return tickExpiryTime Strategy expiry timestamp
     * @return onlyImprovePrice Only execute on price improvement flag
     * @return minTickImprovement Minimum tick improvement required
     * @return dynamicSizing Dynamic sizing enabled flag
     * @return customSlippageTolerance Custom slippage tolerance
     */
    function getDcaTickStrategy(address user) 
        external 
        view 
        returns (
            int24 tickDelta,
            uint256 tickExpiryTime,
            bool onlyImprovePrice,
            int24 minTickImprovement,
            bool dynamicSizing,
            uint256 customSlippageTolerance
        ) 
    {
        DCATickStrategy storage strategy = dcaTickStrategies[user];
        return (
            strategy.tickDelta,
            strategy.tickExpiryTime,
            strategy.onlyImprovePrice,
            strategy.minTickImprovement,
            strategy.dynamicSizing,
            strategy.customSlippageTolerance
        );
    }

    /**
     * @notice Set DCA tick strategy for a user
     * @param user The user address
     * @param tickDelta Tick movement threshold
     * @param tickExpiryTime Strategy expiry timestamp
     * @param onlyImprovePrice Only execute on price improvement flag
     * @param minTickImprovement Minimum tick improvement required
     * @param dynamicSizing Dynamic sizing enabled flag
     * @param customSlippageTolerance Custom slippage tolerance
     */
    function setDcaTickStrategy(
        address user,
        int24 tickDelta,
        uint256 tickExpiryTime,
        bool onlyImprovePrice,
        int24 minTickImprovement,
        bool dynamicSizing,
        uint256 customSlippageTolerance
    ) external onlyModule {
        dcaTickStrategies[user] = DCATickStrategy({
            tickDelta: tickDelta,
            tickExpiryTime: tickExpiryTime,
            onlyImprovePrice: onlyImprovePrice,
            minTickImprovement: minTickImprovement,
            dynamicSizing: dynamicSizing,
            customSlippageTolerance: customSlippageTolerance
        });
        
        emit DCATickStrategySet(user, tickDelta, tickExpiryTime, onlyImprovePrice);
    }

    // ==================== DCA TARGET TOKEN FUNCTIONS ====================

    /**
     * @notice Get DCA target token for a user
     * @param user The user address
     * @return targetToken The target token address
     */
    function dcaTargetToken(address user) external view returns (address targetToken) {
        return dcaTargetTokens[user];
    }

    /**
     * @notice Set DCA target token for a user
     * @param user The user address
     * @param token The target token address
     */
    function setDcaTargetToken(address user, address token) external onlyModule {
        dcaTargetTokens[user] = token;
        emit DCATargetTokenSet(user, token);
    }

    // ==================== ENHANCED DCA QUEUE FUNCTIONS ====================

    /**
     * @notice Add detailed DCA order to user's queue
     * @param user The user address
     * @param fromToken Source token address
     * @param toToken Target token address
     * @param amount DCA amount
     * @param executionTick Target execution tick
     * @param deadline Execution deadline
     * @param customSlippageTolerance Custom slippage tolerance
     */
    function addToDcaQueue(
        address user,
        address fromToken,
        address toToken,
        uint256 amount,
        int24 executionTick,
        uint256 deadline,
        uint256 customSlippageTolerance
    ) external onlyModule {
        EnhancedDCAQueue storage queue = enhancedDcaQueues[user];
        
        // Add to enhanced queue
        queue.items.push(DCAQueueItem({
            fromToken: fromToken,
            toToken: toToken,
            amount: amount,
            executionTick: executionTick,
            deadline: deadline,
            customSlippageTolerance: customSlippageTolerance,
            executed: false
        }));
        
        queue.isActive = true;
        
        // Also maintain compatibility with existing simple queue
        DCAQueue storage simpleQueue = dcaQueues[user];
        simpleQueue.amounts.push(amount);
        simpleQueue.tokens.push(toToken);
        simpleQueue.executionTimes.push(deadline);
        simpleQueue.isActive = true;
        
        emit DCAQueued(user, amount, toToken, deadline);
    }

    /**
     * @notice Get DCA queue length for a user
     * @param user The user address
     * @return length The queue length
     */
    function getDcaQueueLength(address user) external view returns (uint256 length) {
        return enhancedDcaQueues[user].items.length;
    }

    /**
     * @notice Get specific DCA queue item
     * @param user The user address
     * @param index The queue item index
     * @return fromToken Source token address
     * @return toToken Target token address
     * @return amount DCA amount
     * @return executionTick Target execution tick
     * @return deadline Execution deadline
     * @return executed Execution status
     * @return customSlippageTolerance Custom slippage tolerance
     */
    function getDcaQueueItem(address user, uint256 index) 
        external 
        view 
        returns (
            address fromToken,
            address toToken,
            uint256 amount,
            int24 executionTick,
            uint256 deadline,
            bool executed,
            uint256 customSlippageTolerance
        ) 
    {
        if (index >= enhancedDcaQueues[user].items.length) revert IndexOutOfBounds();
        
        DCAQueueItem storage item = enhancedDcaQueues[user].items[index];
        return (
            item.fromToken,
            item.toToken,
            item.amount,
            item.executionTick,
            item.deadline,
            item.executed,
            item.customSlippageTolerance
        );
    }

    /**
     * @notice Mark DCA order as executed
     * @param user The user address
     * @param index The queue item index
     */
    function markDcaExecuted(address user, uint256 index) external onlyModule {
        if (index >= enhancedDcaQueues[user].items.length) revert IndexOutOfBounds();
        
        EnhancedDCAQueue storage queue = enhancedDcaQueues[user];
        queue.items[index].executed = true;
        queue.executed[index] = true;
        
        emit DCAExecuted(user, index);
    }

    // ==================== POOL TICK MANAGEMENT FUNCTIONS ====================

    /**
     * @notice Get current tick for a pool
     * @param poolId The pool identifier
     * @return tick The current tick
     */
    function poolTicks(PoolId poolId) external view returns (int24 tick) {
        return _poolTicks[poolId];
    }

    /**
     * @notice Set current tick for a pool
     * @param poolId The pool identifier
     * @param tick The current tick
     */
    function setPoolTick(PoolId poolId, int24 tick) external onlyModule {
        _poolTicks[poolId] = tick;
        emit PoolTickUpdated(poolId, tick);
    }

    // ==================== POOL KEY CREATION FUNCTIONS ====================

    /**
     * @notice Create pool key with default parameters (2-parameter version)
     * @param token0 The first token address
     * @param token1 The second token address
     * @return key The created pool key
     * @dev CHANGE: external → public (to allow internal calls to 5-parameter version)
     */
    function createPoolKey(address token0, address token1) public onlyModule returns (PoolKey memory key) {
        return createPoolKey(token0, token1, DEFAULT_FEE_TIER, DEFAULT_TICK_SPACING, address(0));
    }

    // ==================== HELPER FUNCTIONS FOR BACKWARDS COMPATIBILITY ====================

    /**
     * @notice Check if user has any pending DCA orders
     * @param user The user address
     * @return hasPending True if user has pending orders
     */
    function hasPendingDCAOrders(address user) external view returns (bool hasPending) {
        EnhancedDCAQueue storage queue = enhancedDcaQueues[user];
        
        for (uint256 i = 0; i < queue.items.length; i++) {
            if (!queue.items[i].executed && queue.items[i].deadline > block.timestamp) {
                return true;
            }
        }
        
        return false;
    }

    /**
     * @notice Get all pending DCA orders for a user
     * @param user The user address
     * @return pendingOrders Array of pending DCA orders
     */
    function getPendingDCAOrders(address user) 
        external 
        view 
        returns (DCAQueueItem[] memory pendingOrders) 
    {
        EnhancedDCAQueue storage queue = enhancedDcaQueues[user];
        
        // Count pending orders
        uint256 pendingCount = 0;
        for (uint256 i = 0; i < queue.items.length; i++) {
            if (!queue.items[i].executed && queue.items[i].deadline > block.timestamp) {
                pendingCount++;
            }
        }
        
        // Create array of pending orders
        pendingOrders = new DCAQueueItem[](pendingCount);
        uint256 pendingIndex = 0;
        
        for (uint256 i = 0; i < queue.items.length; i++) {
            if (!queue.items[i].executed && queue.items[i].deadline > block.timestamp) {
                pendingOrders[pendingIndex] = queue.items[i];
                pendingIndex++;
            }
        }
        
        return pendingOrders;
    }

    // ==================== SLIPPAGE CONTROL FUNCTIONS ====================
    
    /**
     * @notice Set user's slippage tolerance
     * @param user The user address
     * @param tolerance The slippage tolerance in basis points
     */
    function setUserSlippageTolerance(address user, uint256 tolerance) external onlyModule {
        userSlippageTolerance[user] = tolerance;
        emit SlippageToleranceUpdated(user, tolerance);
    }
    
    /**
     * @notice Set token-specific slippage tolerance
     * @param user The user address
     * @param token The token address
     * @param tolerance The slippage tolerance in basis points
     */
    function setTokenSlippageTolerance(address user, address token, uint256 tolerance) external onlyModule {
        tokenSlippageTolerance[user][token] = tolerance;
    }
    
    /**
     * @notice Set slippage exceeded action
     * @param user The user address
     * @param action The action to take when slippage is exceeded
     */
    function setSlippageExceededAction(address user, SlippageAction action) external onlyModule {
        slippageExceededAction[user] = action;
    }
    
    /**
     * @notice Set default slippage tolerance
     * @param tolerance The default tolerance in basis points
     */
    function setDefaultSlippageTolerance(uint256 tolerance) external onlyOwner {
        defaultSlippageTolerance = tolerance;
    }

    // ==================== DAILY SAVINGS FUNCTIONS ====================
    
    /**
     * @notice Configure daily savings for a user
     * @param user The user address
     * @param config The daily savings configuration
     */
    function setDailySavingsConfig(address user, DailySavingsConfig memory config) external onlyModule {
        dailySavingsConfigs[user] = config;
        emit DailySavingsConfigured(user, config);
    }
    
    /**
     * @notice Get daily savings configuration
     * @param user The user address
     * @return config The daily savings configuration
     */
    function getDailySavingsConfig(address user) external view returns (DailySavingsConfig memory config) {
        return dailySavingsConfigs[user];
    }

    // ==================== POOL MANAGEMENT FUNCTIONS ====================
    
    /**
     * @notice Create and store a pool key (5-parameter version)
     * @param token0 The first token address
     * @param token1 The second token address
     * @param fee The pool fee
     * @param tickSpacing The tick spacing
     * @param hooks The hooks contract address
     * @return key The created pool key
     * @dev CHANGE: external → public (to allow internal calls from 2-parameter version)
     */
    function createPoolKey(
        address token0,
        address token1,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) public onlyModule returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(hooks)
        });
        
        bytes32 keyHash = keccak256(abi.encode(key));
        _poolKeys[keyHash] = key;
        poolInitialized[keyHash] = true;
        
        return key;
    }
    
    /**
     * @notice Get stored pool key by hash
     * @param keyHash The pool key hash
     * @return key The pool key
     */
    function getPoolKey(bytes32 keyHash) external view returns (PoolKey memory key) {
        return _poolKeys[keyHash];
    }

    // ==================== ADMINISTRATIVE FUNCTIONS ====================
    
    /**
     * @notice Update treasury address (owner only)
     * @param newTreasury The new treasury address
     */
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidInput();
        treasury = newTreasury;
    }
    
    /**
     * @notice Update treasury fee (owner only)
     * @param newFee The new treasury fee in basis points
     */
    function setTreasuryFee(uint256 newFee) external onlyOwner {
        if (newFee > 1000) revert InvalidInput(); // Max 10% fee
        treasuryFee = newFee;
    }
    
    /**
     * @notice Transfer ownership (owner only)
     * @param newOwner The new owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidInput();
        owner = newOwner;
    }
    
    /**
     * @notice Emergency pause function (owner only)
     * @dev Implementation depends on specific emergency requirements
     */
    function emergencyPause() external onlyOwner {
        // Emergency pause implementation
        // Could disable specific functions or set emergency flags
    }

    /**
     * @notice Set withdrawal timelock for a user
     * @param user The user address
     * @param timelock The timelock timestamp
     */
    function setWithdrawalTimelock(address user, uint256 timelock) external onlyModule {
        userWithdrawalTimelocks[user] = timelock;
    }

    /**
     * @notice Get withdrawal timelock for a user
     * @param user The user address
     * @return timelock The timelock timestamp
     */
    function getWithdrawalTimelock(address user) external view returns (uint256) {
        return withdrawalTimelock[user];
    }

    // ==================== USER SAVINGS TOKEN TRACKING ====================
    mapping(address => address[]) private userSavingsTokens;
    mapping(address => mapping(address => bool)) private userHasToken;

    function addUserSavingsToken(address user, address token) external onlyModule {
        if (!userHasToken[user][token]) {
            userSavingsTokens[user].push(token);
            userHasToken[user][token] = true;
        }
    }

    function getUserSavingsTokens(address user) external view returns (address[] memory) {
        return userSavingsTokens[user];
    }
}