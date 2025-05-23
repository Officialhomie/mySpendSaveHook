// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "lib/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {ReentrancyGuard} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";

/**
 * @notice Centralized storage for all SpendSave modules
 * @dev This contract holds all state variables used by the various modules
 */

// Custom errors
/// @notice Thrown when a caller is not the contract owner
error NotOwner();
/// @notice Thrown when a caller is not an authorized module
error NotAuthorizedModule(); 
/// @notice Thrown when a caller is not the pending owner
error NotPendingOwner();
/// @notice Thrown when fee is set too high
error FeeTooHigh();
/// @notice Thrown when savings balance is insufficient
error InsufficientSavings();
/// @notice Thrown when array index is out of bounds
error IndexOutOfBounds();
/// @notice Thrown when token balance is insufficient
error InsufficientBalance();

/**
 * @title SpendSaveStorage
 * @author Your Name
 * @notice Central storage contract for the SpendSave protocol
 * @dev This contract acts as a shared database for all SpendSave modules,
 *      maintaining all state and providing controlled access to different modules
 */
contract SpendSaveStorage is ReentrancyGuard {
    // Owner and access control
    address public owner;
    address public pendingOwner;
    address public treasury;
    
    // Module registry
    address public savingStrategyModule;
    address public savingsModule;
    address public dcaModule;
    address public slippageControlModule;
    address public tokenModule;
    address public yieldModule;
    address public dailySavingsModule;
    
    // Main hook reference
    address public spendSaveHook;
    IPoolManager public poolManager;
    
    // Enums
    enum SavingsTokenType { OUTPUT, INPUT, SPECIFIC }
    enum YieldStrategy { NONE, AAVE, COMPOUND, UNISWAP_LP }
    enum SlippageAction { CONTINUE, REVERT }

    // Treasury configuration
    uint256 public treasuryFee; // Basis points (0.01%)

/**
 * @notice User's saving strategy configuration
 * @dev Defines how tokens are saved during swaps
 * @param percentage Base percentage to save (0-10000, where 10000 = 100%)
 * @param autoIncrement Percentage to increase after each swap
 * @param maxPercentage Maximum percentage cap for auto-increments
 * @param goalAmount Target savings goal for each token
 * @param roundUpSavings Whether to round up to nearest whole token unit
 * @param enableDCA Whether dollar-cost averaging is enabled
 * @param savingsTokenType Which token to save (INPUT, OUTPUT, or SPECIFIC)
 * @param specificSavingsToken Address of specific token to save, if applicable
 */
    struct SavingStrategy {
        uint256 percentage;     // Base percentage to save (0-100%)
        uint256 autoIncrement;  // Optional auto-increment percentage per swap
        uint256 maxPercentage;  // Maximum percentage cap
        uint256 goalAmount;     // Savings goal for each token
        bool roundUpSavings;    // Round up to nearest whole token unit
        bool enableDCA;         // Enable dollar-cost averaging into target token
        SavingsTokenType savingsTokenType; // Which token to save
        address specificSavingsToken;    // Specific token to save, if that option is selected
    }
    
    // User savings data
    struct SavingsData {
        uint256 totalSaved;     // Total amount saved
        uint256 lastSaveTime;   // Last time user saved
        uint256 swapCount;      // Number of swaps with savings
        uint256 targetSellPrice; // Target price to auto-sell savings
    }
    
    // Swap context for passing data between beforeSwap and afterSwap
    struct SwapContext {
        bool hasStrategy;
        uint256 currentPercentage;
        bool roundUpSavings;
        bool enableDCA;
        address dcaTargetToken;
        int24 currentTick;      // Current tick at swap time
        SavingsTokenType savingsTokenType;
        address specificSavingsToken;
        address inputToken;     // Track input token for INPUT savings type
        uint256 inputAmount;    // Track input amount for INPUT savings type
        uint256 pendingSaveAmount;  // Add this field
    }
    
    // DCA execution details
    struct DCAExecution {
        address fromToken;
        address toToken;
        uint256 amount;
        int24 executionTick;    // Tick at which DCA should execute
        uint256 deadline;       // Deadline for execution
        bool executed;
        uint256 customSlippageTolerance;
    }
    
    // DCA tick strategies
    struct DCATickStrategy {
        int24 tickDelta;         // +/- ticks from current for better execution
        uint256 tickExpiryTime;  // How long to wait before executing regardless of tick
        bool onlyImprovePrice;   // If true, only execute when price is better than entry
        int24 minTickImprovement; // Minimum tick improvement required
        bool dynamicSizing;      // If true, calculate amount based on tick movement
        uint256 customSlippageTolerance;
    }

    // Daily savings configuration
    struct DailySavingsConfig {
        bool enabled;
        uint256 lastExecutionTime;
        uint256 startTime;
        uint256 goalAmount;
        uint256 currentAmount;
        uint256 penaltyBps; // Basis points for early withdrawal penalty (e.g., 500 = 5%)
        uint256 endTime;    // Target date to reach goal (0 means no end date)
    }

    struct DailySavingsConfigParams {
        bool enabled;
        uint256 goalAmount;
        uint256 currentAmount;
        uint256 penaltyBps;
        uint256 endTime;
    }

    // Mappings - Strategy module
    mapping(address => SavingStrategy) internal _userSavingStrategies;
    
    // Mappings - Savings module
    mapping(address => mapping(address => uint256)) internal _savings;
    mapping(address => mapping(address => SavingsData)) internal _savingsData;
    mapping(address => uint256) internal _withdrawalTimelock;
    
    // Mappings - DCA module
    mapping(address => address) internal _dcaTargetToken;
    mapping(address => DCATickStrategy) internal _dcaTickStrategies;
    mapping(address => DCAExecution[]) internal _dcaQueue;
    mapping(PoolId => int24) internal _poolTicks;
    
    // Mappings - Swap context
    mapping(address => SwapContext) internal _swapContexts;
    
    // Mappings - Yield module
    mapping(address => mapping(address => YieldStrategy)) internal _yieldStrategies;
    
    // Mappings - Slippage module
    mapping(address => uint256) internal _userSlippageTolerance;
    mapping(address => mapping(address => uint256)) internal _tokenSlippageTolerance;
    mapping(address => SlippageAction) internal _slippageExceededAction;
    uint256 public defaultSlippageTolerance;
    
    // Mappings - Token module (ERC6909)
    mapping(address => mapping(uint256 => uint256)) internal _balances;
    mapping(address => mapping(address => mapping(uint256 => uint256))) internal _allowances;
    mapping(address => uint256) internal _tokenToId;
    mapping(uint256 => address) internal _idToToken;
    uint256 internal _nextTokenId;


    // Track daily savings for each user and token
    mapping(address => mapping(address => DailySavingsConfig)) internal _dailySavingsConfig;
    mapping(address => mapping(address => uint256)) internal _dailySavingsAmount;
    mapping(address => address[]) internal _userSavingsTokens; // Track which tokens a user is saving


    // Track daily savings for each user and token// Yield strategy for daily savings
    mapping(address => mapping(address => YieldStrategy)) internal _dailySavingsYieldStrategy;

    uint256 private constant MAX_TREASURY_FEE = 100; // 1%
    uint256 private constant DEFAULT_TREASURY_FEE = 80; // 0.8%
    uint256 private constant DEFAULT_SLIPPAGE_TOLERANCE = 100; // 1%
    uint256 private constant FIRST_TOKEN_ID = 1;




/**
 * @notice Contract constructor
 * @param _owner Address of the contract owner
 * @param _treasury Address of the treasury to collect fees
 * @param _poolManager Address of the Uniswap V4 pool manager
 */
    constructor(address _owner, address _treasury, IPoolManager _poolManager) {
        owner = _owner;
        treasury = _treasury;
        poolManager = _poolManager;
        treasuryFee = DEFAULT_TREASURY_FEE;
        defaultSlippageTolerance = DEFAULT_SLIPPAGE_TOLERANCE;
        _nextTokenId = FIRST_TOKEN_ID;
    }
    
    /**
     * @notice Access control modifier
     * @dev Only allows the contract owner to call functions
     */
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /**
     * @notice Access control modifier
     * @dev Only allows authorized modules to call functions
     */
    function _isAuthorizedModule(
        address caller
    ) internal view returns (bool) {
        return (
            caller == savingStrategyModule ||
            caller == savingsModule ||
            caller == dcaModule ||
            caller == slippageControlModule ||
            caller == tokenModule ||
            caller == yieldModule ||
            caller == dailySavingsModule ||
            caller == spendSaveHook
        );
    }
    
    modifier onlyModule() {
        if (!_isAuthorizedModule(msg.sender)) {
            revert NotAuthorizedModule();
        }
        _;
    }
    /**
    * @notice Sets the SpendSave hook contract address
    * @param _hook Address of the SpendSave hook contract
    * @dev Only callable by the contract owner
    */
    function setSpendSaveHook(address _hook) external onlyOwner {
        spendSaveHook = _hook;
    }
    /**
    * @notice Sets the SavingStrategy module address
    * @param _module Address of the SavingStrategy module
    * @dev Only callable by the contract owner
    */
    function setSavingStrategyModule(address _module) external onlyOwner {
        savingStrategyModule = _module;
    }
    /**
    * @notice Sets the Savings module address
    * @param _module Address of the Savings module
    * @dev Only callable by the contract owner
    */
    function setSavingsModule(address _module) external onlyOwner {
        savingsModule = _module;
    }
    /**
    * @notice Sets the DCA module address
    * @param _module Address of the DCA module
    * @dev Only callable by the contract owner
    */
    function setDCAModule(address _module) external onlyOwner {
        dcaModule = _module;
    }
    /**
    * @notice Sets the SlippageControl module address
    * @param _module Address of the SlippageControl module
    * @dev Only callable by the contract owner
    */
    function setSlippageControlModule(address _module) external onlyOwner {
        slippageControlModule = _module;
    }
    /**
    * @notice Sets the Token module address
    * @param _module Address of the Token module
    * @dev Only callable by the contract owner
    */
    function setTokenModule(address _module) external onlyOwner {
        tokenModule = _module;
    }
    
    function setYieldModule(address _module) external onlyOwner {
        yieldModule = _module;
    }

    function setDailySavingsModule(address _module) external onlyOwner {
        dailySavingsModule = _module;
    }
    
    // Ownership transfer functions
    function transferOwnership(address _newOwner) external onlyOwner {
        pendingOwner = _newOwner;
    }


    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        owner = pendingOwner;
        pendingOwner = address(0);
    }
    
    // Treasury management
    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }
    
    function setTreasuryFee(uint256 _fee) external onlyOwner {
        if (_fee > 500) revert FeeTooHigh(); // Max 5%
        treasuryFee = _fee;
    }

    /**
    * @notice Calculates and transfers the fee to the treasury
    * @param user Address of the user
    * @param token Address of the token
    * @param amount Amount of tokens to calculate fee for
    * @return Amount after fee deduction
    */
    function calculateAndTransferFee(address user, address token, uint256 amount) external onlyModule returns (uint256) {
        return _calculateAndTransferFee(user, token, amount);
    }

    function _calculateAndTransferFee(address user, address token, uint256 amount) internal returns (uint256) {
        uint256 fee = (amount * treasuryFee) / 10000;
        
        if (fee > 0) {
            _savings[treasury][token] += fee;
            return amount - fee;
        }
        
        return amount;
    }
    

    function getUserSavingStrategy(address user) external view returns (
        uint256 percentage,
        uint256 autoIncrement,
        uint256 maxPercentage,
        uint256 goalAmount,
        bool roundUpSavings,
        bool enableDCA,
        SavingsTokenType savingsTokenType,
        address specificSavingsToken
    ) {
        SavingStrategy storage strategy = _userSavingStrategies[user];
        return (
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
    /**
    * @notice Sets the user's saving strategy
    * @param user Address of the user
    * @param percentage Base percentage to save (0-100%)
    * @param autoIncrement Percentage to increase after each swap
    * @param maxPercentage Maximum percentage cap for auto-increments
    * @param goalAmount Target savings goal for each token
    */
    function setUserSavingStrategy(
        address user,
        uint256 percentage,
        uint256 autoIncrement,
        uint256 maxPercentage,
        uint256 goalAmount,
        bool roundUpSavings,
        bool enableDCA,
        SavingsTokenType savingsTokenType,
        address specificSavingsToken
    ) external onlyModule {
        SavingStrategy storage strategy = _userSavingStrategies[user];
        strategy.percentage = percentage;
        strategy.autoIncrement = autoIncrement;
        strategy.maxPercentage = maxPercentage;
        strategy.goalAmount = goalAmount;
        strategy.roundUpSavings = roundUpSavings;
        strategy.enableDCA = enableDCA;
        strategy.savingsTokenType = savingsTokenType;
        strategy.specificSavingsToken = specificSavingsToken;
    }
    
    /**
    * @notice Getter for savings
    * @param user Address of the user
    * @param token Address of the token
    * @return Amount of savings
    */
    function savings(address user, address token) external view returns (uint256) {
        return _savings[user][token];
    }
    /**
    * @notice Sets the savings
    * @param user Address of the user
    * @param token Address of the token
    * @param amount Amount of savings to set
    */
    function setSavings(address user, address token, uint256 amount) external onlyModule {
        _savings[user][token] = amount;
    }
    
    function increaseSavings(address user, address token, uint256 amount) external onlyModule {
        _savings[user][token] += amount;
    }
    
    function decreaseSavings(address user, address token, uint256 amount) external onlyModule {
        if (_savings[user][token] < amount) revert InsufficientSavings();
        _savings[user][token] -= amount;
    }
    
    // Getters and setters for savings data
    function getSavingsData(address user, address token) external view returns (
        uint256 totalSaved,
        uint256 lastSaveTime,
        uint256 swapCount,
        uint256 targetSellPrice
    ) {
        SavingsData storage data = _savingsData[user][token];
        return (
            data.totalSaved,
            data.lastSaveTime,
            data.swapCount,
            data.targetSellPrice
        );
    }
    
    /**
    * @notice Sets the savings data
    * @param user Address of the user
    * @param token Address of the token
    * @param totalSaved Amount of savings
    * @param lastSaveTime Last save time
    * @param swapCount Number of swaps
    * @param targetSellPrice Target sell price
    */
    function setSavingsData(
        address user,
        address token,
        uint256 totalSaved,
        uint256 lastSaveTime,
        uint256 swapCount,
        uint256 targetSellPrice
    ) external onlyModule {
        SavingsData storage data = _savingsData[user][token];
        data.totalSaved = totalSaved;
        data.lastSaveTime = lastSaveTime;
        data.swapCount = swapCount;
        data.targetSellPrice = targetSellPrice;
    }

    /**
    * @notice Updates the savings data
    * @param user Address of the user
    * @param token Address of the token
    * @param additionalSaved Amount of additional savings
    */
    function updateSavingsData(
        address user,
        address token,
        uint256 additionalSaved
    ) external onlyModule {
        SavingsData storage data = _savingsData[user][token];
        data.totalSaved += additionalSaved;
        data.lastSaveTime = block.timestamp;
        data.swapCount++;
    }

    // Daily savings configuration
    function getDailySavingsConfig(address user, address token) external view returns (
        bool enabled,
        uint256 lastExecutionTime,
        uint256 startTime,
        uint256 goalAmount,
        uint256 currentAmount,
        uint256 penaltyBps,
        uint256 endTime
    ) {
        DailySavingsConfig storage config = _dailySavingsConfig[user][token];
        return (
            config.enabled,
            config.lastExecutionTime,
            config.startTime,
            config.goalAmount,
            config.currentAmount,
            config.penaltyBps,
            config.endTime
        );
    }


    function setDailySavingsConfig(
        address user,
        address token,
        DailySavingsConfigParams calldata params
    ) external onlyModule {
        DailySavingsConfig storage config = _dailySavingsConfig[user][token];
        
        // Initialize if first time
        if (!config.enabled && params.enabled) {
            _initializeDailySavings(user, token);
        }
        
        // Update the configuration
        _updateDailySavingsConfig(config, params);
    }

    // Helper functions
    function _initializeDailySavings(address user, address token) internal {
        DailySavingsConfig storage config = _dailySavingsConfig[user][token];
        config.startTime = block.timestamp;
        config.lastExecutionTime = block.timestamp;
        
        _addTokenIfNotExists(user, token);
    }

    function _updateDailySavingsConfig(DailySavingsConfig storage config, DailySavingsConfigParams calldata params) internal {
        config.enabled = params.enabled;
        config.goalAmount = params.goalAmount;
        config.currentAmount = params.currentAmount;
        config.penaltyBps = params.penaltyBps;
        config.endTime = params.endTime;
    }

    function _addTokenIfNotExists(address user, address token) internal {
        bool tokenExists = false;
        address[] storage userTokens = _userSavingsTokens[user];
        for (uint i = 0; i < userTokens.length; i++) {
            if (userTokens[i] == token) {
                tokenExists = true;
                break;
            }
        }
        if (!tokenExists) {
            userTokens.push(token);
        }
    }

    function getDailySavingsAmount(address user, address token) external view returns (uint256) {
        return _dailySavingsAmount[user][token];
    }

    function setDailySavingsAmount(address user, address token, uint256 amount) external onlyModule {
        _dailySavingsAmount[user][token] = amount;
    }

    function getUserSavingsTokens(address user) external view returns (address[] memory) {
        return _userSavingsTokens[user];
    }

    function updateDailySavingsExecution(address user, address token, uint256 amount) external onlyModule {
        DailySavingsConfig storage config = _dailySavingsConfig[user][token];
        config.lastExecutionTime = block.timestamp;
        config.currentAmount += amount;
    }

    function getDailySavingsYieldStrategy(address user, address token) external view returns (YieldStrategy) {
        return _dailySavingsYieldStrategy[user][token];
    }

    function setDailySavingsYieldStrategy(address user, address token, YieldStrategy strategy) external onlyModule {
        _dailySavingsYieldStrategy[user][token] = strategy;
    }
    
    // Withdrawal timelock
    function withdrawalTimelock(address user) external view returns (uint256) {
        return _withdrawalTimelock[user];
    }
    
    function setWithdrawalTimelock(address user, uint256 timelock) external onlyModule {
        _withdrawalTimelock[user] = timelock;
    }
    
    // DCA target token
    function dcaTargetToken(address user) external view returns (address) {
        return _dcaTargetToken[user];
    }
    
    function setDcaTargetToken(address user, address token) external onlyModule {
        _dcaTargetToken[user] = token;
    }
    
    // DCA tick strategies
    function getDcaTickStrategy(address user) external view returns (
        int24 tickDelta,
        uint256 tickExpiryTime,
        bool onlyImprovePrice,
        int24 minTickImprovement,
        bool dynamicSizing,
        uint256 customSlippageTolerance
    ) {
        DCATickStrategy storage strategy = _dcaTickStrategies[user];
        return (
            strategy.tickDelta,
            strategy.tickExpiryTime,
            strategy.onlyImprovePrice,
            strategy.minTickImprovement,
            strategy.dynamicSizing,
            strategy.customSlippageTolerance
        );
    }
    
    function setDcaTickStrategy(
        address user,
        int24 tickDelta,
        uint256 tickExpiryTime,
        bool onlyImprovePrice,
        int24 minTickImprovement,
        bool dynamicSizing,
        uint256 customSlippageTolerance
    ) external onlyModule {
        DCATickStrategy storage strategy = _dcaTickStrategies[user];
        strategy.tickDelta = tickDelta;
        strategy.tickExpiryTime = tickExpiryTime;
        strategy.onlyImprovePrice = onlyImprovePrice;
        strategy.minTickImprovement = minTickImprovement;
        strategy.dynamicSizing = dynamicSizing;
        strategy.customSlippageTolerance = customSlippageTolerance;
    }
    
    // DCA queue operations
    function getDcaQueueLength(address user) external view returns (uint256) {
        return _dcaQueue[user].length;
    }
    
    function getDcaQueueItem(address user, uint256 index) external view returns (
        address fromToken,
        address toToken,
        uint256 amount,
        int24 executionTick,
        uint256 deadline,
        bool executed,
        uint256 customSlippageTolerance
    ) {
        if (index >= _dcaQueue[user].length) revert IndexOutOfBounds();
        DCAExecution storage execution = _dcaQueue[user][index];
        return (
            execution.fromToken,
            execution.toToken,
            execution.amount,
            execution.executionTick,
            execution.deadline,
            execution.executed,
            execution.customSlippageTolerance
        );
    }
    
    function addToDcaQueue(
        address user,
        address fromToken,
        address toToken,
        uint256 amount,
        int24 executionTick,
        uint256 deadline,
        uint256 customSlippageTolerance
    ) external onlyModule {
        _dcaQueue[user].push(DCAExecution({
            fromToken: fromToken,
            toToken: toToken,
            amount: amount,
            executionTick: executionTick,
            deadline: deadline,
            executed: false,
            customSlippageTolerance: customSlippageTolerance
        }));
    }
    
    function markDcaExecuted(address user, uint256 index) external onlyModule {
        if (index >= _dcaQueue[user].length) revert IndexOutOfBounds();
        _dcaQueue[user][index].executed = true;
    }
    
    // Pool ticks
    function poolTicks(PoolId poolId) external view returns (int24) {
        return _poolTicks[poolId];
    }

    /**
    * @notice Creates a pool key with custom parameters
    * @param tokenA First token address
    * @param tokenB Second token address
    * @param feeTier Fee tier (e.g., 3000 for 0.3%)
    * @param tickSpacing Tick spacing for the pool
    * @return Pool key for the specified parameters
    */
    function createPoolKey(
        address tokenA, 
        address tokenB, 
        uint24 feeTier, 
        int24 tickSpacing
    ) public pure returns (PoolKey memory) {
        // Ensure tokens are in correct order
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: feeTier,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0)) // No hooks for this swap to avoid recursive calls
        });
    }

    function createPoolKey(address tokenA, address tokenB) public pure returns (PoolKey memory) {
        return createPoolKey(tokenA, tokenB, 3000, 60); // Default 0.3% fee tier and 60 tick spacing
    }
    
    function setPoolTick(PoolId poolId, int24 tick) external onlyModule {
        _poolTicks[poolId] = tick;
    }
    
    // SwapContext accessors
    function getSwapContext(address user) external view onlyModule returns (SwapContext memory) {
        return _swapContexts[user];
    }
    
    function setSwapContext(address user, SwapContext memory context) external onlyModule {
        _swapContexts[user] = context;
    }
    
    function deleteSwapContext(address user) external onlyModule {
        delete _swapContexts[user];
    }
    
    // Yield strategies
    function getYieldStrategy(address user, address token) external view returns (YieldStrategy) {
        return _yieldStrategies[user][token];
    }
    
    function setYieldStrategy(address user, address token, YieldStrategy strategy) external onlyModule {
        _yieldStrategies[user][token] = strategy;
    }
    
    // Slippage settings
    function userSlippageTolerance(address user) external view returns (uint256) {
        return _userSlippageTolerance[user];
    }
    
    function setUserSlippageTolerance(address user, uint256 tolerance) external onlyModule {
        _userSlippageTolerance[user] = tolerance;
    }
    
    function tokenSlippageTolerance(address user, address token) external view returns (uint256) {
        return _tokenSlippageTolerance[user][token];
    }
    
    function setTokenSlippageTolerance(address user, address token, uint256 tolerance) external onlyModule {
        _tokenSlippageTolerance[user][token] = tolerance;
    }
    
    function slippageExceededAction(address user) external view returns (SlippageAction) {
        return _slippageExceededAction[user];
    }
    
    function setSlippageExceededAction(address user, SlippageAction action) external onlyModule {
        _slippageExceededAction[user] = action;
    }
    
    function setDefaultSlippageTolerance(uint256 tolerance) external onlyModule {
        defaultSlippageTolerance = tolerance;
    }
    
    // ERC6909 storage accessors
    function getBalance(address user, uint256 id) external view onlyModule returns (uint256) {
        return _balances[user][id];
    }
    
    function setBalance(address user, uint256 id, uint256 amount) external onlyModule {
        _balances[user][id] = amount;
    }
    
    function increaseBalance(address user, uint256 id, uint256 amount) external onlyModule {
        _balances[user][id] += amount;
    }
    
    function decreaseBalance(address user, uint256 id, uint256 amount) external onlyModule {
        if (_balances[user][id] < amount) revert InsufficientBalance();
        _balances[user][id] -= amount;
    }
    
    function getAllowance(address tokenOwner, address spender, uint256 id) external view onlyModule returns (uint256) {
        return _allowances[tokenOwner][spender][id];
    }
    
    function setAllowance(address tokenOwner, address spender, uint256 id, uint256 amount) external onlyModule {
        _allowances[tokenOwner][spender][id] = amount;
    }
    
    function tokenToId(address token) external view returns (uint256) {
        return _tokenToId[token];
    }
    
    function setTokenToId(address token, uint256 id) external onlyModule {
        _tokenToId[token] = id;
    }
    
    function idToToken(uint256 id) external view returns (address) {
        return _idToToken[id];
    }
    
    function setIdToToken(uint256 id, address token) external onlyModule {
        _idToToken[id] = token;
    }
    
    function getNextTokenId() external view onlyModule returns (uint256) {
        return _nextTokenId;
    }
    
    function incrementNextTokenId() external onlyModule returns (uint256) {
        return _nextTokenId++;
    }
}