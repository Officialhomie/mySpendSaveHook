// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SpendSaveStorage} from "../../src/SpendSaveStorage.sol";
import {SpendSaveHook} from "../../src/SpendSaveHook.sol";
import {Savings} from "../../src/Savings.sol";
import {SavingStrategy} from "../../src/SavingStrategy.sol";
import {DCA} from "../../src/DCA.sol";
import {DailySavings} from "../../src/DailySavings.sol";
import {SlippageControl} from "../../src/SlippageControl.sol";
import {Token} from "../../src/Token.sol";

/// @notice Minimal ERC20 used for invariant fuzzing tokens.
contract TestToken is ERC20 {
    constructor(string memory name, string memory symbol, uint256 initialSupply) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }

    /// @notice Mint tokens for testing
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Stub PoolManager
contract MockPoolManager {
    function take(Currency, address, uint256) external {}
}

/// @notice Registry to track fuzzed users/tokens and expected accounting totals.
contract InvariantStateRegistry {
    address[] private _users;
    mapping(address => bool) private _userSeen;

    address[] private _tokens;
    mapping(address => bool) private _tokenSeen;

    mapping(address => mapping(address => uint256)) public expectedNetSavings;
    mapping(address => mapping(address => uint256)) public expectedGrossSavings;
    mapping(address => uint256) public expectedTreasuryFees;

    mapping(address => mapping(address => uint256)) public lastDailyExecution;

    // Withdrawal tracking
    struct WithdrawalRecord {
        address user;
        address caller;
        address token;
        uint256 amount;
    }
    WithdrawalRecord[] public withdrawals;

    // Transfer tracking
    struct TransferRecord {
        address from;
        address to;
        uint256 tokenId;
        uint256 balancesBefore;
        uint256 balancesAfter;
    }
    TransferRecord[] public transfers;

    // Mint/Burn tracking
    mapping(uint256 => uint256) public totalMinted;
    mapping(uint256 => uint256) public totalBurned;

    // DCA execution tracking
    struct DcaExecution {
        address user;
        uint256 queueIndex;
        uint256 inputAmount;
        uint256 outputAmount;
    }
    mapping(address => mapping(uint256 => DcaExecution)) public dcaExecutions;

    // Access control violation tracking
    mapping(address => mapping(string => uint256)) public unauthorizedAccessAttempts;

    // Module modification tracking
    address[] private _modules;
    mapping(address => bool) private _moduleSeen;
    mapping(address => uint256) public moduleModificationCount;
    mapping(bytes32 => uint256) public moduleRegistryChanges;

    // Strategy setter tracking
    mapping(address => address) public strategySetter;

    // Transient context tracking
    address[] public transientContextModifiers;

    // Expected total deposits/withdrawals tracking
    mapping(address => uint256) public expectedTotalDeposits;
    mapping(address => uint256) public expectedTotalWithdrawals;

    // Daily savings execution tracking
    struct DailyExecutionRecord {
        address user;
        address token;
        uint256 amount;
        uint256 daysPassed;
        uint256 balanceBefore;
        uint256 allowanceBefore;
        uint256 currentAmountBefore;
        string skipReason;
    }
    DailyExecutionRecord[] public dailyExecutions;

    // Daily savings withdrawal tracking
    struct DailyWithdrawalRecord {
        address user;
        address token;
        uint256 withdrawnAmount;
        uint256 penalty;
        uint256 netReceived;
        uint256 treasuryBefore;
        uint256 treasuryAfter;
    }
    DailyWithdrawalRecord[] public dailyWithdrawals;

    // Daily deposits/withdrawals
    mapping(address => mapping(address => uint256)) public expectedDailyDeposits;
    mapping(address => mapping(address => uint256)) public expectedDailyWithdrawals;

    // Goal tracking
    mapping(address => mapping(address => bool)) public wasGoalReached;
    mapping(address => mapping(address => bool)) public goalReachedEventEmitted;

    // Execution counts
    mapping(address => mapping(address => uint256)) public executionCount;

    // Batch execution tracking
    struct BatchExecutionRecord {
        address user;
        uint256 tokensProcessed;
        uint256 totalTokens;
        uint256 gasUsed;
    }
    BatchExecutionRecord[] public batchExecutions;

    // Previous amounts for accumulation testing
    mapping(address => mapping(address => uint256)) public previousDailyAmount;

    // Amount at execution tracking
    mapping(address => mapping(address => mapping(uint256 => uint256))) public amountAtExecution;

    // Config at execution tracking
    struct ConfigAtExecution {
        uint256 goalAmount;
        uint256 currentAmountBefore;
        uint256 dailyAmount;
    }
    mapping(uint256 => ConfigAtExecution) public configAtExecution;

    function addUser(address user) external {
        if (user == address(0)) return;
        if (!_userSeen[user]) {
            _userSeen[user] = true;
            _users.push(user);
        }
    }

    function addToken(address token) external {
        if (token == address(0)) return;
        if (!_tokenSeen[token]) {
            _tokenSeen[token] = true;
            _tokens.push(token);
        }
    }

    function addModule(address module) external {
        if (module == address(0)) return;
        if (!_moduleSeen[module]) {
            _moduleSeen[module] = true;
            _modules.push(module);
        }
    }

    function usersLength() external view returns (uint256) {
        return _users.length;
    }

    function tokensLength() external view returns (uint256) {
        return _tokens.length;
    }

    function totalModules() external view returns (uint256) {
        return _modules.length;
    }

    function userAt(uint256 index) external view returns (address) {
        return _users[index];
    }

    function tokenAt(uint256 index) external view returns (address) {
        return _tokens[index];
    }

    function moduleAt(uint256 index) external view returns (address) {
        return _modules[index];
    }

    function recordNet(address user, address token, uint256 amount) external {
        expectedNetSavings[user][token] += amount;
    }

    function recordGross(address user, address token, uint256 amount) external {
        expectedGrossSavings[user][token] += amount;
    }

    function recordTreasury(address token, uint256 amount) external {
        expectedTreasuryFees[token] += amount;
    }

    function updateLastDaily(address user, address token, uint256 timestamp) external {
        lastDailyExecution[user][token] = timestamp;
    }

    // Withdrawal tracking
    function recordWithdrawal(address user, address caller, address token, uint256 amount) external {
        withdrawals.push(WithdrawalRecord(user, caller, token, amount));
        expectedTotalWithdrawals[token] += amount;
    }

    function totalWithdrawals() external view returns (uint256) {
        return withdrawals.length;
    }

    function getWithdrawal(uint256 index) external view returns (
        address user,
        address caller,
        address token,
        uint256 amount
    ) {
        WithdrawalRecord memory w = withdrawals[index];
        return (w.user, w.caller, w.token, w.amount);
    }

    // Transfer tracking
    function recordTransfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 balancesBefore,
        uint256 balancesAfter
    ) external {
        transfers.push(TransferRecord(from, to, tokenId, balancesBefore, balancesAfter));
    }

    function transferOperationCount() external view returns (uint256) {
        return transfers.length;
    }

    function getTransferOperation(uint256 index) external view returns (
        address from,
        address to,
        uint256 tokenId,
        uint256 balancesBefore,
        uint256 balancesAfter
    ) {
        TransferRecord memory t = transfers[index];
        return (t.from, t.to, t.tokenId, t.balancesBefore, t.balancesAfter);
    }

    // Mint/Burn tracking
    function recordMint(uint256 tokenId, uint256 amount) external {
        totalMinted[tokenId] += amount;
    }

    function recordBurn(uint256 tokenId, uint256 amount) external {
        totalBurned[tokenId] += amount;
    }

    // DCA execution tracking
    function recordDcaExecution(
        address user,
        uint256 queueIndex,
        uint256 inputAmount,
        uint256 outputAmount
    ) external {
        dcaExecutions[user][queueIndex] = DcaExecution(user, queueIndex, inputAmount, outputAmount);
    }

    function dcaOutputAmount(address user, uint256 queueIndex) external view returns (uint256) {
        return dcaExecutions[user][queueIndex].outputAmount;
    }

    // Access control violation tracking
    function recordUnauthorizedAccess(address attacker, string memory function_) external {
        unauthorizedAccessAttempts[attacker][function_]++;
    }

    // Module modification tracking
    function recordModuleModification(address module) external {
        moduleModificationCount[module]++;
    }

    function recordRegistryChange(bytes32 moduleId) external {
        moduleRegistryChanges[moduleId]++;
    }

    // Strategy setter tracking
    function recordStrategySet(address user, address setter) external {
        strategySetter[user] = setter;
    }

    // Transient context tracking
    function recordTransientContextModification(address modifier_) external {
        transientContextModifiers.push(modifier_);
    }

    function transientContextModifications() external view returns (uint256) {
        return transientContextModifiers.length;
    }

    function transientContextModifier(uint256 index) external view returns (address) {
        return transientContextModifiers[index];
    }

    // Expected total tracking
    function recordDeposit(address token, uint256 amount) external {
        expectedTotalDeposits[token] += amount;
    }

    // Daily savings recording functions
    function recordDailyExecution(
        address user,
        address token,
        uint256 amount,
        uint256 daysPassed
    ) external {
        dailyExecutions.push(DailyExecutionRecord({
            user: user,
            token: token,
            amount: amount,
            daysPassed: daysPassed,
            balanceBefore: 0,
            allowanceBefore: 0,
            currentAmountBefore: 0,
            skipReason: ""
        }));
        executionCount[user][token]++;
    }

    function recordExecutionState(
        address user,
        address token,
        uint256 balanceBefore,
        uint256 allowanceBefore,
        uint256 currentAmountBefore
    ) external {
        uint256 lastIndex = dailyExecutions.length - 1;
        dailyExecutions[lastIndex].balanceBefore = balanceBefore;
        dailyExecutions[lastIndex].allowanceBefore = allowanceBefore;
        dailyExecutions[lastIndex].currentAmountBefore = currentAmountBefore;
    }

    function recordExecutionSkip(address user, address token, string memory reason) external {
        dailyExecutions.push(DailyExecutionRecord({
            user: user,
            token: token,
            amount: 0,
            daysPassed: 0,
            balanceBefore: 0,
            allowanceBefore: 0,
            currentAmountBefore: 0,
            skipReason: reason
        }));
    }

    function recordDailyDeposit(address user, address token, uint256 amount) external {
        expectedDailyDeposits[user][token] += amount;
    }

    function recordDailyWithdrawal(
        address user,
        address token,
        uint256 withdrawnAmount,
        uint256 penalty,
        uint256 netReceived,
        uint256 treasuryBefore,
        uint256 treasuryAfter
    ) external {
        dailyWithdrawals.push(DailyWithdrawalRecord({
            user: user,
            token: token,
            withdrawnAmount: withdrawnAmount,
            penalty: penalty,
            netReceived: netReceived,
            treasuryBefore: treasuryBefore,
            treasuryAfter: treasuryAfter
        }));
    }

    function recordDailyWithdrawalTotal(address user, address token, uint256 amount) external {
        expectedDailyWithdrawals[user][token] += amount;
    }

    function recordGoalReached(address user, address token) external {
        wasGoalReached[user][token] = true;
    }

    function recordGoalEvent(address user, address token) external {
        goalReachedEventEmitted[user][token] = true;
    }

    function recordBatchExecution(
        address user,
        uint256 tokensProcessed,
        uint256 totalTokens,
        uint256 gasUsed
    ) external {
        batchExecutions.push(BatchExecutionRecord({
            user: user,
            tokensProcessed: tokensProcessed,
            totalTokens: totalTokens,
            gasUsed: gasUsed
        }));
    }

    function updatePreviousAmount(address user, address token, uint256 amount) external {
        previousDailyAmount[user][token] = amount;
    }

    function recordAmountAtExecution(address user, address token, uint256 executionIndex, uint256 amount) external {
        amountAtExecution[user][token][executionIndex] = amount;
    }

    function recordConfigAtExecution(
        uint256 executionIndex,
        uint256 goalAmount,
        uint256 currentAmountBefore,
        uint256 dailyAmount
    ) external {
        configAtExecution[executionIndex] = ConfigAtExecution({
            goalAmount: goalAmount,
            currentAmountBefore: currentAmountBefore,
            dailyAmount: dailyAmount
        });
    }

    // Getter functions
    function totalDailyExecutions() external view returns (uint256) {
        return dailyExecutions.length;
    }

    function getDailyExecution(uint256 index) external view returns (
        address user,
        address token,
        uint256 amount,
        uint256 daysPassed
    ) {
        DailyExecutionRecord memory record = dailyExecutions[index];
        return (record.user, record.token, record.amount, record.daysPassed);
    }

    function executionSkipReason(uint256 index) external view returns (string memory) {
        return dailyExecutions[index].skipReason;
    }

    function balanceBeforeExecution(uint256 index) external view returns (uint256) {
        return dailyExecutions[index].balanceBefore;
    }

    function allowanceBeforeExecution(uint256 index) external view returns (uint256) {
        return dailyExecutions[index].allowanceBefore;
    }

    function amountBeforeExecution(uint256 index) external view returns (uint256) {
        return dailyExecutions[index].currentAmountBefore;
    }

    function totalDailyWithdrawals() external view returns (uint256) {
        return dailyWithdrawals.length;
    }

    function getDailyWithdrawal(uint256 index) external view returns (
        address user,
        address token,
        uint256 withdrawnAmount,
        uint256 penalty,
        uint256 netReceived
    ) {
        DailyWithdrawalRecord memory record = dailyWithdrawals[index];
        return (record.user, record.token, record.withdrawnAmount, record.penalty, record.netReceived);
    }

    function treasuryBalanceBefore(uint256 index, address) external view returns (uint256) {
        return dailyWithdrawals[index].treasuryBefore;
    }

    function treasuryBalanceAfter(uint256 index, address) external view returns (uint256) {
        return dailyWithdrawals[index].treasuryAfter;
    }

    function totalBatchExecutions() external view returns (uint256) {
        return batchExecutions.length;
    }

    function getBatchExecution(uint256 index) external view returns (
        address user,
        uint256 tokensProcessed,
        uint256 totalTokens,
        uint256 gasUsed
    ) {
        BatchExecutionRecord memory record = batchExecutions[index];
        return (record.user, record.tokensProcessed, record.totalTokens, record.gasUsed);
    }

    function hadWithdrawal(address user, address token) external view returns (bool) {
        return expectedDailyWithdrawals[user][token] > 0;
    }
}

/// @notice Unified handler driving protocol interactions during invariant runs.
contract SpendSaveHandler is StdUtils {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    SpendSaveStorage public immutable storage_;
    SpendSaveHook public immutable hook;
    Savings public immutable savings;
    SavingStrategy public immutable savingStrategy;
    DCA public immutable dca;
    DailySavings public immutable dailySavings;
    SlippageControl public immutable slippage;
    Token public immutable tokenModule;
    InvariantStateRegistry public immutable registry;
    TestToken[] public testTokens;

    uint256 private constant MAX_WITHDRAWAL_TIMELOCK = 30 days;
    uint256 private constant MAX_USER_SLIPPAGE = 1000; // 10%
    uint256 private constant MAX_DEFAULT_SLIPPAGE = 500; // 5%

    function _selectActiveUser(uint256 seed) internal view returns (address) {
        uint256 len = registry.usersLength();
        if (len == 0) return address(0);
        address treasury = storage_.treasury();
        address owner = storage_.owner();

        for (uint256 i = 0; i < len; i++) {
            address candidate = registry.userAt((seed + i) % len);
            if (candidate != treasury && candidate != owner) {
                return candidate;
            }
        }
        return address(0);
    }

    constructor(
        SpendSaveStorage storageContract,
        SpendSaveHook hookContract,
        Savings savingsModule,
        SavingStrategy savingStrategyModule,
        DCA dcaModule,
        DailySavings dailyModule,
        SlippageControl slippageModule,
        Token tokenModule_,
        InvariantStateRegistry registry_,
        TestToken[] memory tokens_
    ) {
        storage_ = storageContract;
        hook = hookContract;
        savings = savingsModule;
        savingStrategy = savingStrategyModule;
        dca = dcaModule;
        dailySavings = dailyModule;
        slippage = slippageModule;
        tokenModule = tokenModule_;
        registry = registry_;
        testTokens = tokens_;

        registry.addUser(storage_.owner());
        registry.addUser(storage_.treasury());

        for (uint256 i = 0; i < tokens_.length; i++) {
            registry.addToken(address(tokens_[i]));
        }
    }

    // ===== User & Token seeding =====

    function seedUser(uint256 seed) external {
        address user = address(uint160(uint256(keccak256(abi.encodePacked(seed, "user")))));
        registry.addUser(user);
    }

    function registerToken(uint256 tokenIndex) external {
        uint256 idx = bound(tokenIndex, 0, testTokens.length - 1);
        address tokenAddress = address(testTokens[idx]);
        registry.addToken(tokenAddress);
        tokenModule.registerToken(tokenAddress);
    }

    // ===== Saving strategy configuration =====

    function configureStrategy(uint256 userIndex, uint256 percentage, uint256 maxPercentage, uint8 tokenTypeSeed)
        external
    {
        address user = _selectActiveUser(userIndex);
        if (user == address(0)) return;

        uint256 pct = bound(percentage, 0, 10000);
        uint256 maxPct = bound(maxPercentage, pct, 10000);

        SpendSaveStorage.SavingsTokenType tokenType = SpendSaveStorage.SavingsTokenType(bound(tokenTypeSeed, 0, 2));
        address specificToken = address(0);
        if (tokenType == SpendSaveStorage.SavingsTokenType.SPECIFIC && registry.tokensLength() > 0) {
            specificToken = registry.tokenAt(tokenTypeSeed % registry.tokensLength());
        }

        vm.startPrank(user);
        try savingStrategy.setSavingStrategy(user, pct, 0, maxPct, false, tokenType, specificToken) {
        // Intentionally blank
        }
            catch {
            // ignore invalid combos
        }
        vm.stopPrank();
    }

    // ===== Savings processing =====

    function processSavings(uint256 userIndex, uint256 tokenIndex, uint256 rawAmount) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0) || registry.tokensLength() == 0) return;

        address tokenAddress = registry.tokenAt(tokenIndex % registry.tokensLength());
        uint256 amount = bound(rawAmount, 1e6, 1e18);

        // Fix: Mint tokens to user first (simulating they have funds)
        TestToken(tokenAddress).mint(user, amount);

        // Fix: Transfer tokens from user to storage (simulating swap flow)
        // In real swaps, hook transfers tokens to storage before processing
        vm.startPrank(user);
        TestToken(tokenAddress).approve(address(storage_), amount);
        SafeERC20.safeTransferFrom(IERC20(tokenAddress), user, address(storage_), amount);
        vm.stopPrank();

        // Simulate transient context write as hook would do.
        vm.prank(address(hook));
        storage_.setTransientSwapContext(
            user, uint128(amount), uint128(1000), true, uint8(SpendSaveStorage.SavingsTokenType.INPUT), false, false
        );

        SpendSaveStorage.SwapContext memory ctx = SpendSaveStorage.SwapContext({
            hasStrategy: true,
            currentPercentage: 1000,
            inputAmount: amount,
            inputToken: tokenAddress,
            roundUpSavings: false,
            enableDCA: false,
            dcaTargetToken: address(0),
            currentTick: 0,
            savingsTokenType: SpendSaveStorage.SavingsTokenType.INPUT,
            specificSavingsToken: address(0),
            pendingSaveAmount: amount
        });

        bool processed;
        uint256 netAmount;

        vm.startPrank(address(hook));
        try savings.processSavings(user, tokenAddress, amount, ctx) returns (uint256 net) {
            processed = true;
            netAmount = net;
        } catch {
            processed = false;
        }
        vm.stopPrank();

        if (processed) {
            uint256 feeAmount = amount - netAmount;
            registry.recordGross(user, tokenAddress, amount);
            registry.recordNet(user, tokenAddress, netAmount);
            registry.recordTreasury(tokenAddress, feeAmount);
            
            // Fix: Track total deposits for solvency checks
            registry.recordDeposit(tokenAddress, amount);
        }

        vm.prank(address(hook));
        storage_.clearTransientSwapContext(user);
    }

    // ===== Timelock management =====

    function setWithdrawalTimelock(uint256 userIndex, uint256 futureSeconds) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0)) return;
        uint256 lockDuration = bound(futureSeconds, 0, MAX_WITHDRAWAL_TIMELOCK);

        vm.startPrank(address(savings));
        storage_.setWithdrawalTimelock(user, block.timestamp + lockDuration);
        vm.stopPrank();
    }

    // ===== DCA queue operations =====

    function enqueueDca(
        uint256 userIndex,
        uint256 fromTokenIndex,
        uint256 toTokenIndex,
        uint256 amount,
        uint256 deadlineOffset
    ) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0) || registry.tokensLength() == 0) return;
        address fromToken = registry.tokenAt(fromTokenIndex % registry.tokensLength());
        address toToken = registry.tokenAt(toTokenIndex % registry.tokensLength());

        uint256 boundedAmount = bound(amount, 1e4, 1e20);
        uint256 deadline = block.timestamp + bound(deadlineOffset, 1 minutes, 30 days);

        vm.startPrank(address(dca));
        storage_.addToDcaQueue(user, fromToken, toToken, boundedAmount, 0, deadline, 50);
        vm.stopPrank();
    }

    function markDcaExecuted(uint256 userIndex, uint256 itemIndex) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0)) return;
        uint256 length = storage_.getDcaQueueLength(user);
        if (length == 0) return;
        uint256 idx = itemIndex % length;

        vm.startPrank(address(dca));
        try storage_.markDcaExecuted(user, idx) {
        // noop
        }
            catch {
            // ignore
        }
        vm.stopPrank();
    }

    // ===== Daily savings =====

    function configureDailySavings(uint256 userIndex, uint256 tokenIndex, uint256 dailyAmount) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0) || registry.tokensLength() == 0) return;
        address tokenAddress = registry.tokenAt(tokenIndex % registry.tokensLength());
        uint256 amount = bound(dailyAmount, 0, 1e20);

        // Fix: Get current amount first to ensure goal >= current
        (bool existingEnabled, , , , uint256 existingCurrent, ,) = 
            storage_.getDailySavingsConfig(user, tokenAddress);
        
        uint256 currentAmount = existingCurrent;
        uint256 goalAmount = amount * 10;
        
        // Fix: Ensure goal is always >= current amount
        if (goalAmount < currentAmount) {
            goalAmount = currentAmount;
        }

        SpendSaveStorage.DailySavingsConfigParams memory params = SpendSaveStorage.DailySavingsConfigParams({
            enabled: true,
            lastExecutionTime: registry.lastDailyExecution(user, tokenAddress),
            startTime: block.timestamp,
            goalAmount: goalAmount,
            currentAmount: currentAmount,
            penaltyBps: 100,
            endTime: block.timestamp + 365 days
        });

        vm.startPrank(address(dailySavings));
        storage_.setDailySavingsAmount(user, tokenAddress, amount);
        storage_.setDailySavingsConfig(user, tokenAddress, params);
        vm.stopPrank();

        // Record the initial currentAmount as a deposit for value conservation (only if new)
        if (amount > 0 && !existingEnabled) {
            registry.recordDailyDeposit(user, tokenAddress, currentAmount);
        }
    }

    function updateDailyExecution(uint256 userIndex, uint256 tokenIndex, uint256 advanceSeconds) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0) || registry.tokensLength() == 0) return;
        address tokenAddress = registry.tokenAt(tokenIndex % registry.tokensLength());

        // Get current config to respect goal limits
        (bool enabled,, , uint256 goal, uint256 current,,) = storage_.getDailySavingsConfig(user, tokenAddress);

        // Only proceed if daily savings is enabled for this user/token
        if (!enabled) return;

        uint256 warpDelta = bound(advanceSeconds, 1, 1 days);
        vm.warp(block.timestamp + warpDelta);

        // Calculate safe amount that won't exceed goal
        uint256 amountToAdd = 1 ether;
        if (goal > 0) {
            uint256 remaining = goal > current ? goal - current : 0;
            if (remaining == 0) return; // Already at goal
            if (amountToAdd > remaining) amountToAdd = remaining;
        }

        vm.startPrank(address(dailySavings));
        storage_.updateDailySavingsExecution(user, tokenAddress, amountToAdd);
        vm.stopPrank();

        // Record the deposit for value conservation tracking
        registry.recordDailyDeposit(user, tokenAddress, amountToAdd);
        registry.updateLastDaily(user, tokenAddress, block.timestamp);
    }

    // ===== Slippage settings =====

    function setUserSlippage(uint256 userIndex, uint256 toleranceBps) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0)) return;
        uint256 tolerance = bound(toleranceBps, 0, MAX_USER_SLIPPAGE);

        vm.startPrank(user);
        slippage.setSlippageTolerance(user, tolerance);
        vm.stopPrank();
    }

    function setTokenSlippage(uint256 userIndex, uint256 tokenIndex, uint256 toleranceBps) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0) || registry.tokensLength() == 0) return;
        address tokenAddress = registry.tokenAt(tokenIndex % registry.tokensLength());
        uint256 tolerance = bound(toleranceBps, 0, MAX_USER_SLIPPAGE);

        vm.startPrank(user);
        slippage.setTokenSlippageTolerance(user, tokenAddress, tolerance);
        vm.stopPrank();
    }

    function setDefaultSlippage(uint256 toleranceBps) external {
        uint256 tolerance = bound(toleranceBps, 0, MAX_DEFAULT_SLIPPAGE);

        vm.startPrank(storage_.owner());
        storage_.setDefaultSlippageTolerance(tolerance);
        vm.stopPrank();
    }

    // ===== Time travel utility =====

    function advanceTime(uint256 secondsForward) external {
        uint256 delta = bound(secondsForward, 1, 30 days);
        vm.warp(block.timestamp + delta);
    }

    // ===== Withdrawal operations =====

    function withdraw(uint256 userIndex, uint256 tokenIndex, uint256 amount) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0) || registry.tokensLength() == 0) return;

        address token = registry.tokenAt(tokenIndex % registry.tokensLength());
        uint256 userSavings = storage_._savings(user, token);
        uint256 withdrawAmount = bound(amount, 0, userSavings);

        vm.startPrank(user);
        try savings.withdraw(user, token, withdrawAmount, false) {
            registry.recordWithdrawal(user, user, token, withdrawAmount);
        } catch {}
        vm.stopPrank();
    }

    // ===== ERC6909 Transfer operations =====

    function transferToken(
        uint256 fromIndex,
        uint256 toIndex,
        uint256 tokenIndex,
        uint256 amount
    ) external {
        address from = registry.userAt(fromIndex % registry.usersLength());
        address to = registry.userAt(toIndex % registry.usersLength());
        if (from == address(0) || to == address(0) || registry.tokensLength() == 0) return;

        address token = registry.tokenAt(tokenIndex % registry.tokensLength());
        uint256 tokenId = tokenModule.getTokenId(token);
        if (tokenId == 0) return;

        uint256 fromBalance = storage_.balanceOf(from, tokenId);
        uint256 toBalance = storage_.balanceOf(to, tokenId);
        uint256 balanceBefore = fromBalance + toBalance;

        uint256 transferAmount = bound(amount, 0, fromBalance);

        vm.startPrank(from);
        try storage_.transfer(to, tokenId, transferAmount) {
            uint256 fromBalanceAfter = storage_.balanceOf(from, tokenId);
            uint256 toBalanceAfter = storage_.balanceOf(to, tokenId);
            uint256 balanceAfter = fromBalanceAfter + toBalanceAfter;
            registry.recordTransfer(from, to, tokenId, balanceBefore, balanceAfter);
        } catch {}
        vm.stopPrank();
    }

    // ===== Mint/Burn tracking =====

    function burnTokens(uint256 userIndex, uint256 tokenIndex, uint256 amount) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0) || registry.tokensLength() == 0) return;

        address token = registry.tokenAt(tokenIndex % registry.tokensLength());
        uint256 tokenId = tokenModule.getTokenId(token);
        if (tokenId == 0) return;

        uint256 balance = storage_.balanceOf(user, tokenId);
        uint256 burnAmount = bound(amount, 0, balance);

        vm.startPrank(address(savings));
        try tokenModule.burnSavingsToken(user, tokenId, burnAmount) {
            registry.recordBurn(tokenId, burnAmount);
        } catch {}
        vm.stopPrank();
    }

    // Track mint in processSavings
    function processSavingsWithMint(uint256 userIndex, uint256 tokenIndex, uint256 rawAmount) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0) || registry.tokensLength() == 0) return;

        address tokenAddress = registry.tokenAt(tokenIndex % registry.tokensLength());
        uint256 amount = bound(rawAmount, 1e6, 1e18);

        // Fix: Mint tokens to user first (simulating they have funds)
        TestToken(tokenAddress).mint(user, amount);

        // Fix: Transfer tokens from user to storage (simulating swap flow)
        // In real swaps, hook transfers tokens to storage before processing
        vm.startPrank(user);
        TestToken(tokenAddress).approve(address(storage_), amount);
        SafeERC20.safeTransferFrom(IERC20(tokenAddress), user, address(storage_), amount);
        vm.stopPrank();

        vm.prank(address(hook));
        storage_.setTransientSwapContext(
            user, uint128(amount), uint128(1000), true, uint8(SpendSaveStorage.SavingsTokenType.INPUT), false, false
        );

        SpendSaveStorage.SwapContext memory ctx = SpendSaveStorage.SwapContext({
            hasStrategy: true,
            currentPercentage: 1000,
            inputAmount: amount,
            inputToken: tokenAddress,
            roundUpSavings: false,
            enableDCA: false,
            dcaTargetToken: address(0),
            currentTick: 0,
            savingsTokenType: SpendSaveStorage.SavingsTokenType.INPUT,
            specificSavingsToken: address(0),
            pendingSaveAmount: amount
        });

        bool processed;
        uint256 netAmount;

        vm.startPrank(address(hook));
        try savings.processSavings(user, tokenAddress, amount, ctx) returns (uint256 net) {
            processed = true;
            netAmount = net;
        } catch {
            processed = false;
        }
        vm.stopPrank();

        if (processed) {
            uint256 feeAmount = amount - netAmount;
            registry.recordGross(user, tokenAddress, amount);
            registry.recordNet(user, tokenAddress, netAmount);
            registry.recordTreasury(tokenAddress, feeAmount);
            
            // Fix: Track total deposits for solvency checks
            registry.recordDeposit(tokenAddress, amount);

            // Track mint
            uint256 tokenId = tokenModule.getTokenId(tokenAddress);
            if (tokenId > 0) {
                registry.recordMint(tokenId, netAmount);
            }
        }

        vm.prank(address(hook));
        storage_.clearTransientSwapContext(user);
    }

    // ===== DCA execution with output tracking =====

    function executeDca(uint256 userIndex, uint256 queueIndex) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0)) return;

        uint256 queueLength = storage_.getDcaQueueLength(user);
        if (queueLength == 0) return;

        uint256 idx = queueIndex % queueLength;

        (
            address fromToken,
            address toToken,
            uint256 amount,
            , , ,
        ) = storage_.getDcaQueueItem(user, idx);

        uint256 balanceBefore = storage_._savings(user, toToken);

        vm.startPrank(address(dca));
        try dca.executeDCA(user) returns (bool executed, uint256 totalAmount) {
            if (executed) {
                uint256 balanceAfter = storage_._savings(user, toToken);
                uint256 outputAmount = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
                registry.recordDcaExecution(user, idx, amount, outputAmount);
            }
        } catch {}
        vm.stopPrank();
    }

    // ===== Access control violation attempts =====

    function attemptUnauthorizedTreasuryChange(uint256 attackerIndex) external {
        uint256 userCount = registry.usersLength();
        if (userCount == 0) return;

        address attacker = registry.userAt(attackerIndex % userCount);
        if (attacker == storage_.owner()) return; // Skip owner

        address newTreasury = address(uint160(uint256(keccak256(abi.encodePacked(attacker, "treasury")))));

        vm.startPrank(attacker);
        try storage_.setTreasury(newTreasury) {
            registry.recordUnauthorizedAccess(attacker, "setTreasury");
        } catch {
            // Expected to fail
        }
        vm.stopPrank();
    }

    function attemptUnauthorizedFeeChange(uint256 attackerIndex, uint256 newFee) external {
        uint256 userCount = registry.usersLength();
        if (userCount == 0) return;

        address attacker = registry.userAt(attackerIndex % userCount);
        if (attacker == storage_.owner()) return; // Skip owner

        vm.startPrank(attacker);
        try storage_.setTreasuryFee(newFee) {
            registry.recordUnauthorizedAccess(attacker, "setTreasuryFee");
        } catch {
            // Expected to fail
        }
        vm.stopPrank();
    }

    function attemptUnauthorizedModuleRegistration(uint256 attackerIndex, bytes32 moduleId, address module) external {
        uint256 userCount = registry.usersLength();
        if (userCount == 0) return;

        address attacker = registry.userAt(attackerIndex % userCount);
        if (attacker == storage_.owner()) return; // Skip owner

        vm.startPrank(attacker);
        try storage_.registerModule(moduleId, module) {
            registry.recordUnauthorizedAccess(attacker, "registerModule");
        } catch {
            // Expected to fail
        }
        vm.stopPrank();
    }

    // ===== Strategy modification tracking =====

    function configureStrategyWithTracking(uint256 userIndex, uint256 percentage, uint256 maxPercentage, uint8 tokenTypeSeed)
        external
    {
        address user = _selectActiveUser(userIndex);
        if (user == address(0)) return;

        uint256 pct = bound(percentage, 0, 10000);
        uint256 maxPct = bound(maxPercentage, pct, 10000);

        SpendSaveStorage.SavingsTokenType tokenType = SpendSaveStorage.SavingsTokenType(bound(tokenTypeSeed, 0, 2));
        address specificToken = address(0);
        if (tokenType == SpendSaveStorage.SavingsTokenType.SPECIFIC && registry.tokensLength() > 0) {
            specificToken = registry.tokenAt(tokenTypeSeed % registry.tokensLength());
        }

        vm.startPrank(user);
        try savingStrategy.setSavingStrategy(user, pct, 0, maxPct, false, tokenType, specificToken) {
            registry.recordStrategySet(user, user);
        } catch {}
        vm.stopPrank();
    }

    // ===== Transient context tracking =====

    function setTransientContextWithTracking(uint256 userIndex, uint256 amount) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0)) return;

        vm.startPrank(address(hook));
        storage_.setTransientSwapContext(
            user, uint128(amount), uint128(1000), true, uint8(SpendSaveStorage.SavingsTokenType.INPUT), false, false
        );
        registry.recordTransientContextModification(address(hook));
        
        // Fix: Clear transient context after setting it (simulating swap completion)
        // Transient context should only exist during swap execution
        storage_.clearTransientSwapContext(user);
        vm.stopPrank();
    }

    // ===== Module tracking =====

    function trackModuleModification(address module) external {
        registry.addModule(module);
        registry.recordModuleModification(module);
    }

    // ===== Daily Savings Execution =====

    function executeDailySavingsForToken(uint256 userIndex, uint256 tokenIndex) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0) || registry.tokensLength() == 0) return;

        address token = registry.tokenAt(tokenIndex % registry.tokensLength());

        // Get configuration
        (
            bool enabled,
            uint256 lastExecution,
            uint256 startTime,
            uint256 goal,
            uint256 current,
            ,
            uint256 endTime
        ) = storage_.getDailySavingsConfig(user, token);

        if (!enabled) {
            registry.recordExecutionSkip(user, token, "Not enabled");
            return;
        }

        // Fix: Check startTime before execution
        if (block.timestamp < startTime) {
            registry.recordExecutionSkip(user, token, "Before start time");
            return;
        }

        // Check endTime if set
        if (endTime > 0 && block.timestamp > endTime) {
            registry.recordExecutionSkip(user, token, "After end time");
            return;
        }

        // Check time - use startTime if lastExecution is 0
        uint256 effectiveLastExecution = lastExecution > 0 ? lastExecution : startTime;
        uint256 daysPassed = (block.timestamp - effectiveLastExecution) / 1 days;
        if (daysPassed == 0) {
            registry.recordExecutionSkip(user, token, "Not enough time passed");
            return;
        }

        // Calculate amount
        uint256 dailyAmount = storage_.dailySavingsAmounts(user, token);
        uint256 amountToSave = dailyAmount * daysPassed;

        // Cap at goal
        if (goal > 0) {
            uint256 remaining = goal > current ? goal - current : 0;
            if (amountToSave > remaining) amountToSave = remaining;
        }

        if (amountToSave == 0) {
            registry.recordExecutionSkip(user, token, "Zero amount");
            return;
        }

        // Mint tokens to user (simulating they have funds)
        TestToken(token).mint(user, amountToSave);

        // Approve
        vm.startPrank(user);
        TestToken(token).approve(address(dailySavings), amountToSave);
        vm.stopPrank();

        // Track before state
        uint256 balanceBefore = TestToken(token).balanceOf(user);
        uint256 allowanceBefore = TestToken(token).allowance(user, address(dailySavings));
        uint256 currentBefore = current;

        // Execute
        vm.startPrank(user);
        try dailySavings.executeDailySavingsForToken(user, token) returns (uint256 saved) {
            // Track execution
            registry.recordDailyExecution(user, token, saved, daysPassed);
            registry.recordExecutionState(user, token, balanceBefore, allowanceBefore, currentBefore);
            registry.recordDailyDeposit(user, token, saved);

            // Update previous amount for accumulation testing
            registry.updatePreviousAmount(user, token, current);

            // Record amount at execution
            uint256 execCount = registry.executionCount(user, token);
            registry.recordAmountAtExecution(user, token, execCount - 1, current);

            // Record config at execution
            registry.recordConfigAtExecution(
                registry.totalDailyExecutions() - 1,
                goal,
                currentBefore,
                dailyAmount
            );

            // Check if goal reached
            (,, , uint256 newGoal, uint256 newCurrent,,) = storage_.getDailySavingsConfig(user, token);
            if (newGoal > 0 && newCurrent >= newGoal && !registry.wasGoalReached(user, token)) {
                registry.recordGoalReached(user, token);
                registry.recordGoalEvent(user, token);
            }

        } catch (bytes memory reason) {
            string memory reasonStr = string(reason);
            registry.recordExecutionSkip(user, token, reasonStr);
        }
        vm.stopPrank();
    }

    // ===== Daily Savings Withdrawal =====

    function withdrawDailySavings(
        uint256 userIndex,
        uint256 tokenIndex,
        uint256 amount
    ) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0) || registry.tokensLength() == 0) return;

        address token = registry.tokenAt(tokenIndex % registry.tokensLength());

        (bool enabled, , , uint256 goal, uint256 current, uint256 penaltyBps,) =
            storage_.getDailySavingsConfig(user, token);

        if (!enabled) return;

        // Bound amount to current balance
        uint256 withdrawAmount = bound(amount, 0, current);
        if (withdrawAmount == 0) return;

        // Calculate penalty
        bool goalReached = goal > 0 && current >= goal;
        uint256 penalty = goalReached ? 0 : (withdrawAmount * penaltyBps) / 10000;
        uint256 netAmount = withdrawAmount - penalty;

        // Track treasury before
        uint256 treasuryBefore = storage_._savings(storage_.treasury(), token);

        // Execute withdrawal
        vm.startPrank(user);
        try dailySavings.withdrawDailySavings(user, token, withdrawAmount) returns (uint256 actualNet) {
            // Verify treasury received penalty
            uint256 treasuryAfter = storage_._savings(storage_.treasury(), token);

            // Record withdrawal
            registry.recordDailyWithdrawal(
                user,
                token,
                withdrawAmount,
                penalty,
                actualNet,
                treasuryBefore,
                treasuryAfter
            );

            // Track total withdrawals (hadWithdrawal checks this)
            registry.recordDailyWithdrawalTotal(user, token, withdrawAmount);

        } catch (bytes memory) {
            // Withdrawal failed, no recording
        }
        vm.stopPrank();
    }

    // ===== Batch Daily Savings Execution =====

    function executeBatchDailySavings(uint256 userIndex) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0)) return;

        address[] memory tokens = storage_.getUserSavingsTokens(user);
        if (tokens.length == 0) return;

        uint256 gasStart = gasleft();
        uint256 processed = 0;

        for (uint256 i = 0; i < tokens.length && i < 5; i++) {
            address token = tokens[i];

            (bool enabled, uint256 lastExecution,,,,,) =
                storage_.getDailySavingsConfig(user, token);

            if (!enabled) continue;

            uint256 daysPassed = (block.timestamp - lastExecution) / 1 days;
            if (daysPassed == 0) continue;

            // Attempt execution
            vm.startPrank(user);
            try dailySavings.executeDailySavingsForToken(user, token) returns (uint256 saved) {
                if (saved > 0) {
                    processed++;
                }
            } catch {}
            vm.stopPrank();
        }

        uint256 gasUsed = gasStart - gasleft();

        // Record batch execution
        registry.recordBatchExecution(user, processed, tokens.length, gasUsed);
    }

    // ===== Disable Daily Savings =====

    function disableDailySavings(uint256 userIndex, uint256 tokenIndex) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0) || registry.tokensLength() == 0) return;

        address token = registry.tokenAt(tokenIndex % registry.tokensLength());

        vm.startPrank(user);
        try dailySavings.disableDailySavings(user, token) {
            // Successfully disabled
        } catch {}
        vm.stopPrank();
    }
}

/**
 * @title BaseInvariantTest
 * @notice Base contract for all invariant tests with shared setup
 */
contract BaseInvariantTest is StdInvariant, Test {
    MockPoolManager internal poolManager;
    SpendSaveStorage internal storage_;
    SpendSaveHook internal hook;
    Savings internal savings;
    SavingStrategy internal savingStrategy;
    DCA internal dca;
    DailySavings internal dailySavings;
    SlippageControl internal slippage;
    Token internal tokenModule;

    InvariantStateRegistry internal registry;
    SpendSaveHandler internal handler;

    function setUp() public virtual {
        poolManager = new MockPoolManager();
        storage_ = new SpendSaveStorage(address(poolManager));
        hook = new SpendSaveHook(IPoolManager(address(poolManager)), storage_);
        savings = new Savings();
        savingStrategy = new SavingStrategy();
        dca = new DCA();
        dailySavings = new DailySavings();
        slippage = new SlippageControl();
        tokenModule = new Token();

        // Deploy tokens
        TestToken[] memory fuzzTokens = new TestToken[](3);
        fuzzTokens[0] = new TestToken("TokenA", "TOKA", type(uint96).max);
        fuzzTokens[1] = new TestToken("TokenB", "TOKB", type(uint96).max);
        fuzzTokens[2] = new TestToken("TokenC", "TOKC", type(uint96).max);

        // Initialize modules
        savingStrategy.initialize(storage_);
        savings.initialize(storage_);
        dca.initialize(storage_);
        dailySavings.initialize(storage_);
        slippage.initialize(storage_);
        tokenModule.initialize(storage_);

        // Register modules
        bytes32 STRATEGY_ID = keccak256("STRATEGY");
        bytes32 SAVINGS_ID = keccak256("SAVINGS");
        bytes32 DCA_ID = keccak256("DCA");
        bytes32 SLIPPAGE_ID = keccak256("SLIPPAGE");
        bytes32 TOKEN_ID = keccak256("TOKEN");
        bytes32 DAILY_ID = keccak256("DAILY");

        storage_.registerModule(STRATEGY_ID, address(savingStrategy));
        storage_.registerModule(SAVINGS_ID, address(savings));
        storage_.registerModule(DCA_ID, address(dca));
        storage_.registerModule(SLIPPAGE_ID, address(slippage));
        storage_.registerModule(TOKEN_ID, address(tokenModule));
        storage_.registerModule(DAILY_ID, address(dailySavings));

        storage_.initialize(address(hook));

        // Set module references
        savingStrategy.setModuleReferences(
            address(savingStrategy), address(savings), address(dca),
            address(slippage), address(tokenModule), address(dailySavings)
        );
        savings.setModuleReferences(
            address(savingStrategy), address(savings), address(dca),
            address(slippage), address(tokenModule), address(dailySavings)
        );
        dca.setModuleReferences(
            address(savingStrategy), address(savings), address(dca),
            address(slippage), address(tokenModule), address(dailySavings)
        );
        dailySavings.setModuleReferences(
            address(savingStrategy), address(savings), address(dca),
            address(slippage), address(tokenModule), address(dailySavings)
        );
        slippage.setModuleReferences(
            address(savingStrategy), address(savings), address(dca),
            address(slippage), address(tokenModule), address(dailySavings)
        );
        tokenModule.setModuleReferences(
            address(savingStrategy), address(savings), address(dca),
            address(slippage), address(tokenModule), address(dailySavings)
        );

        registry = new InvariantStateRegistry();
        handler = new SpendSaveHandler(
            storage_, hook, savings, savingStrategy, dca, dailySavings, slippage, tokenModule, registry, fuzzTokens
        );

        targetContract(address(handler));
    }
}

