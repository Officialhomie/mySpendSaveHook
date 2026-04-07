// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {SpendSaveHook} from "../../src/SpendSaveHook.sol";
import {SpendSaveStorage} from "../../src/SpendSaveStorage.sol";
import {Savings} from "../../src/Savings.sol";
import {SavingStrategy} from "../../src/SavingStrategy.sol";
import {DCA} from "../../src/DCA.sol";
import {DailySavings} from "../../src/DailySavings.sol";
import {SlippageControl} from "../../src/SlippageControl.sol";
import {Token} from "../../src/Token.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Minimal ERC20 used for invariant fuzzing tokens.
contract TestToken is ERC20 {
    constructor(string memory name, string memory symbol, uint256 initialSupply) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }
}

/// @notice Stub PoolManager that exposes the minimal surface needed for tests.
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

    // NEW: Withdrawal tracking
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

    // NEW: Transfer tracking
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

    // NEW: Mint/Burn tracking
    function recordMint(uint256 tokenId, uint256 amount) external {
        totalMinted[tokenId] += amount;
    }

    function recordBurn(uint256 tokenId, uint256 amount) external {
        totalBurned[tokenId] += amount;
    }

    // NEW: DCA execution tracking
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

    // NEW: Access control violation tracking
    function recordUnauthorizedAccess(address attacker, string memory function_) external {
        unauthorizedAccessAttempts[attacker][function_]++;
    }

    // NEW: Module modification tracking
    function recordModuleModification(address module) external {
        moduleModificationCount[module]++;
    }

    function recordRegistryChange(bytes32 moduleId) external {
        moduleRegistryChanges[moduleId]++;
    }

    // NEW: Strategy setter tracking
    function recordStrategySet(address user, address setter) external {
        strategySetter[user] = setter;
    }

    // NEW: Transient context tracking
    function recordTransientContextModification(address modifier_) external {
        transientContextModifiers.push(modifier_);
    }

    function transientContextModifications() external view returns (uint256) {
        return transientContextModifiers.length;
    }

    function transientContextModifier(uint256 index) external view returns (address) {
        return transientContextModifiers[index];
    }

    // NEW: Expected total tracking
    function recordDeposit(address token, uint256 amount) external {
        expectedTotalDeposits[token] += amount;
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

        SpendSaveStorage.DailySavingsConfigParams memory params = SpendSaveStorage.DailySavingsConfigParams({
            enabled: true,
            lastExecutionTime: registry.lastDailyExecution(user, tokenAddress),
            startTime: block.timestamp,
            goalAmount: amount * 10,
            currentAmount: amount,
            penaltyBps: 100,
            endTime: block.timestamp + 365 days
        });

        vm.startPrank(address(dailySavings));
        storage_.setDailySavingsAmount(user, tokenAddress, amount);
        storage_.setDailySavingsConfig(user, tokenAddress, params);
        vm.stopPrank();
    }

    function updateDailyExecution(uint256 userIndex, uint256 tokenIndex, uint256 advanceSeconds) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0) || registry.tokensLength() == 0) return;
        address tokenAddress = registry.tokenAt(tokenIndex % registry.tokensLength());

        uint256 warpDelta = bound(advanceSeconds, 1, 1 days);
        vm.warp(block.timestamp + warpDelta);

        vm.startPrank(address(dailySavings));
        storage_.updateDailySavingsExecution(user, tokenAddress, 1 ether);
        vm.stopPrank();

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

    // =====  ERC6909 Transfer operations =====

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

            // Track mint and verify ERC6909 tokens were actually minted
            uint256 tokenId = tokenModule.getTokenId(tokenAddress);
            if (tokenId > 0) {
                registry.recordMint(tokenId, netAmount);

                // CRITICAL VERIFICATION: Ensure ERC6909 tokens were minted
                uint256 erc6909Balance = tokenModule.balanceOf(user, tokenId);
                require(erc6909Balance >= netAmount, "ERC6909 tokens not minted correctly");
            }
        }

        vm.prank(address(hook));
        storage_.clearTransientSwapContext(user);
    }

    // Handler for OUTPUT token savings
    function processSavingsFromOutput(uint256 userIndex, uint256 tokenIndex, uint256 rawAmount) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0) || registry.tokensLength() == 0) return;

        address tokenAddress = registry.tokenAt(tokenIndex % registry.tokensLength());
        uint256 outputAmount = bound(rawAmount, 1e6, 1e18);
        uint256 percentage = 1000; // 10%

        SpendSaveStorage.SwapContext memory ctx = SpendSaveStorage.SwapContext({
            hasStrategy: true,
            currentPercentage: uint128(percentage),
            inputAmount: 0,
            inputToken: tokenAddress,
            roundUpSavings: false,
            enableDCA: false,
            dcaTargetToken: address(0),
            currentTick: 0,
            savingsTokenType: SpendSaveStorage.SavingsTokenType.OUTPUT,
            specificSavingsToken: address(0),
            pendingSaveAmount: 0
        });

        bool processed;
        uint256 savedAmount;

        vm.startPrank(address(hook));
        try savings.processSavingsFromOutput(user, tokenAddress, outputAmount, ctx) returns (uint256 saved) {
            processed = true;
            savedAmount = saved;
        } catch {
            processed = false;
        }
        vm.stopPrank();

        if (processed && savedAmount > 0) {
            uint256 treasuryFee = storage_.treasuryFee();
            uint256 feeAmount = (savedAmount * treasuryFee) / 10000;
            uint256 netAmount = savedAmount - feeAmount;

            registry.recordGross(user, tokenAddress, savedAmount);
            registry.recordNet(user, tokenAddress, netAmount);
            registry.recordTreasury(tokenAddress, feeAmount);

            // Track mint and verify ERC6909 tokens were minted
            uint256 tokenId = tokenModule.getTokenId(tokenAddress);
            if (tokenId > 0) {
                registry.recordMint(tokenId, netAmount);

                // CRITICAL VERIFICATION: Ensure ERC6909 tokens were minted for OUTPUT savings
                uint256 erc6909Balance = tokenModule.balanceOf(user, tokenId);
                require(erc6909Balance >= netAmount, "OUTPUT: ERC6909 tokens not minted correctly");
            }
        }
    }

    // Handler for SPECIFIC token savings
    function processSavingsToSpecificToken(uint256 userIndex, uint256 tokenIndex, uint256 targetTokenIndex, uint256 rawAmount) external {
        address user = _selectActiveUser(userIndex);
        if (user == address(0) || registry.tokensLength() < 2) return;

        address outputToken = registry.tokenAt(tokenIndex % registry.tokensLength());
        address specificToken = registry.tokenAt(targetTokenIndex % registry.tokensLength());
        if (outputToken == specificToken) return; // Must be different tokens

        uint256 outputAmount = bound(rawAmount, 1e6, 1e18);
        uint256 percentage = 1000; // 10%

        SpendSaveStorage.SwapContext memory ctx = SpendSaveStorage.SwapContext({
            hasStrategy: true,
            currentPercentage: uint128(percentage),
            inputAmount: 0,
            inputToken: outputToken,
            roundUpSavings: false,
            enableDCA: true,
            dcaTargetToken: specificToken,
            currentTick: 0,
            savingsTokenType: SpendSaveStorage.SavingsTokenType.SPECIFIC,
            specificSavingsToken: specificToken,
            pendingSaveAmount: 0
        });

        bool processed;
        uint256 savedAmount;

        vm.startPrank(address(hook));
        try savings.processSavingsToSpecificToken(user, outputToken, outputAmount, ctx) returns (uint256 saved) {
            processed = true;
            savedAmount = saved;
        } catch {
            processed = false;
        }
        vm.stopPrank();

        if (processed && savedAmount > 0) {
            uint256 treasuryFee = storage_.treasuryFee();
            uint256 feeAmount = (savedAmount * treasuryFee) / 10000;
            uint256 netAmount = savedAmount - feeAmount;

            registry.recordGross(user, outputToken, savedAmount);
            registry.recordNet(user, outputToken, netAmount);
            registry.recordTreasury(outputToken, feeAmount);

            // Track mint and verify ERC6909 tokens were minted
            uint256 tokenId = tokenModule.getTokenId(outputToken);
            if (tokenId > 0) {
                registry.recordMint(tokenId, netAmount);

                // CRITICAL VERIFICATION: Ensure ERC6909 tokens were minted for SPECIFIC savings
                uint256 erc6909Balance = tokenModule.balanceOf(user, tokenId);
                require(erc6909Balance >= netAmount, "SPECIFIC: ERC6909 tokens not minted correctly");
            }
        }
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

    // ===== NEW: Access control violation attempts =====

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
}

/// @notice Main invariant test suite.
contract SpendSaveInvariantTest is StdInvariant, Test {
    uint256 private constant TREASURY_FEE_DENOMINATOR = 10000;
    bytes32 private constant STRATEGY_ID = keccak256("STRATEGY");
    bytes32 private constant SAVINGS_ID = keccak256("SAVINGS");
    bytes32 private constant DCA_ID = keccak256("DCA");
    bytes32 private constant SLIPPAGE_ID = keccak256("SLIPPAGE");
    bytes32 private constant TOKEN_ID = keccak256("TOKEN");
    bytes32 private constant DAILY_ID = keccak256("DAILY");

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

    function setUp() public {
        poolManager = new MockPoolManager();
        storage_ = new SpendSaveStorage(address(poolManager));

        hook = new SpendSaveHook(IPoolManager(address(poolManager)), storage_);
        savings = new Savings();
        savingStrategy = new SavingStrategy();
        dca = new DCA();
        dailySavings = new DailySavings();
        slippage = new SlippageControl();
        tokenModule = new Token();

        // Deploy sample tokens
        TestToken[] memory fuzzTokens = new TestToken[](3);
        fuzzTokens[0] = new TestToken("TokenA", "TOKA", type(uint96).max);
        fuzzTokens[1] = new TestToken("TokenB", "TOKB", type(uint96).max);
        fuzzTokens[2] = new TestToken("TokenC", "TOKC", type(uint96).max);

        // Initialize modules with storage reference
        savingStrategy.initialize(storage_);
        savings.initialize(storage_);
        dca.initialize(storage_);
        dailySavings.initialize(storage_);
        slippage.initialize(storage_);
        tokenModule.initialize(storage_);

        // Register modules in storage
        storage_.registerModule(STRATEGY_ID, address(savingStrategy));
        storage_.registerModule(SAVINGS_ID, address(savings));
        storage_.registerModule(DCA_ID, address(dca));
        storage_.registerModule(SLIPPAGE_ID, address(slippage));
        storage_.registerModule(TOKEN_ID, address(tokenModule));
        storage_.registerModule(DAILY_ID, address(dailySavings));

        storage_.initialize(address(hook));

        // Wire module references (owner-only calls)
        savingStrategy.setModuleReferences(
            address(savingStrategy),
            address(savings),
            address(dca),
            address(slippage),
            address(tokenModule),
            address(dailySavings)
        );
        savings.setModuleReferences(
            address(savingStrategy),
            address(savings),
            address(dca),
            address(slippage),
            address(tokenModule),
            address(dailySavings)
        );
        dca.setModuleReferences(
            address(savingStrategy),
            address(savings),
            address(dca),
            address(slippage),
            address(tokenModule),
            address(dailySavings)
        );
        dailySavings.setModuleReferences(
            address(savingStrategy),
            address(savings),
            address(dca),
            address(slippage),
            address(tokenModule),
            address(dailySavings)
        );
        slippage.setModuleReferences(
            address(savingStrategy),
            address(savings),
            address(dca),
            address(slippage),
            address(tokenModule),
            address(dailySavings)
        );
        tokenModule.setModuleReferences(
            address(savingStrategy),
            address(savings),
            address(dca),
            address(slippage),
            address(tokenModule),
            address(dailySavings)
        );

        registry = new InvariantStateRegistry();

        handler = new SpendSaveHandler(
            storage_, hook, savings, savingStrategy, dca, dailySavings, slippage, tokenModule, registry, fuzzTokens
        );

        targetContract(address(handler));
    }

    // ===== Invariants =====

    function invariant_owner_and_treasury_non_zero() external {
        assertTrue(storage_.owner() != address(0), "owner zero");
        assertTrue(storage_.treasury() != address(0), "treasury zero");
    }

    function invariant_module_registry_consistency() external {
        assertEq(storage_.moduleRegistry(STRATEGY_ID), address(savingStrategy), "strategy registry mismatch");
        assertEq(storage_.moduleRegistry(SAVINGS_ID), address(savings), "savings registry mismatch");
        assertEq(storage_.moduleRegistry(DCA_ID), address(dca), "dca registry mismatch");
        assertEq(storage_.moduleRegistry(SLIPPAGE_ID), address(slippage), "slippage registry mismatch");
        assertEq(storage_.moduleRegistry(TOKEN_ID), address(tokenModule), "token registry mismatch");
        assertEq(storage_.moduleRegistry(DAILY_ID), address(dailySavings), "daily registry mismatch");

        assertTrue(storage_.authorizedModules(address(savingStrategy)), "strategy not authorized");
        assertTrue(storage_.authorizedModules(address(savings)), "savings not authorized");
        assertTrue(storage_.authorizedModules(address(dca)), "dca not authorized");
        assertTrue(storage_.authorizedModules(address(slippage)), "slippage not authorized");
        assertTrue(storage_.authorizedModules(address(tokenModule)), "token not authorized");
        assertTrue(storage_.authorizedModules(address(dailySavings)), "daily not authorized");
    }

    function invariant_transient_context_cleared() external {
        uint256 len = registry.usersLength();
        for (uint256 i = 0; i < len; i++) {
            address user = registry.userAt(i);
            (
                uint128 pendingSaveAmount,
                uint128 currentPercentage,
                uint8 savingsTokenType,
                bool roundUpSavings,
                bool enableDCA
            ) = storage_.getTransientSwapContext(user);

            assertEq(pendingSaveAmount, 0, "pending save");
            assertEq(currentPercentage, 0, "percentage");
            assertEq(savingsTokenType, 0, "token type");
            assertFalse(roundUpSavings, "round up");
            assertFalse(enableDCA, "enable DCA");
        }
    }

    function invariant_erc6909_supply_matches_savings() external {
        uint256 tokenCount = registry.tokensLength();
        uint256 userCount = registry.usersLength();

        for (uint256 t = 0; t < tokenCount; t++) {
            address tokenAddr = registry.tokenAt(t);
            uint256 tokenId = tokenModule.getTokenId(tokenAddr);
            if (tokenId == 0) {
                // no registrations yet, ensure no balances
                for (uint256 u = 0; u < userCount; u++) {
                    address user = registry.userAt(u);
                    assertEq(storage_._savings(user, tokenAddr), 0, "unexpected savings");
                }
                continue;
            }

            uint256 computedTotal = 0;
            for (uint256 u = 0; u < userCount; u++) {
                address user = registry.userAt(u);
                if (user == storage_.treasury()) continue;
                computedTotal += storage_._savings(user, tokenAddr);
            }

            uint256 recordedSupply = storage_.getTotalSupply(tokenId);
            assertEq(computedTotal, recordedSupply, "ERC6909 mismatch");
        }
    }

    function invariant_savings_accounting_matches_expectations() external {
        uint256 tokenCount = registry.tokensLength();
        uint256 userCount = registry.usersLength();

        for (uint256 t = 0; t < tokenCount; t++) {
            address tokenAddr = registry.tokenAt(t);

            uint256 expectedTreasury = registry.expectedTreasuryFees(tokenAddr);
            uint256 actualTreasury = storage_._savings(storage_.treasury(), tokenAddr);
            assertEq(actualTreasury, expectedTreasury, "treasury mismatch");

            for (uint256 u = 0; u < userCount; u++) {
                address user = registry.userAt(u);
                uint256 expectedNet = registry.expectedNetSavings(user, tokenAddr);
                uint256 actualNet = storage_._savings(user, tokenAddr);
                if (user == storage_.treasury()) continue; // handled above
                assertEq(actualNet, expectedNet, "user net mismatch");
            }
        }
    }

    function invariant_treasury_fee_bounds() external {
        uint256 fee = storage_.treasuryFee();
        assertTrue(fee <= TREASURY_FEE_DENOMINATOR, "fee out of bounds");
    }

    function invariant_withdrawal_timelock_bounds() external {
        uint256 userCount = registry.usersLength();
        for (uint256 i = 0; i < userCount; i++) {
            address user = registry.userAt(i);
            uint256 timelock = storage_.userWithdrawalTimelocks(user);
            if (timelock == 0) continue;
            assertTrue(timelock <= block.timestamp + 30 days, "withdrawal timelock exceeds max window");
        }
    }

    function invariant_dca_queue_consistency() external {
        uint256 userCount = registry.usersLength();
        for (uint256 i = 0; i < userCount; i++) {
            address user = registry.userAt(i);

            SpendSaveStorage.DCAQueue memory simpleQueue = _getSimpleDcaQueue(user);
            uint256 lengthSimple = simpleQueue.amounts.length;

            (uint256 enhancedLength,) = _enhancedQueueStats(user);
            assertEq(lengthSimple, simpleQueue.tokens.length, "tokens length mismatch");
            assertEq(lengthSimple, simpleQueue.executionTimes.length, "execution length mismatch");
            if (lengthSimple == 0) {
                assertFalse(simpleQueue.isActive, "simple queue active with zero length");
            } else {
                assertTrue(simpleQueue.isActive, "simple queue inactive with items");
            }
            assertEq(lengthSimple, enhancedLength, "enhanced length mismatch");
        }
    }

    function invariant_slippage_bounds() external {
        uint256 userCount = registry.usersLength();
        for (uint256 i = 0; i < userCount; i++) {
            address user = registry.userAt(i);
            uint256 tolerance = storage_.userSlippageTolerance(user);
            assertTrue(tolerance <= 1000, "user tolerance gt 10%");

            uint256 tokenCount = registry.tokensLength();
            for (uint256 t = 0; t < tokenCount; t++) {
                address tokenAddr = registry.tokenAt(t);
                uint256 tokenTol = storage_.tokenSlippageTolerance(user, tokenAddr);
                assertTrue(tokenTol <= 1000, "token tolerance gt 10%");
            }
        }

        uint256 defaultTolerance = storage_.defaultSlippageTolerance();
        assertTrue(defaultTolerance <= 500, "default tolerance gt 5%");
    }

    function invariant_daily_execution_monotonic() external {
        uint256 userCount = registry.usersLength();
        for (uint256 i = 0; i < userCount; i++) {
            address user = registry.userAt(i);
            uint256 tokenCount = registry.tokensLength();
            for (uint256 t = 0; t < tokenCount; t++) {
                address tokenAddr = registry.tokenAt(t);
                (
                    , // enabled
                    uint256 lastExecutionTime,
                    , , , ,
                ) = storage_.getDailySavingsConfig(user, tokenAddr);
                uint256 recorded = registry.lastDailyExecution(user, tokenAddr);
                assertTrue(lastExecutionTime >= recorded, "daily execution regressed");
            }
        }
    }

    // ===== Helper =====

    function _enhancedQueueStats(address user) internal view returns (uint256 length, bool isActive) {
        uint256 l = storage_.getDcaQueueLength(user);
        bool active;
        if (l == 0) {
            active = false;
        } else {
            try storage_.getDcaQueueItem(user, 0) returns (address, address, uint256, int24, uint256, bool, uint256) {
                active = true;
            } catch {
                active = false;
            }
        }
        return (l, active);
    }

    function _getSimpleDcaQueue(address user) internal view returns (SpendSaveStorage.DCAQueue memory queue) {
        try storage_.getDcaQueue(user) returns (SpendSaveStorage.DCAQueue memory q) {
            return q;
        } catch {
            SpendSaveStorage.DCAQueue memory empty;
            return empty;
        }
    }
}

