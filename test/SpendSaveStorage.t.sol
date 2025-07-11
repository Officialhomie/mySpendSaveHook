// SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.20;

// // Foundry libraries
// import {Test} from "forge-std/Test.sol";
// import {console} from "forge-std/console.sol";

// import {PoolManager} from "v4-core/PoolManager.sol";
// import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
// import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
// import {PoolId} from "lib/v4-periphery/lib/v4-core/src/types/PoolId.sol";


// import {SpendSaveStorage} from "../src/SpendSaveStorage.sol";

// contract SpendSaveStorageTest is Test, Deployers {
//     SpendSaveStorage public storage_;
//     PoolManager public poolManager;

//     address public owner;
//     address public pendingOwner;
//     address public treasury;
//     address public user1;
//     address public user2;
//     address public mockModule;
//     address public mockToken1;
//     address public mockToken2;

//     uint256 private snapshotId; // Stores the snapshot state ID

//     function setUp() public {
//         owner = makeAddr("owner");
//         pendingOwner = makeAddr("pendingOwner");
//         treasury = makeAddr("treasury");
//         user1 = makeAddr("user1");
//         user2 = makeAddr("user2");
//         mockModule = makeAddr("mockModule");
//         mockToken1 = makeAddr("mockToken1");
//         mockToken2 = makeAddr("mockToken2");

//         deployFreshManager();
//         poolManager = PoolManager(address(manager));

//         vm.prank(owner);
//         storage_ = new SpendSaveStorage(owner, treasury, poolManager);

//         console.log("SpendSaveStorage deployed to:", address(storage_));

//         vm.startPrank(owner);
//         storage_.setSavingStrategyModule(mockModule);
//         storage_.setSavingsModule(mockModule);
//         storage_.setDCAModule(mockModule);
//         storage_.setSlippageControlModule(mockModule);
//         storage_.setTokenModule(mockModule);
//         storage_.setDailySavingsModule(mockModule);
//         storage_.setSpendSaveHook(mockModule);
//         vm.stopPrank();

//         console.log("Registered mockModule for all module slots");

//         // Capture snapshot after setup
//         snapshotId = vm.snapshotState();
//     }

//     function beforeEach() internal {
//         vm.revertToState(snapshotId); // Reset to initial state before each test
//     }

//     function testInitialization() public {
//         beforeEach();
//         console.log("Testing initialization parameters...");
//         assertEq(storage_.owner(), owner, "Owner should match");
//         assertEq(storage_.treasury(), treasury, "Treasury should match");
//         assertEq(address(storage_.poolManager()), address(poolManager), "PoolManager should match");
//     }

//     function testOnlyOwnerCanRegisterModules() public {
//         beforeEach();
//         address newModule = makeAddr("newModule");

//         vm.prank(owner);
//         storage_.setSavingStrategyModule(newModule);
//         assertEq(storage_.savingStrategyModule(), newModule, "Owner should be able to set module");

//         vm.prank(user1);
//         vm.expectRevert(abi.encodeWithSignature("NotOwner()"));
//         storage_.setSavingStrategyModule(address(0));
//     }

//     function testOnlyModulesCanCallRestrictedFunctions() public {
//         beforeEach();
//         vm.prank(mockModule);
//         storage_.increaseSavings(user1, mockToken1, 100);

//         vm.prank(user1);
//         vm.expectRevert(abi.encodeWithSignature("NotAuthorizedModule()"));
//         storage_.increaseSavings(user1, mockToken1, 100);
//     }

//     function testOwnershipTransfer() public {
//         beforeEach();
//         console.log("Testing ownership transfer...");

//         vm.prank(owner);
//         storage_.transferOwnership(pendingOwner);
//         assertEq(storage_.pendingOwner(), pendingOwner, "Pending owner should be set");

//         vm.prank(user1);
//         vm.expectRevert(abi.encodeWithSignature("NotPendingOwner()"));
//         storage_.acceptOwnership();

//         vm.prank(pendingOwner);
//         storage_.acceptOwnership();

//         assertEq(storage_.owner(), pendingOwner, "Owner should be updated");
//         assertEq(storage_.pendingOwner(), address(0), "Pending owner should be cleared");
//     }

//     function testTreasuryFeeManagement() public {
//         beforeEach();
        
//         vm.prank(owner);
//         storage_.setTreasuryFee(500); // Use 500 (5%), not 5000 (500%)
//         assertEq(storage_.treasuryFee(), 500, "Treasury fee should be updated");

//         vm.prank(owner);
//         vm.expectRevert(abi.encodeWithSignature("FeeTooHigh()"));
//         storage_.setTreasuryFee(501); // This should revert as it exceeds the max limit
//     }


//     function testSavingsOperations() public {
//         beforeEach();
//         uint256 initialAmount = 1000;
//         uint256 increaseAmount = 500;
//         uint256 decreaseAmount = 300;

//         vm.prank(mockModule);
//         storage_.setSavings(user1, mockToken1, initialAmount);
//         assertEq(storage_.savings(user1, mockToken1), initialAmount, "Initial savings not set correctly");

//         vm.prank(mockModule);
//         storage_.increaseSavings(user1, mockToken1, increaseAmount);
//         assertEq(storage_.savings(user1, mockToken1), initialAmount + increaseAmount, "Savings not increased correctly");

//         vm.prank(mockModule);
//         storage_.decreaseSavings(user1, mockToken1, decreaseAmount);
//         assertEq(storage_.savings(user1, mockToken1), initialAmount + increaseAmount - decreaseAmount, "Savings not decreased correctly");
//     }

//     function testDailySavingsConfig() public {
//         beforeEach();
//         SpendSaveStorage.DailySavingsConfigParams memory params = SpendSaveStorage.DailySavingsConfigParams({
//             enabled: true,
//             goalAmount: 1000 ether,
//             currentAmount: 100 ether,
//             penaltyBps: 500,
//             endTime: block.timestamp + 30 days
//         });

//         vm.prank(mockModule);
//         storage_.setDailySavingsConfig(user1, mockToken1, params);

//         (bool enabled, uint256 lastExecTime, uint256 startTime, uint256 goalAmount, uint256 currentAmount, uint256 penaltyBps, uint256 endTime) = storage_.getDailySavingsConfig(user1, mockToken1);
        
//         assertEq(enabled, true, "Enabled flag not set correctly");
//         assertEq(startTime, block.timestamp, "Start time not set correctly");
//         assertEq(goalAmount, params.goalAmount, "Goal amount not set correctly");
//         assertEq(currentAmount, params.currentAmount, "Current amount not set correctly");
//         assertEq(penaltyBps, params.penaltyBps, "Penalty basis points not set correctly");
//         assertEq(endTime, params.endTime, "End time not set correctly");
//     }

//        // Test setting and getting user saving strategy
//     function testUserSavingStrategy() public {
//         beforeEach();
        
//         uint256 percentage = 1000; // 10%
//         uint256 autoIncrement = 100; // 1%
//         uint256 maxPercentage = 3000; // 30%
//         uint256 goalAmount = 1000 ether; 
//         bool roundUpSavings = true;
//         bool enableDCA = true;
//         SpendSaveStorage.SavingsTokenType savingsTokenType = SpendSaveStorage.SavingsTokenType.OUTPUT;
//         address specificSavingsToken = address(0);
        
//         vm.prank(mockModule);
//         storage_.setUserSavingStrategy(
//             user1,
//             percentage,
//             autoIncrement,
//             maxPercentage,
//             goalAmount,
//             roundUpSavings,
//             enableDCA,
//             savingsTokenType,
//             specificSavingsToken
//         );
        
//         (
//             uint256 storedPercentage,
//             uint256 storedAutoIncrement,
//             uint256 storedMaxPercentage,
//             uint256 storedGoalAmount,
//             bool storedRoundUpSavings,
//             bool storedEnableDCA,
//             SpendSaveStorage.SavingsTokenType storedSavingsTokenType,
//             address storedSpecificSavingsToken
//         ) = storage_.getUserSavingStrategy(user1);
        
//         assertEq(storedPercentage, percentage, "Percentage not stored correctly");
//         assertEq(storedAutoIncrement, autoIncrement, "AutoIncrement not stored correctly");
//         assertEq(storedMaxPercentage, maxPercentage, "MaxPercentage not stored correctly");
//         assertEq(storedGoalAmount, goalAmount, "GoalAmount not stored correctly");
//         assertEq(storedRoundUpSavings, roundUpSavings, "RoundUpSavings not stored correctly");
//         assertEq(storedEnableDCA, enableDCA, "EnableDCA not stored correctly");
//         assertEq(uint(storedSavingsTokenType), uint(savingsTokenType), "SavingsTokenType not stored correctly");
//         assertEq(storedSpecificSavingsToken, specificSavingsToken, "SpecificSavingsToken not stored correctly");
//     }

//     // Test setting and getting savings data
//     function testSavingsData() public {
//         beforeEach();
        
//         uint256 totalSaved = 5000 ether;
//         uint256 lastSaveTime = block.timestamp;
//         uint256 swapCount = 10;
//         uint256 targetSellPrice = 1500 ether;
        
//         vm.prank(mockModule);
//         storage_.setSavingsData(
//             user1,
//             mockToken1,
//             totalSaved,
//             lastSaveTime,
//             swapCount,
//             targetSellPrice
//         );
        
//         (
//             uint256 storedTotalSaved,
//             uint256 storedLastSaveTime,
//             uint256 storedSwapCount,
//             uint256 storedTargetSellPrice
//         ) = storage_.getSavingsData(user1, mockToken1);
        
//         assertEq(storedTotalSaved, totalSaved, "TotalSaved not stored correctly");
//         assertEq(storedLastSaveTime, lastSaveTime, "LastSaveTime not stored correctly");
//         assertEq(storedSwapCount, swapCount, "SwapCount not stored correctly");
//         assertEq(storedTargetSellPrice, targetSellPrice, "TargetSellPrice not stored correctly");
//     }

//     // Test updating savings data
//     function testUpdateSavingsData() public {
//         beforeEach();
        
//         // Set a specific timestamp to start with
//         uint256 startTime = 1000000; // A safe non-zero starting timestamp
//         vm.warp(startTime);
        
//         uint256 initialTotalSaved = 5000 ether;
//         uint256 initialLastSaveTime = startTime - 1 days; // Now safe from underflow
//         uint256 initialSwapCount = 10;
//         uint256 targetSellPrice = 1500 ether;
        
//         vm.prank(mockModule);
//         storage_.setSavingsData(
//             user1,
//             mockToken1,
//             initialTotalSaved,
//             initialLastSaveTime,
//             initialSwapCount,
//             targetSellPrice
//         );
        
//         uint256 additionalSaved = 500 ether;
        
//         // Use a specific timestamp for the warp
//         uint256 newTimestamp = startTime + 2 days;
//         vm.warp(newTimestamp);
        
//         vm.prank(mockModule);
//         storage_.updateSavingsData(user1, mockToken1, additionalSaved);
        
//         (
//             uint256 storedTotalSaved,
//             uint256 storedLastSaveTime,
//             uint256 storedSwapCount,
//             uint256 storedTargetSellPrice
//         ) = storage_.getSavingsData(user1, mockToken1);
        
//         assertEq(storedTotalSaved, initialTotalSaved + additionalSaved, "TotalSaved not updated correctly");
//         // Compare with the exact timestamp we set
//         assertEq(storedLastSaveTime, newTimestamp, "LastSaveTime not updated correctly");
//         assertEq(storedSwapCount, initialSwapCount + 1, "SwapCount not updated correctly");
//         assertEq(storedTargetSellPrice, targetSellPrice, "TargetSellPrice should remain unchanged");
//     }


//     // Test treasury fee calculation
//     function testCalculateAndTransferFee() public {
//         beforeEach();
        
//         // Set treasury fee to 2% (200 basis points)
//         vm.prank(owner);
//         storage_.setTreasuryFee(200);
        
//         uint256 amount = 10000 ether;
//         uint256 expectedFee = 200 ether; // 2% of 10000
//         uint256 expectedNetAmount = 9800 ether; // 10000 - 200
        
//         vm.prank(mockModule);
//         uint256 actualNetAmount = storage_.calculateAndTransferFee(user1, mockToken1, amount);
        
//         assertEq(actualNetAmount, expectedNetAmount, "Net amount after fee not calculated correctly");
//         assertEq(storage_.savings(treasury, mockToken1), expectedFee, "Fee not transferred to treasury correctly");
//     }

//     // Test withdrawal timelock
//     function testWithdrawalTimelock() public {
//         beforeEach();
        
//         uint256 timelock = 7 days;
        
//         vm.prank(mockModule);
//         storage_.setWithdrawalTimelock(user1, timelock);
        
//         assertEq(storage_.withdrawalTimelock(user1), timelock, "Withdrawal timelock not set correctly");
//     }

//     // Test DCA target token
//     function testDcaTargetToken() public {
//         beforeEach();
        
//         vm.prank(mockModule);
//         storage_.setDcaTargetToken(user1, mockToken2);
        
//         assertEq(storage_.dcaTargetToken(user1), mockToken2, "DCA target token not set correctly");
//     }

//     // Test DCA tick strategy
//     function testDcaTickStrategy() public {
//         beforeEach();
        
//         int24 tickDelta = 100;
//         uint256 tickExpiryTime = 2 days;
//         bool onlyImprovePrice = true;
//         int24 minTickImprovement = 50;
//         bool dynamicSizing = true;
//         uint256 customSlippageTolerance = 50; // 0.5%
        
//         vm.prank(mockModule);
//         storage_.setDcaTickStrategy(
//             user1,
//             tickDelta,
//             tickExpiryTime,
//             onlyImprovePrice,
//             minTickImprovement,
//             dynamicSizing,
//             customSlippageTolerance
//         );
        
//         (
//             int24 storedTickDelta,
//             uint256 storedTickExpiryTime,
//             bool storedOnlyImprovePrice,
//             int24 storedMinTickImprovement,
//             bool storedDynamicSizing,
//             uint256 storedCustomSlippageTolerance
//         ) = storage_.getDcaTickStrategy(user1);
        
//         assertEq(storedTickDelta, tickDelta, "TickDelta not stored correctly");
//         assertEq(storedTickExpiryTime, tickExpiryTime, "TickExpiryTime not stored correctly");
//         assertEq(storedOnlyImprovePrice, onlyImprovePrice, "OnlyImprovePrice not stored correctly");
//         assertEq(storedMinTickImprovement, minTickImprovement, "MinTickImprovement not stored correctly");
//         assertEq(storedDynamicSizing, dynamicSizing, "DynamicSizing not stored correctly");
//         assertEq(storedCustomSlippageTolerance, customSlippageTolerance, "CustomSlippageTolerance not stored correctly");
//     }

//     // Test DCA queue operations
//     function testDcaQueueOperations() public {
//         beforeEach();
        
//         address fromToken = mockToken1;
//         address toToken = mockToken2;
//         uint256 amount = 1000 ether;
//         int24 executionTick = 200000;
//         uint256 deadline = block.timestamp + 1 days;
//         uint256 customSlippageTolerance = 50;
        
//         // Add to queue
//         vm.prank(mockModule);
//         storage_.addToDcaQueue(
//             user1,
//             fromToken,
//             toToken,
//             amount,
//             executionTick,
//             deadline,
//             customSlippageTolerance
//         );
        
//         // Verify queue length
//         assertEq(storage_.getDcaQueueLength(user1), 1, "DCA queue length should be 1");
        
//         // Get queue item
//         (
//             address storedFromToken,
//             address storedToToken,
//             uint256 storedAmount,
//             int24 storedExecutionTick,
//             uint256 storedDeadline,
//             bool storedExecuted,
//             uint256 storedCustomSlippageTolerance
//         ) = storage_.getDcaQueueItem(user1, 0);
        
//         assertEq(storedFromToken, fromToken, "FromToken not stored correctly");
//         assertEq(storedToToken, toToken, "ToToken not stored correctly");
//         assertEq(storedAmount, amount, "Amount not stored correctly");
//         assertEq(storedExecutionTick, executionTick, "ExecutionTick not stored correctly");
//         assertEq(storedDeadline, deadline, "Deadline not stored correctly");
//         assertEq(storedExecuted, false, "Executed should be false initially");
//         assertEq(storedCustomSlippageTolerance, customSlippageTolerance, "CustomSlippageTolerance not stored correctly");
        
//         // Mark as executed
//         vm.prank(mockModule);
//         storage_.markDcaExecuted(user1, 0);
        
//         // Verify executed status
//         (,,,,,storedExecuted,) = storage_.getDcaQueueItem(user1, 0);
//         assertEq(storedExecuted, true, "Executed should be true after marking");
        
//         // Test out of bounds access
//         vm.prank(mockModule);
//         vm.expectRevert(abi.encodeWithSignature("IndexOutOfBounds()"));
//         storage_.getDcaQueueItem(user1, 1);
        
//         vm.prank(mockModule);
//         vm.expectRevert(abi.encodeWithSignature("IndexOutOfBounds()"));
//         storage_.markDcaExecuted(user1, 1);
//     }

//     // Test pool ticks
//     function testPoolTicks() public {
//         beforeEach();
        
//         PoolId poolId = PoolId.wrap(keccak256(abi.encode("test-pool-id"))); // Explicitly wrap into PoolId
//         int24 tick = 123456;
        
//         vm.prank(mockModule);
//         storage_.setPoolTick(poolId, tick);
        
//         assertEq(storage_.poolTicks(poolId), tick, "Pool tick not set correctly");
//     }


//     // Test swap context operations
//     function testSwapContext() public {
//         beforeEach();
        
//         SpendSaveStorage.SwapContext memory context = SpendSaveStorage.SwapContext({
//             hasStrategy: true,
//             currentPercentage: 1000,
//             roundUpSavings: true,
//             enableDCA: true,
//             dcaTargetToken: mockToken2,
//             currentTick: 123456,
//             savingsTokenType: SpendSaveStorage.SavingsTokenType.OUTPUT,
//             specificSavingsToken: address(0),
//             inputToken: mockToken1,
//             inputAmount: 1000 ether,
//             pendingSaveAmount: 100 ether
//         });
        
//         vm.prank(mockModule);
//         storage_.setSwapContext(user1, context);
        
//         vm.prank(mockModule);
//         SpendSaveStorage.SwapContext memory storedContext = storage_.getSwapContext(user1);
        
//         assertEq(storedContext.hasStrategy, context.hasStrategy, "HasStrategy not stored correctly");
//         assertEq(storedContext.currentPercentage, context.currentPercentage, "CurrentPercentage not stored correctly");
//         assertEq(storedContext.roundUpSavings, context.roundUpSavings, "RoundUpSavings not stored correctly");
//         assertEq(storedContext.enableDCA, context.enableDCA, "EnableDCA not stored correctly");
//         assertEq(storedContext.dcaTargetToken, context.dcaTargetToken, "DcaTargetToken not stored correctly");
//         assertEq(storedContext.currentTick, context.currentTick, "CurrentTick not stored correctly");
//         assertEq(uint(storedContext.savingsTokenType), uint(context.savingsTokenType), "SavingsTokenType not stored correctly");
//         assertEq(storedContext.specificSavingsToken, context.specificSavingsToken, "SpecificSavingsToken not stored correctly");
//         assertEq(storedContext.inputToken, context.inputToken, "InputToken not stored correctly");
//         assertEq(storedContext.inputAmount, context.inputAmount, "InputAmount not stored correctly");
//         assertEq(storedContext.pendingSaveAmount, context.pendingSaveAmount, "PendingSaveAmount not stored correctly");
        
//         // Test delete
//         vm.prank(mockModule);
//         storage_.deleteSwapContext(user1);
        
//         vm.prank(mockModule);
//         SpendSaveStorage.SwapContext memory deletedContext = storage_.getSwapContext(user1);
        
//         assertEq(deletedContext.hasStrategy, false, "HasStrategy should be reset");
//     }

//     // Test yield strategies
//     function testYieldStrategy() public {
//         beforeEach();
        
//         SpendSaveStorage.YieldStrategy strategy = SpendSaveStorage.YieldStrategy.AAVE;
        
//         vm.prank(mockModule);
//         storage_.setYieldStrategy(user1, mockToken1, strategy);
        
//         assertEq(uint(storage_.getYieldStrategy(user1, mockToken1)), uint(strategy), "Yield strategy not set correctly");
//     }

//     // Test slippage settings
//     function testSlippageSettings() public {
//         beforeEach();
        
//         uint256 userTolerance = 50; // 0.5%
//         uint256 tokenTolerance = 30; // 0.3%
//         SpendSaveStorage.SlippageAction action = SpendSaveStorage.SlippageAction.REVERT;
//         uint256 defaultTolerance = 100; // 1%
        
//         vm.startPrank(mockModule);
//         storage_.setUserSlippageTolerance(user1, userTolerance);
//         storage_.setTokenSlippageTolerance(user1, mockToken1, tokenTolerance);
//         storage_.setSlippageExceededAction(user1, action);
//         storage_.setDefaultSlippageTolerance(defaultTolerance);
//         vm.stopPrank();
        
//         assertEq(storage_.userSlippageTolerance(user1), userTolerance, "User slippage tolerance not set correctly");
//         assertEq(storage_.tokenSlippageTolerance(user1, mockToken1), tokenTolerance, "Token slippage tolerance not set correctly");
//         assertEq(uint(storage_.slippageExceededAction(user1)), uint(action), "Slippage exceeded action not set correctly");
//         assertEq(storage_.defaultSlippageTolerance(), defaultTolerance, "Default slippage tolerance not set correctly");
//     }

//     // Test ERC6909 token operations
//     function testERC6909Operations() public {
//         beforeEach();
        
//         uint256 id = 1;
//         uint256 amount = 1000 ether;
        
//         vm.startPrank(mockModule);
        
//         // Test balance operations
//         storage_.setBalance(user1, id, amount);
//         assertEq(storage_.getBalance(user1, id), amount, "Balance not set correctly");
        
//         storage_.increaseBalance(user1, id, 500 ether);
//         assertEq(storage_.getBalance(user1, id), amount + 500 ether, "Balance not increased correctly");
        
//         storage_.decreaseBalance(user1, id, 200 ether);
//         assertEq(storage_.getBalance(user1, id), amount + 500 ether - 200 ether, "Balance not decreased correctly");
        
//         // Test allowance
//         storage_.setAllowance(user1, user2, id, 300 ether);
//         assertEq(storage_.getAllowance(user1, user2, id), 300 ether, "Allowance not set correctly");
        
//         // Test token ID mapping
//         uint256 nextTokenId = storage_.getNextTokenId();
//         assertEq(nextTokenId, 1, "Initial token ID should be 1");
        
//         uint256 newTokenId = storage_.incrementNextTokenId();
//         assertEq(newTokenId, 1, "Should return old value when incrementing");
//         assertEq(storage_.getNextTokenId(), 2, "Next token ID should be incremented");
        
//         storage_.setTokenToId(mockToken1, id);
//         storage_.setIdToToken(id, mockToken1);
        
//         assertEq(storage_.tokenToId(mockToken1), id, "Token to ID mapping not set correctly");
//         assertEq(storage_.idToToken(id), mockToken1, "ID to token mapping not set correctly");
        
//         vm.stopPrank();
        
//         // Test insufficient balance revert
//         vm.prank(mockModule);
//         vm.expectRevert(abi.encodeWithSignature("InsufficientBalance()"));
//         storage_.decreaseBalance(user1, id + 1, 1 ether);
//     }

//     // Test daily savings operations
//     function testDailySavingsOperations() public {
//         beforeEach();
        
//         address token = mockToken1;
//         uint256 amount = 100 ether;
        
//         vm.prank(mockModule);
//         storage_.setDailySavingsAmount(user1, token, amount);
        
//         assertEq(storage_.getDailySavingsAmount(user1, token), amount, "Daily savings amount not set correctly");
        
//         // Configure daily savings
//         SpendSaveStorage.DailySavingsConfigParams memory params = SpendSaveStorage.DailySavingsConfigParams({
//             enabled: true,
//             goalAmount: 1000 ether,
//             currentAmount: 200 ether,
//             penaltyBps: 500, // 5%
//             endTime: block.timestamp + 30 days
//         });
        
//         vm.prank(mockModule);
//         storage_.setDailySavingsConfig(user1, token, params);
        
//         // Update execution
//         vm.prank(mockModule);
//         storage_.updateDailySavingsExecution(user1, token, 50 ether);
        
//         (
//             bool enabled,
//             uint256 lastExecutionTime,
//             uint256 startTime,
//             uint256 goalAmount,
//             uint256 currentAmount,
//             uint256 penaltyBps,
//             uint256 endTime
//         ) = storage_.getDailySavingsConfig(user1, token);
        
//         assertEq(enabled, true, "Enabled flag not updated correctly");
//         assertEq(lastExecutionTime, block.timestamp, "Last execution time not updated correctly");
//         assertEq(currentAmount, 250 ether, "Current amount not updated correctly (200 + 50)");
        
//         // Test yield strategy
//         SpendSaveStorage.YieldStrategy strategy = SpendSaveStorage.YieldStrategy.COMPOUND;
        
//         vm.prank(mockModule);
//         storage_.setDailySavingsYieldStrategy(user1, token, strategy);
        
//         assertEq(uint(storage_.getDailySavingsYieldStrategy(user1, token)), uint(strategy), "Daily savings yield strategy not set correctly");
        
//         // Get user savings tokens
//         address[] memory tokens = storage_.getUserSavingsTokens(user1);
//         assertEq(tokens.length, 1, "Should have 1 token");
//         assertEq(tokens[0], token, "Token address not stored correctly");
//     }

// }