// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Foundry libraries
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

// Our contracts
import {SpendSaveHook} from "../src/SpendSaveHook.sol";
import {SpendSaveStorage} from "../src/SpendSaveStorage.sol";
import {SavingStrategy} from "../src/SavingStrategy.sol";
import {Savings} from "../src/Savings.sol";
import {DCA} from "../src/DCA.sol";
import {SlippageControl} from "../src/SlippageControl.sol";
import {Token} from "../src/Token.sol";
import {DailySavings} from "../src/DailySavings.sol";

contract MockYieldModule {
    function applyYieldStrategy(address user, address token) external {}
}

contract SpendSaveHookTest is Test, Deployers {
    // Use the libraries
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Main contracts
    SpendSaveHook hook;
    SpendSaveStorage storage_;
    
    // Module contracts
    SavingStrategy savingStrategyModule;
    Savings savingsModule;
    DCA dcaModule;
    SlippageControl slippageControlModule;
    Token tokenModule;
    DailySavings dailySavingsModule;
    MockYieldModule yieldModule;

    // The two currencies (tokens) from the pool
    Currency token0;
    Currency token1;
    
    // Additional test token
    Currency token2;

    // Users for testing
    address user1;
    address user2;
    address treasury;
    
    // PoolKey for our test pool
    PoolKey poolKey;

    function setUp() public {
        // Set up test users
        user1 = address(0x1);
        user2 = address(0x2);
        treasury = address(0x3);
        
        vm.startPrank(address(this));
        
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();

        // Deploy three test tokens
        MockERC20 mockToken0 = new MockERC20("Token0", "TK0", 18);
        MockERC20 mockToken1 = new MockERC20("Token1", "TK1", 18);
        MockERC20 mockToken2 = new MockERC20("Token2", "TK2", 18);
        
        token0 = Currency.wrap(address(mockToken0));
        token1 = Currency.wrap(address(mockToken1));
        token2 = Currency.wrap(address(mockToken2));
        
        // Mint tokens to test users
        mockToken0.mint(user1, 100 ether);
        mockToken1.mint(user1, 100 ether);
        mockToken2.mint(user1, 100 ether);
        
        mockToken0.mint(user2, 100 ether);
        mockToken1.mint(user2, 100 ether);
        mockToken2.mint(user2, 100 ether);
        
        // Deploy storage contract
        storage_ = new SpendSaveStorage(address(this), treasury, manager);
        
        // Deploy modules
        savingStrategyModule = new SavingStrategy();
        savingsModule = new Savings();
        dcaModule = new DCA();
        slippageControlModule = new SlippageControl();
        tokenModule = new Token();
        dailySavingsModule = new DailySavings();
        yieldModule = new MockYieldModule();
        
        // Deploy SpendSaveHook with the correct flags for beforeSwap and afterSwap
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddress = address(uint160(flags));
        
        // Generate the bytecode and deploy to the hookAddress
        bytes memory hookBytecode = abi.encodePacked(
            type(SpendSaveHook).creationCode,
            abi.encode(manager, address(storage_))
        );
        
        vm.etch(hookAddress, hookBytecode);
        hook = SpendSaveHook(hookAddress);
        
        // Initialize all modules
        savingStrategyModule.initialize(storage_);
        savingsModule.initialize(storage_);
        dcaModule.initialize(storage_);
        slippageControlModule.initialize(storage_);
        tokenModule.initialize(storage_);
        dailySavingsModule.initialize(storage_);
        
        // Set module references
        savingStrategyModule.setModuleReferences(address(savingsModule));
        savingsModule.setModuleReferences(address(tokenModule), address(savingStrategyModule));
        dcaModule.setModuleReferences(address(tokenModule), address(slippageControlModule));
        dailySavingsModule.setModuleReferences(address(tokenModule), address(yieldModule));
        
        // Initialize the hook with all modules
        hook.initializeModules(
            address(savingStrategyModule),
            address(savingsModule),
            address(dcaModule),
            address(slippageControlModule),
            address(tokenModule),
            address(dailySavingsModule)
        );
        
        // Approve tokens for router
        mockToken0.approve(address(swapRouter), type(uint256).max);
        mockToken1.approve(address(swapRouter), type(uint256).max);
        mockToken2.approve(address(swapRouter), type(uint256).max);
        
        // Approve tokens for the hook
        mockToken0.approve(address(hook), type(uint256).max);
        mockToken1.approve(address(hook), type(uint256).max);
        mockToken2.approve(address(hook), type(uint256).max);
        
        // Initialize a pool with two tokens and our hook
        (poolKey, ) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);
        
        // Add initial liquidity to the pool
        
        // Liquidity from -60 to +60 tick range
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        // Liquidity from -120 to +120 tick range
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        // Full range liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        SAVING STRATEGY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetSavingStrategy() public {
        vm.startPrank(user1);
        
        // Set saving strategy for user1
        savingStrategyModule.setSavingStrategy(
            user1,
            500, // 5% saving percentage
            0,   // No auto-increment
            1000, // 10% max percentage
            false, // Don't round up
            SpendSaveStorage.SavingsTokenType.OUTPUT, // Save from output
            address(0) // No specific token
        );
        
        // Get the saving strategy
        (
            uint256 percentage,
            uint256 autoIncrement,
            uint256 maxPercentage,
            ,
            bool roundUpSavings,
            ,
            SpendSaveStorage.SavingsTokenType savingsTokenType,
            address specificSavingsToken
        ) = storage_.getUserSavingStrategy(user1);
        
        // Assert all values are correct
        assertEq(percentage, 500);
        assertEq(autoIncrement, 0);
        assertEq(maxPercentage, 1000);
        assertEq(roundUpSavings, false);
        assertEq(uint8(savingsTokenType), uint8(SpendSaveStorage.SavingsTokenType.OUTPUT));
        assertEq(specificSavingsToken, address(0));
        
        vm.stopPrank();
    }

    function test_SetSavingStrategyWithSpecificToken() public {
        vm.startPrank(user1);
        
        // Set saving strategy for user1 with specific token
        savingStrategyModule.setSavingStrategy(
            user1,
            500, // 5% saving percentage
            50,  // 0.5% auto-increment per swap
            1000, // 10% max percentage
            true, // Round up
            SpendSaveStorage.SavingsTokenType.SPECIFIC, // Save to specific token
            Currency.unwrap(token2) // Specific token
        );
        
        // Get the saving strategy
        (
            uint256 percentage,
            uint256 autoIncrement,
            uint256 maxPercentage,
            ,
            bool roundUpSavings,
            ,
            SpendSaveStorage.SavingsTokenType savingsTokenType,
            address specificSavingsToken
        ) = storage_.getUserSavingStrategy(user1);
        
        // Assert all values are correct
        assertEq(percentage, 500);
        assertEq(autoIncrement, 50);
        assertEq(maxPercentage, 1000);
        assertEq(roundUpSavings, true);
        assertEq(uint8(savingsTokenType), uint8(SpendSaveStorage.SavingsTokenType.SPECIFIC));
        assertEq(specificSavingsToken, Currency.unwrap(token2));
        
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           SWAP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SwapWithOutputSavings() public {
        vm.startPrank(user1);
        
        // Set saving strategy for user1
        savingStrategyModule.setSavingStrategy(
            user1,
            1000, // 10% saving percentage
            0,    // No auto-increment
            1000, // 10% max percentage
            false, // Don't round up
            SpendSaveStorage.SavingsTokenType.OUTPUT, // Save from output
            address(0) // No specific token
        );
        
        // Approve tokens for swap
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        
        // Get initial balances
        uint256 initialToken0Balance = MockERC20(Currency.unwrap(token0)).balanceOf(user1);
        uint256 initialToken1Balance = MockERC20(Currency.unwrap(token1)).balanceOf(user1);
        
        // Get initial savings
        uint256 initialSavings = storage_.savings(user1, Currency.unwrap(token1));
        
        // Swap token0 for token1
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1 ether, // Swap 1 token0
            sqrtPriceLimitX96: 0
        });
        
        BalanceDelta delta = swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        
        // Since we're swapping token0 for token1 (zeroForOne), 
        // the delta should be negative for token0 and positive for token1
        int256 token0Delta = delta.amount0();
        int256 token1Delta = delta.amount1();
        
        // Calculate the expected values
        uint256 token0Used = uint256(-token0Delta);
        uint256 token1Received = uint256(token1Delta);
        uint256 expectedSavings = token1Received * 1000 / 10000; // 10% of output
        
        // Get the final balances
        uint256 finalToken0Balance = MockERC20(Currency.unwrap(token0)).balanceOf(user1);
        uint256 finalToken1Balance = MockERC20(Currency.unwrap(token1)).balanceOf(user1);
        
        // Get the final savings
        uint256 finalSavings = storage_.savings(user1, Currency.unwrap(token1));
        
        // Assert the balances
        assertEq(initialToken0Balance - finalToken0Balance, token0Used);
        assertEq(finalToken1Balance - initialToken1Balance, token1Received - expectedSavings);
        
        // Assert the savings (with some tolerance for fee calculations)
        uint256 actualSavingsIncrease = finalSavings - initialSavings;
        assertApproxEqRel(actualSavingsIncrease, expectedSavings, 0.01e18); // 1% tolerance for fees
        
        vm.stopPrank();
    }

    function test_SwapWithInputSavings() public {
        vm.startPrank(user1);
        
        // Set saving strategy for user1
        savingStrategyModule.setSavingStrategy(
            user1,
            1000, // 10% saving percentage
            0,    // No auto-increment
            1000, // 10% max percentage
            false, // Don't round up
            SpendSaveStorage.SavingsTokenType.INPUT, // Save from input
            address(0) // No specific token
        );
        
        // Approve tokens for swap
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);
        
        // Get initial balances
        uint256 initialToken0Balance = MockERC20(Currency.unwrap(token0)).balanceOf(user1);
        uint256 initialToken1Balance = MockERC20(Currency.unwrap(token1)).balanceOf(user1);
        
        // Get initial savings
        uint256 initialSavings = storage_.savings(user1, Currency.unwrap(token0));
        
        // Swap token0 for token1
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1 ether, // Swap 1 token0
            sqrtPriceLimitX96: 0
        });
        
        BalanceDelta delta = swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        
        // Since we're swapping token0 for token1 (zeroForOne), 
        // the delta should be negative for token0 and positive for token1
        int256 token0Delta = delta.amount0();
        int256 token1Delta = delta.amount1();
        
        // Calculate the expected values
        uint256 token0Used = uint256(-token0Delta);
        uint256 token1Received = uint256(token1Delta);
        uint256 expectedSavings = 1 ether * 1000 / 10000; // 10% of 1 ether input
        
        // Get the final balances
        uint256 finalToken0Balance = MockERC20(Currency.unwrap(token0)).balanceOf(user1);
        uint256 finalToken1Balance = MockERC20(Currency.unwrap(token1)).balanceOf(user1);
        
        // Get the final savings
        uint256 finalSavings = storage_.savings(user1, Currency.unwrap(token0));
        
        // Assert the balances
        assertEq(initialToken0Balance - finalToken0Balance, token0Used + expectedSavings);
        assertEq(finalToken1Balance - initialToken1Balance, token1Received);
        
        // Assert the savings (with some tolerance for fee calculations)
        uint256 actualSavingsIncrease = finalSavings - initialSavings;
        assertApproxEqRel(actualSavingsIncrease, expectedSavings, 0.01e18); // 1% tolerance for fees
        
        vm.stopPrank();
    }

    function test_SwapWithAutoIncrement() public {
        vm.startPrank(user1);
        
        // Set saving strategy for user1 with auto-increment
        savingStrategyModule.setSavingStrategy(
            user1,
            500, // 5% initial saving percentage
            100, // 1% auto-increment per swap
            1000, // 10% max percentage
            false, // Don't round up
            SpendSaveStorage.SavingsTokenType.OUTPUT, // Save from output
            address(0) // No specific token
        );
        
        // Approve tokens for swap
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        
        // First swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1 ether, // Swap 1 token0
            sqrtPriceLimitX96: 0
        });
        
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        
        // Get the saving strategy after first swap
        (uint256 percentageAfterFirstSwap,,,,,,, ) = storage_.getUserSavingStrategy(user1);
        
        // Should be incremented to 6%
        assertEq(percentageAfterFirstSwap, 600);
        
        // Second swap
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        
        // Get the saving strategy after second swap
        (uint256 percentageAfterSecondSwap,,,,,,, ) = storage_.getUserSavingStrategy(user1);
        
        // Should be incremented to 7%
        assertEq(percentageAfterSecondSwap, 700);
        
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          WITHDRAWAL TESTS
    //////////////////////////////////////////////////////////////*/

    function test_WithdrawSavings() public {
        vm.startPrank(user1);
        
        // Set saving strategy for user1
        savingStrategyModule.setSavingStrategy(
            user1,
            1000, // 10% saving percentage
            0,    // No auto-increment
            1000, // 10% max percentage
            false, // Don't round up
            SpendSaveStorage.SavingsTokenType.OUTPUT, // Save from output
            address(0) // No specific token
        );
        
        // Approve tokens for swap
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        
        // Swap to generate some savings
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 2 ether, // Swap 2 token0
            sqrtPriceLimitX96: 0
        });
        
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        
        // Get savings after swap
        uint256 savingsAfterSwap = storage_.savings(user1, Currency.unwrap(token1));
        assertTrue(savingsAfterSwap > 0, "No savings generated");
        
        // Get token balance before withdrawal
        uint256 balanceBeforeWithdrawal = MockERC20(Currency.unwrap(token1)).balanceOf(user1);
        
        // Withdraw half of the savings
        uint256 withdrawAmount = savingsAfterSwap / 2;
        savingsModule.withdrawSavings(user1, Currency.unwrap(token1), withdrawAmount);
        
        // Get savings after withdrawal
        uint256 savingsAfterWithdrawal = storage_.savings(user1, Currency.unwrap(token1));
        
        // Get token balance after withdrawal
        uint256 balanceAfterWithdrawal = MockERC20(Currency.unwrap(token1)).balanceOf(user1);
        
        // Assert the savings were decreased correctly
        assertEq(savingsAfterWithdrawal, savingsAfterSwap - withdrawAmount);
        
        // Assert the token balance increased correctly (considering potential fees)
        uint256 expectedFee = withdrawAmount * storage_.treasuryFee() / 10000;
        uint256 expectedBalanceIncrease = withdrawAmount - expectedFee;
        assertApproxEqRel(balanceAfterWithdrawal - balanceBeforeWithdrawal, expectedBalanceIncrease, 0.01e18);
        
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            DCA TESTS
    //////////////////////////////////////////////////////////////*/

    function test_EnableDCA() public {
        vm.startPrank(user1);
        
        // Enable DCA for user1 targeting token2
        dcaModule.enableDCA(user1, Currency.unwrap(token2), true);
        
        // Get the saving strategy
        (
            ,
            ,
            ,
            ,
            ,
            bool enableDCA,
            ,
            
        ) = storage_.getUserSavingStrategy(user1);
        
        // Assert DCA is enabled
        assertTrue(enableDCA);
        
        // Assert target token is set correctly
        assertEq(storage_.dcaTargetToken(user1), Currency.unwrap(token2));
        
        vm.stopPrank();
    }

    function test_QueueDCAFromSwap() public {
        vm.startPrank(user1);
        
        // Setup saving strategy with DCA enabled
        savingStrategyModule.setSavingStrategy(
            user1,
            1000, // 10% saving percentage
            0,    // No auto-increment
            1000, // 10% max percentage
            false, // Don't round up
            SpendSaveStorage.SavingsTokenType.OUTPUT, // Save from output
            address(0) // No specific token
        );
        
        // Enable DCA targeting token2
        dcaModule.enableDCA(user1, Currency.unwrap(token2), true);
        
        // Approve tokens for swap
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        
        // Swap to generate some savings
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 2 ether, // Swap 2 token0
            sqrtPriceLimitX96: 0
        });
        
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        
        // Get savings after swap
        uint256 savingsAfterSwap = storage_.savings(user1, Currency.unwrap(token1));
        assertTrue(savingsAfterSwap > 0, "No savings generated");
        
        // Get DCA queue length
        uint256 queueLength = storage_.getDcaQueueLength(user1);
        
        // Assert a DCA was queued
        assertEq(queueLength, 1);
        
        // Get the queued DCA
        (
            address fromToken,
            address toToken,
            uint256 amount,
            ,
            ,
            bool executed,
            
        ) = storage_.getDcaQueueItem(user1, 0);
        
        // Assert DCA details
        assertEq(fromToken, Currency.unwrap(token1));
        assertEq(toToken, Currency.unwrap(token2));
        assertEq(amount, savingsAfterSwap);
        assertEq(executed, false);
        
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        DAILY SAVINGS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ConfigureDailySavings() public {
        vm.startPrank(user1);
        
        // Configure daily savings for token0
        uint256 dailyAmount = 0.1 ether;
        uint256 goalAmount = 10 ether;
        uint256 penaltyBps = 500; // 5% penalty
        uint256 endTime = block.timestamp + 30 days;
        
        // Approve tokens for daily savings
        MockERC20(Currency.unwrap(token0)).approve(address(dailySavingsModule), type(uint256).max);
        
        // Configure daily savings
        dailySavingsModule.configureDailySavings(
            user1,
            Currency.unwrap(token0),
            dailyAmount,
            goalAmount,
            penaltyBps,
            endTime
        );
        
        // Get daily savings config
        (
            bool enabled,
            uint256 lastExecutionTime,
            uint256 startTime,
            uint256 configGoalAmount,
            uint256 currentAmount,
            uint256 configPenaltyBps,
            uint256 configEndTime
        ) = storage_.getDailySavingsConfig(user1, Currency.unwrap(token0));
        
        // Assert daily savings is enabled and configured correctly
        assertTrue(enabled);
        assertEq(lastExecutionTime, block.timestamp);
        assertEq(startTime, block.timestamp);
        assertEq(configGoalAmount, goalAmount);
        assertEq(currentAmount, 0);
        assertEq(configPenaltyBps, penaltyBps);
        assertEq(configEndTime, endTime);
        
        // Assert daily amount is set correctly
        assertEq(storage_.getDailySavingsAmount(user1, Currency.unwrap(token0)), dailyAmount);
        
        vm.stopPrank();
    }

    function test_ExecuteDailySavings() public {
        vm.startPrank(user1);
        
        // Configure daily savings for token0
        uint256 dailyAmount = 0.1 ether;
        uint256 goalAmount = 10 ether;
        
        // Approve tokens for daily savings
        MockERC20(Currency.unwrap(token0)).approve(address(dailySavingsModule), type(uint256).max);
        
        // Configure daily savings
        dailySavingsModule.configureDailySavings(
            user1,
            Currency.unwrap(token0),
            dailyAmount,
            goalAmount,
            0, // No penalty
            0  // No end time
        );
        
        // Advance time by 2 days
        vm.warp(block.timestamp + 2 days);
        
        // Get initial balances
        uint256 initialToken0Balance = MockERC20(Currency.unwrap(token0)).balanceOf(user1);
        
        // Execute daily savings
        uint256 savedAmount = dailySavingsModule.executeDailySavingsForToken(user1, Currency.unwrap(token0));
        
        // Expected saved amount (2 days * daily amount)
        uint256 expectedSavedAmount = dailyAmount * 2;
        
        // Assert saved amount
        assertEq(savedAmount, expectedSavedAmount);
        
        // Get final balances
        uint256 finalToken0Balance = MockERC20(Currency.unwrap(token0)).balanceOf(user1);
        
        // Assert token balance decreased correctly
        assertEq(initialToken0Balance - finalToken0Balance, expectedSavedAmount);
        
        // Get daily savings config after execution
        (
            ,
            uint256 lastExecutionTime,
            ,
            ,
            uint256 currentAmount,
            ,
            
        ) = storage_.getDailySavingsConfig(user1, Currency.unwrap(token0));
        
        // Assert last execution time and current amount updated correctly
        assertEq(lastExecutionTime, block.timestamp);
        assertEq(currentAmount, expectedSavedAmount);
        
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                         COMBINED TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FullFlowWithHook() public {
        vm.startPrank(user1);
        
        // 1. Set up saving strategy with auto-increment and DCA
        savingStrategyModule.setSavingStrategy(
            user1,
            500, // 5% saving percentage
            100, // 1% auto-increment per swap
            1500, // 15% max percentage
            true, // Round up
            SpendSaveStorage.SavingsTokenType.OUTPUT, // Save from output
            address(0) // No specific token
        );
        
        // 2. Enable DCA targeting token2
        dcaModule.enableDCA(user1, Currency.unwrap(token2), true);
        
        // 3. Configure daily savings for token0
        uint256 dailyAmount = 0.1 ether;
        MockERC20(Currency.unwrap(token0)).approve(address(dailySavingsModule), type(uint256).max);
        dailySavingsModule.configureDailySavings(
            user1,
            Currency.unwrap(token0),
            dailyAmount,
            10 ether, // Goal
            0, // No penalty
            0  // No end time
        );
        
        // 4. Approve tokens for swap
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        
        // 5. Perform first swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1 ether, // Swap 1 token0
            sqrtPriceLimitX96: 0
        });
        
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        
        // 6. Verify saving strategy was updated (should be 6%)
        (uint256 percentage,,,,,,, ) = storage_.getUserSavingStrategy(user1);
        assertEq(percentage, 600);
        
        // 7. Verify savings were generated
        uint256 savingsAfterFirstSwap = storage_.savings(user1, Currency.unwrap(token1));
        assertTrue(savingsAfterFirstSwap > 0, "No savings generated from first swap");
        
        // 8. Verify a DCA was queued
        uint256 queueLength = storage_.getDcaQueueLength(user1);
        assertEq(queueLength, 1);
        
        // 9. Advance time by 1 day to trigger daily savings
        vm.warp(block.timestamp + 1 days);
        
        // 10. Perform second swap (should trigger daily savings execution in the hook)
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        
        // 11. Verify saving strategy was updated again (should be 7%)
        (uint256 updatedPercentage,,,,,,, ) = storage_.getUserSavingStrategy(user1);
        assertEq(updatedPercentage, 700);
        
        // 12. Verify daily savings were executed
        (
            ,
            uint256 lastExecutionTime,
            ,
            ,
            uint256 currentAmount,
            ,
            
        ) = storage_.getDailySavingsConfig(user1, Currency.unwrap(token0));
        
        assertEq(lastExecutionTime, block.timestamp);
        assertEq(currentAmount, dailyAmount);
        
        // 13. Withdraw some savings
        uint256 withdrawAmount = savingsAfterFirstSwap / 2;
        savingsModule.withdrawSavings(user1, Currency.unwrap(token1), withdrawAmount);
        
        // 14. Verify savings were decreased
        uint256 savingsAfterWithdrawal = storage_.savings(user1, Currency.unwrap(token1));
        assertEq(savingsAfterWithdrawal, savingsAfterFirstSwap - withdrawAmount);
        
        vm.stopPrank();
    }
    
    /*//////////////////////////////////////////////////////////////
                        ERROR CASES TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RevertWhenInvalidPercentage() public {
        vm.startPrank(user1);
        
        // Try to set saving percentage > 100%
        vm.expectRevert(abi.encodeWithSelector(SavingStrategy.PercentageTooHigh.selector, 11000, 10000));
        savingStrategyModule.setSavingStrategy(
            user1,
            11000, // 110% saving percentage (invalid)
            0,
            12000,
            false,
            SpendSaveStorage.SavingsTokenType.OUTPUT,
            address(0)
        );
        
        vm.stopPrank();
    }
    
    function test_RevertWhenMaxPercentageTooLow() public {
        vm.startPrank(user1);
        
        // Try to set max percentage < current percentage
        vm.expectRevert(abi.encodeWithSelector(SavingStrategy.MaxPercentageTooLow.selector, 500, 1000));
        savingStrategyModule.setSavingStrategy(
            user1,
            1000, // 10% saving percentage
            0,
            500,  // 5% max percentage (invalid)
            false,
            SpendSaveStorage.SavingsTokenType.OUTPUT,
            address(0)
        );
        
        vm.stopPrank();
    }
    
    function test_RevertWhenInvalidSpecificToken() public {
        vm.startPrank(user1);
        
        // Try to set specific token type without a token address
        vm.expectRevert(SavingStrategy.InvalidSpecificToken.selector);
        savingStrategyModule.setSavingStrategy(
            user1,
            1000,
            0,
            1000,
            false,
            SpendSaveStorage.SavingsTokenType.SPECIFIC, // Specific token type
            address(0) // But no token address (invalid)
        );
        
        vm.stopPrank();
    }
    
    function test_RevertWhenInsufficientSavings() public {
        vm.startPrank(user1);
        
        // Set up saving strategy
        savingStrategyModule.setSavingStrategy(
            user1,
            1000,
            0,
            1000,
            false,
            SpendSaveStorage.SavingsTokenType.OUTPUT,
            address(0)
        );
        
        // Try to withdraw without any savings
        vm.expectRevert();
        savingsModule.withdrawSavings(user1, Currency.unwrap(token1), 1 ether);
        
        vm.stopPrank();
    }

    function test_RevertWhenUnauthorizedAccess() public {
        // Set up saving strategy as user1
        vm.startPrank(user1);
        savingStrategyModule.setSavingStrategy(
            user1,
            1000,
            0,
            1000,
            false,
            SpendSaveStorage.SavingsTokenType.OUTPUT,
            address(0)
        );
        vm.stopPrank();
        
        // Try to withdraw user1's savings as user2
        vm.startPrank(user2);
        vm.expectRevert();
        savingsModule.withdrawSavings(user1, Currency.unwrap(token1), 1 ether);
        vm.stopPrank();
    }
    
    /*//////////////////////////////////////////////////////////////
                            HOOK TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_HookPermissions() public {
        // Verify hook permissions
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        
        // Only beforeSwap and afterSwap should be enabled
        assertTrue(permissions.beforeSwap);
        assertTrue(permissions.afterSwap);
        
        // All other hooks should be disabled
        assertFalse(permissions.beforeInitialize);
        assertFalse(permissions.afterInitialize);
        assertFalse(permissions.beforeAddLiquidity);
        assertFalse(permissions.afterAddLiquidity);
        assertFalse(permissions.beforeRemoveLiquidity);
        assertFalse(permissions.afterRemoveLiquidity);
        assertFalse(permissions.beforeDonate);
        assertFalse(permissions.afterDonate);
        assertFalse(permissions.beforeSwapReturnDelta);
        assertFalse(permissions.afterSwapReturnDelta);
        assertFalse(permissions.afterAddLiquidityReturnDelta);
        assertFalse(permissions.afterRemoveLiquidityReturnDelta);
    }
    
    function test_ModulesInitialization() public {
        // Check that all modules are properly registered in storage
        assertEq(storage_.savingStrategyModule(), address(savingStrategyModule));
        assertEq(storage_.savingsModule(), address(savingsModule));
        assertEq(storage_.dcaModule(), address(dcaModule));
        assertEq(storage_.slippageControlModule(), address(slippageControlModule));
        assertEq(storage_.tokenModule(), address(tokenModule));
        assertEq(storage_.dailySavingsModule(), address(dailySavingsModule));
        assertEq(storage_.spendSaveHook(), address(hook));
    }
    
    function test_SwapContextManagement() public {
        vm.startPrank(user1);
        
        // Set saving strategy for user1
        savingStrategyModule.setSavingStrategy(
            user1,
            1000, // 10% saving percentage
            0,    // No auto-increment
            1000, // 10% max percentage
            false, // Don't round up
            SpendSaveStorage.SavingsTokenType.OUTPUT, // Save from output
            address(0) // No specific token
        );
        
        // Approve tokens for swap
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        
        // Get swap context before swap (should be empty)
        SpendSaveStorage.SwapContext memory contextBefore = storage_.getSwapContext(user1);
        assertFalse(contextBefore.hasStrategy);
        
        // Perform swap
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1 ether, // Swap 1 token0
            sqrtPriceLimitX96: 0
        });
        
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        
        // Get swap context after swap (should be cleared)
        SpendSaveStorage.SwapContext memory contextAfter = storage_.getSwapContext(user1);
        assertFalse(contextAfter.hasStrategy);
        
        vm.stopPrank();
    }
    
    /*//////////////////////////////////////////////////////////////
                          PROXY TESTS
    //////////////////////////////////////////////////////////////*/
    
    function test_TokenModuleProxyFunctions() public {
        vm.startPrank(user1);
        
        // Set saving strategy for user1
        savingStrategyModule.setSavingStrategy(
            user1,
            1000, // 10% saving percentage
            0,    // No auto-increment
            1000, // 10% max percentage
            false, // Don't round up
            SpendSaveStorage.SavingsTokenType.OUTPUT, // Save from output
            address(0) // No specific token
        );
        
        // Approve tokens for swap
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        
        // Perform swap to generate savings
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1 ether, // Swap 1 token0
            sqrtPriceLimitX96: 0
        });
        
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        
        // Get token ID for token1
        uint256 tokenId = tokenModule.getTokenId(Currency.unwrap(token1));
        assertTrue(tokenId > 0, "Token not registered");
        
        // Check balance via hook proxy function
        uint256 balance = hook.balanceOf(user1, tokenId);
        assertTrue(balance > 0, "No tokens minted");
        
        // Approve spending via hook proxy
        address spender = address(0x123);
        hook.approve(spender, tokenId, balance);
        
        // Check allowance via hook proxy
        uint256 allowance = hook.allowance(user1, spender, tokenId);
        assertEq(allowance, balance);
        
        vm.stopPrank();
    }
    
    /*//////////////////////////////////////////////////////////////
                          GAS OPTIMIZATIONS
    //////////////////////////////////////////////////////////////*/
    
    function test_DailySavingsGasOptimization() public {
        vm.startPrank(user1);
        
        // Configure multiple daily savings to test gas optimization
        for (uint i = 0; i < 3; i++) {
            address token = i == 0 ? Currency.unwrap(token0) : (i == 1 ? Currency.unwrap(token1) : Currency.unwrap(token2));
            MockERC20(token).approve(address(dailySavingsModule), type(uint256).max);
            
            dailySavingsModule.configureDailySavings(
                user1,
                token,
                0.1 ether,
                10 ether,
                0,
                0
            );
        }
        
        // Advance time by 1 day
        vm.warp(block.timestamp + 1 days);
        
        // Set up a swap that will trigger daily savings in the hook
        savingStrategyModule.setSavingStrategy(
            user1,
            1000,
            0,
            1000,
            false,
            SpendSaveStorage.SavingsTokenType.OUTPUT,
            address(0)
        );
        
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);
        
        uint256 gasBefore = gasleft();
        
        // This swap should trigger daily savings execution
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: 1 ether,
            sqrtPriceLimitX96: 0
        });
        
        swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        
        uint256 gasUsed = gasBefore - gasleft();
        
        // Log gas used for analysis
        console.log("Gas used for swap with daily savings execution: %d", gasUsed);
        
        // Verify daily savings were executed
        for (uint i = 0; i < 3; i++) {
            address token = i == 0 ? Currency.unwrap(token0) : (i == 1 ? Currency.unwrap(token1) : Currency.unwrap(token2));
            
            (
                ,
                uint256 lastExecutionTime,
                ,
                ,
                uint256 currentAmount,
                ,
                
            ) = storage_.getDailySavingsConfig(user1, token);
            
            // Each token should have been processed
            assertEq(lastExecutionTime, block.timestamp);
            assertEq(currentAmount, 0.1 ether);
        }
        
        vm.stopPrank();
    }
}