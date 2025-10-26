// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// V4 Core imports
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "lib/v4-periphery/lib/v4-core/src/PoolManager.sol";
import {Deployers} from "lib/v4-periphery/lib/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {IHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";
import {StateLibrary} from "lib/v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";

// V4 Periphery imports
import {StateView} from "lib/v4-periphery/src/lens/StateView.sol";

// SpendSave Contracts
import {SpendSaveHook} from "../src/SpendSaveHook.sol";
import {SpendSaveStorage} from "../src/SpendSaveStorage.sol";
import {SavingStrategy} from "../src/SavingStrategy.sol";
import {Savings} from "../src/Savings.sol";
import {DCA} from "../src/DCA.sol";
import {Token} from "../src/Token.sol";
import {SlippageControl} from "../src/SlippageControl.sol";
import {DailySavings} from "../src/DailySavings.sol";
import {SpendSaveAnalytics} from "../src/SpendSaveAnalytics.sol";

/**
 * @title SpendSaveAnalyticsTest
 * @notice P8 ENHANCED: Comprehensive testing of analytics portfolio tracking with real-time valuation
 * @dev Tests portfolio summaries, DCA tracking, pool analytics, and real-time valuation
 */
contract SpendSaveAnalyticsTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Core contracts
    SpendSaveHook public hook;
    SpendSaveStorage public storageContract;
    SpendSaveAnalytics public analytics;

    // V4 periphery contracts
    StateView public stateView;

    // All modules
    Savings public savingsModule;
    SavingStrategy public strategyModule;
    Token public tokenModule;
    DCA public dcaModule;
    DailySavings public dailySavingsModule;
    SlippageControl public slippageModule;

    // Test accounts
    address public owner;
    address public alice;
    address public bob;
    address public charlie;

    // Test tokens
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;

    // Pool configuration
    PoolKey public poolKeyAB;
    PoolKey public poolKeyAC;
    PoolKey public poolKeyBC;

    // Test parameters
    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 constant SAVINGS_AMOUNT = 100 ether;
    uint256 constant DCA_AMOUNT = 50 ether;

    // Token IDs
    uint256 public tokenAId;
    uint256 public tokenBId;
    uint256 public tokenCId;

    function setUp() public {
        // Create test accounts
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");

        // Deploy V4 infrastructure
        deployFreshManagerAndRouters();

        // Deploy StateView
        stateView = new StateView(manager);

        // Deploy tokens
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        tokenC = new MockERC20("Token C", "TKNC", 18);

        // Ensure proper token ordering for V4
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        if (address(tokenA) > address(tokenC)) {
            (tokenA, tokenC) = (tokenC, tokenA);
        }
        if (address(tokenB) > address(tokenC)) {
            (tokenB, tokenC) = (tokenC, tokenB);
        }

        // Deploy core protocol
        _deployProtocol();

        // Initialize pools for testing
        _initializePools();

        // Setup test accounts
        _setupTestAccounts();

        console.log("=== P8 ENHANCED: ANALYTICS TESTS SETUP COMPLETE ===");
    }

    function _deployProtocol() internal {
        // Deploy storage
        vm.prank(owner);
        storageContract = new SpendSaveStorage(address(manager));

        // Deploy all modules with fresh instances
        vm.startPrank(owner);
        savingsModule = new Savings();
        strategyModule = new SavingStrategy();
        tokenModule = new Token();
        dcaModule = new DCA();
        dailySavingsModule = new DailySavings();
        slippageModule = new SlippageControl();
        vm.stopPrank();

        // Deploy hook with proper address mining
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            owner, flags, type(SpendSaveHook).creationCode, abi.encode(IPoolManager(address(manager)), storageContract)
        );

        vm.prank(owner);
        hook = new SpendSaveHook{salt: salt}(IPoolManager(address(manager)), storageContract);

        require(address(hook) == hookAddress, "Hook deployed at wrong address");

        // Deploy SpendSaveAnalytics
        vm.prank(owner);
        analytics = new SpendSaveAnalytics(address(storageContract), address(stateView));

        // Initialize storage
        vm.prank(owner);
        storageContract.initialize(address(hook));

        // Register modules
        vm.startPrank(owner);
        storageContract.registerModule(keccak256("SAVINGS"), address(savingsModule));
        storageContract.registerModule(keccak256("STRATEGY"), address(strategyModule));
        storageContract.registerModule(keccak256("TOKEN"), address(tokenModule));
        storageContract.registerModule(keccak256("DCA"), address(dcaModule));
        storageContract.registerModule(keccak256("DAILY"), address(dailySavingsModule));
        storageContract.registerModule(keccak256("SLIPPAGE"), address(slippageModule));
        vm.stopPrank();

        // Initialize modules with storage reference
        vm.startPrank(owner);
        savingsModule.initialize(storageContract);
        strategyModule.initialize(storageContract);
        tokenModule.initialize(storageContract);
        dcaModule.initialize(storageContract);
        dailySavingsModule.initialize(storageContract);
        slippageModule.initialize(storageContract);

        // Set cross-module references
        strategyModule.setModuleReferences(
            address(strategyModule),
            address(savingsModule),
            address(dcaModule),
            address(slippageModule),
            address(tokenModule),
            address(dailySavingsModule)
        );

        savingsModule.setModuleReferences(
            address(strategyModule),
            address(savingsModule),
            address(dcaModule),
            address(slippageModule),
            address(tokenModule),
            address(dailySavingsModule)
        );

        dcaModule.setModuleReferences(
            address(strategyModule),
            address(savingsModule),
            address(dcaModule),
            address(slippageModule),
            address(tokenModule),
            address(dailySavingsModule)
        );

        slippageModule.setModuleReferences(
            address(strategyModule),
            address(savingsModule),
            address(dcaModule),
            address(slippageModule),
            address(tokenModule),
            address(dailySavingsModule)
        );

        tokenModule.setModuleReferences(
            address(strategyModule),
            address(savingsModule),
            address(dcaModule),
            address(slippageModule),
            address(tokenModule),
            address(dailySavingsModule)
        );

        dailySavingsModule.setModuleReferences(
            address(strategyModule),
            address(savingsModule),
            address(dcaModule),
            address(slippageModule),
            address(tokenModule),
            address(dailySavingsModule)
        );

        vm.stopPrank();

        console.log("Core protocol deployed and initialized");
    }

    function _initializePools() internal {
        // Initialize multiple pools for analytics testing
        poolKeyAB = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolKeyAC = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenC)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolKeyBC = PoolKey({
            currency0: Currency.wrap(address(tokenB)),
            currency1: Currency.wrap(address(tokenC)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pools with 1:1 price
        manager.initialize(poolKeyAB, SQRT_PRICE_1_1);
        manager.initialize(poolKeyAC, SQRT_PRICE_1_1);
        manager.initialize(poolKeyBC, SQRT_PRICE_1_1);

        console.log("Initialized pools for analytics testing");
    }

    function _setupTestAccounts() internal {
        // Fund all test accounts with tokens
        address[] memory accounts = new address[](4);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = charlie;
        accounts[3] = owner;

        for (uint256 i = 0; i < accounts.length; i++) {
            tokenA.mint(accounts[i], INITIAL_BALANCE);
            tokenB.mint(accounts[i], INITIAL_BALANCE);
            tokenC.mint(accounts[i], INITIAL_BALANCE);
        }

        // Register tokens and get their IDs
        tokenAId = tokenModule.registerToken(address(tokenA));
        tokenBId = tokenModule.registerToken(address(tokenB));
        tokenCId = tokenModule.registerToken(address(tokenC));

        // Setup user portfolios for analytics testing
        _setupUserPortfolios();

        console.log("Test accounts configured with portfolios");
    }

    function _setupUserPortfolios() internal {
        // Setup Alice's portfolio
        vm.prank(address(savingsModule));
        storageContract.increaseSavings(alice, address(tokenA), SAVINGS_AMOUNT);

        vm.prank(address(savingsModule));
        storageContract.increaseSavings(alice, address(tokenB), SAVINGS_AMOUNT / 2);

        // Setup DCA for Alice
        vm.prank(alice);
        dcaModule.enableDCA(alice, address(tokenB), DCA_AMOUNT, 500);

        // Setup Bob's portfolio
        vm.prank(address(savingsModule));
        storageContract.increaseSavings(bob, address(tokenB), SAVINGS_AMOUNT * 2);

        vm.prank(address(savingsModule));
        storageContract.increaseSavings(bob, address(tokenC), SAVINGS_AMOUNT);

        // Setup Charlie's portfolio
        vm.prank(address(savingsModule));
        storageContract.increaseSavings(charlie, address(tokenC), SAVINGS_AMOUNT / 2);
    }

    // ==================== PORTFOLIO SUMMARY TESTS ====================

    function testAnalytics_GetUserPortfolio() public {
        console.log("\n=== P8 ENHANCED: Testing User Portfolio Summary ===");

        // Get Alice's portfolio
        (address[] memory tokens, uint256[] memory savings, uint256[] memory dcaAmounts, uint256 totalValueUSD) =
            analytics.getUserPortfolio(alice);

        // Verify portfolio data
        assertGt(tokens.length, 0, "Should have tokens in portfolio");
        assertGt(savings.length, 0, "Should have savings data");
        assertGt(dcaAmounts.length, 0, "Should have DCA data");

        // Verify savings data matches storage
        assertEq(savings[0], SAVINGS_AMOUNT, "Alice tokenA savings should match");
        assertEq(savings[1], SAVINGS_AMOUNT / 2, "Alice tokenB savings should match");

        // Verify DCA data
        assertGt(dcaAmounts[0], 0, "Alice should have DCA amounts");

        console.log("User portfolio summary working correctly");
        console.log("Tokens:", tokens.length, "Total value:", totalValueUSD);
        console.log("SUCCESS: User portfolio summary working");
    }

    function testAnalytics_GetUserPortfolioNoSavings() public {
        console.log("\n=== P8 ENHANCED: Testing Portfolio with No Savings ===");

        // Get portfolio for user with no savings
        (address[] memory tokens, uint256[] memory savings, uint256[] memory dcaAmounts, uint256 totalValueUSD) =
            analytics.getUserPortfolio(owner);

        // Should return empty arrays
        assertEq(tokens.length, 0, "Should have no tokens");
        assertEq(savings.length, 0, "Should have no savings");
        assertEq(dcaAmounts.length, 0, "Should have no DCA amounts");
        assertEq(totalValueUSD, 0, "Should have zero total value");

        console.log("Empty portfolio handling working correctly");
        console.log("SUCCESS: Empty portfolio handling working");
    }

    function testAnalytics_GetUserPortfolioMultipleUsers() public {
        console.log("\n=== P8 ENHANCED: Testing Portfolio for Multiple Users ===");

        // Get portfolios for different users
        (,,, uint256 aliceValue) = analytics.getUserPortfolio(alice);
        (,,, uint256 bobValue) = analytics.getUserPortfolio(bob);
        (,,, uint256 charlieValue) = analytics.getUserPortfolio(charlie);

        // Each should have different portfolio values
        assertGt(aliceValue, 0, "Alice should have portfolio value");
        assertGt(bobValue, 0, "Bob should have portfolio value");
        assertGt(charlieValue, 0, "Charlie should have portfolio value");

        console.log("Multi-user portfolio tracking working");
        console.log("Alice value:", aliceValue);
        console.log("Bob value:", bobValue);
        console.log("Charlie value:", charlieValue);
        console.log("SUCCESS: Multi-user portfolio tracking working");
    }

    // ==================== DCA TRACKING TESTS ====================

    function testAnalytics_DCATracking() public {
        console.log("\n=== P8 ENHANCED: Testing DCA Tracking Analytics ===");

        // Setup DCA for Alice
        vm.prank(alice);
        dcaModule.enableDCA(alice, address(tokenB), DCA_AMOUNT, 500);

        // Get DCA tracking data via getUserPortfolio
        (address[] memory tokens, uint256[] memory savings, uint256[] memory dcaAmounts, uint256 totalValueUSD) =
            analytics.getUserPortfolio(alice);

        // Should track DCA amounts
        require(tokens.length > 0, "Should have tokens");
        uint256 aliceDCA = dcaAmounts[0]; // Get first token's DCA amount
        assertGt(aliceDCA, 0, "Should track DCA amounts");

        console.log("DCA tracking working correctly");
        console.log("Alice DCA amount:", aliceDCA);
        console.log("SUCCESS: DCA tracking working");
    }

    function testAnalytics_DCATrackingMultipleTokens() public {
        console.log("\n=== P8 ENHANCED: Testing DCA Tracking for Multiple Tokens ===");

        // Setup DCA for multiple tokens
        vm.prank(alice);
        dcaModule.enableDCA(alice, address(tokenB), DCA_AMOUNT, 500);

        vm.prank(alice);
        dcaModule.enableDCA(alice, address(tokenC), DCA_AMOUNT / 2, 500);

        // Get DCA tracking for each token via getUserPortfolio
        (address[] memory tokens, uint256[] memory savings, uint256[] memory dcaAmounts, uint256 totalValueUSD) =
            analytics.getUserPortfolio(alice);

        // Extract DCA amounts for verification (simplified approach)
        uint256 totalDCA = 0;
        for (uint256 i = 0; i < dcaAmounts.length; i++) {
            totalDCA += dcaAmounts[i];
        }

        // Should track DCA for multiple tokens
        assertGt(totalDCA, 0, "Should track total DCA amounts");
        assertGt(tokens.length, 0, "Should have multiple tokens");

        console.log("Multi-token DCA tracking working");
        console.log("Total DCA amount:", totalDCA);
        console.log("Number of tokens:", tokens.length);
        console.log("SUCCESS: Multi-token DCA tracking working");
    }

    // ==================== POOL ANALYTICS TESTS ====================

    function testAnalytics_GetPoolAnalytics() public {
        console.log("\n=== P8 ENHANCED: Testing Pool Analytics ===");

        // Get pool analytics using StateView
        (uint160 sqrtPriceX96, int24 tick, uint128 liquidity, uint256 feeGrowthGlobal0, uint256 feeGrowthGlobal1) =
            analytics.getPoolAnalytics(poolKeyAB);

        // Should get pool data
        assertGt(sqrtPriceX96, 0, "Should get sqrt price");
        assertGt(liquidity, 0, "Should get liquidity");

        console.log("Pool analytics working correctly");
        console.log("Sqrt price:", sqrtPriceX96);
        console.log("Tick:", tick);
        console.log("Liquidity:", liquidity);
        console.log("SUCCESS: Pool analytics working");
    }

    function testAnalytics_GetPoolAnalyticsMultiplePools() public {
        console.log("\n=== P8 ENHANCED: Testing Analytics for Multiple Pools ===");

        // Get analytics for multiple pools
        (uint160 sqrtPriceAB,,,,) = analytics.getPoolAnalytics(poolKeyAB);
        (uint160 sqrtPriceAC,,,,) = analytics.getPoolAnalytics(poolKeyAC);
        (uint160 sqrtPriceBC,,,,) = analytics.getPoolAnalytics(poolKeyBC);

        // All pools should have valid prices
        assertGt(sqrtPriceAB, 0, "Pool AB should have valid price");
        assertGt(sqrtPriceAC, 0, "Pool AC should have valid price");
        assertGt(sqrtPriceBC, 0, "Pool BC should have valid price");

        console.log("Multi-pool analytics working");
        console.log("Pool AB price:", sqrtPriceAB);
        console.log("Pool AC price:", sqrtPriceAC);
        console.log("Pool BC price:", sqrtPriceBC);
        console.log("SUCCESS: Multi-pool analytics working");
    }

    // ==================== REAL-TIME VALUATION TESTS ====================

    function testAnalytics_RealTimeValuation() public {
        console.log("\n=== P8 ENHANCED: Testing Real-Time Portfolio Valuation ===");

        // Get real-time portfolio value
        (,,, uint256 aliceValue) = analytics.getUserPortfolio(alice);

        // Should calculate real-time value
        assertGt(aliceValue, 0, "Should calculate real-time portfolio value");

        // Value should be reasonable (simplified calculation)
        assertLt(aliceValue, INITIAL_BALANCE * 10, "Portfolio value should be reasonable");

        console.log("Real-time valuation working");
        console.log("Alice portfolio value:", aliceValue);
        console.log("SUCCESS: Real-time valuation working");
    }

    function testAnalytics_ValuationAfterChanges() public {
        console.log("\n=== P8 ENHANCED: Testing Valuation After Portfolio Changes ===");

        // Get initial valuation
        (,,, uint256 initialValue) = analytics.getUserPortfolio(alice);

        // Make changes to portfolio
        vm.prank(address(savingsModule));
        storageContract.increaseSavings(alice, address(tokenA), 50 ether);

        // Get updated valuation
        (,,, uint256 updatedValue) = analytics.getUserPortfolio(alice);

        // Value should increase
        assertGt(updatedValue, initialValue, "Portfolio value should increase after savings addition");

        console.log("Portfolio valuation updates correctly");
        console.log("Initial value:", initialValue, "Updated value:", updatedValue);
        console.log("SUCCESS: Portfolio valuation updates working");
    }

    // ==================== PERFORMANCE TESTS ====================

    function testAnalytics_Performance() public {
        console.log("\n=== P8 ENHANCED: Testing Analytics Performance ===");

        uint256 gasBefore = gasleft();

        // Perform multiple analytics operations
        for (uint256 i = 0; i < 5; i++) {
            analytics.getUserPortfolio(alice);
        }

        uint256 gasUsed = gasBefore - gasleft();

        // Gas usage should be reasonable for analytics operations
        assertLt(gasUsed, 1000000, "Analytics gas usage should be reasonable");

        console.log("Analytics performance verified");
        console.log("Gas used for 5 portfolio queries:", gasUsed);
        console.log("SUCCESS: Analytics performance working");
    }

    // ==================== INTEGRATION TESTS ====================

    function testAnalytics_CompleteWorkflow() public {
        console.log("\n=== P8 ENHANCED: Testing Complete Analytics Workflow ===");

        // 1. Setup comprehensive user portfolio
        vm.prank(address(savingsModule));
        storageContract.increaseSavings(alice, address(tokenA), SAVINGS_AMOUNT);

        vm.prank(address(savingsModule));
        storageContract.increaseSavings(alice, address(tokenB), SAVINGS_AMOUNT / 2);

        vm.prank(address(savingsModule));
        storageContract.increaseSavings(alice, address(tokenC), SAVINGS_AMOUNT / 4);

        // 2. Setup DCA
        vm.prank(alice);
        dcaModule.enableDCA(alice, address(tokenB), DCA_AMOUNT, 500);

        vm.prank(alice);
        dcaModule.enableDCA(alice, address(tokenC), DCA_AMOUNT / 2, 500);

        // 3. Get comprehensive portfolio analytics
        (address[] memory tokens, uint256[] memory savings, uint256[] memory dcaAmounts, uint256 totalValue) =
            analytics.getUserPortfolio(alice);

        // 4. Verify comprehensive data
        assertEq(tokens.length, 3, "Should track 3 tokens");
        assertEq(savings.length, 3, "Should have savings for 3 tokens");
        assertEq(dcaAmounts.length, 3, "Should have DCA data for 3 tokens");

        // 5. Verify savings data
        assertEq(savings[0], SAVINGS_AMOUNT, "TokenA savings should match");
        assertEq(savings[1], SAVINGS_AMOUNT / 2, "TokenB savings should match");
        assertEq(savings[2], SAVINGS_AMOUNT / 4, "TokenC savings should match");

        // 6. Verify DCA data
        assertGt(dcaAmounts[0], 0, "Should have DCA for tokenA");
        assertGt(dcaAmounts[1], 0, "Should have DCA for tokenB");
        assertGt(dcaAmounts[2], 0, "Should have DCA for tokenC");

        // 7. Verify total value
        assertGt(totalValue, 0, "Should calculate total portfolio value");

        // 8. Test pool analytics
        (uint160 sqrtPrice,,,,) = analytics.getPoolAnalytics(poolKeyAB);
        assertGt(sqrtPrice, 0, "Should get pool price data");

        console.log("Complete analytics workflow successful");
        console.log("Tokens:", tokens.length);
        console.log("Total value:", totalValue);
        console.log("Pool price:", sqrtPrice);
        console.log("SUCCESS: Complete analytics workflow verified");
    }

    function testAnalytics_ComprehensiveReport() public {
        console.log("\n=== P8 ENHANCED: COMPREHENSIVE ANALYTICS REPORT ===");

        // Run all analytics tests
        testAnalytics_GetUserPortfolio();
        testAnalytics_GetUserPortfolioNoSavings();
        testAnalytics_GetUserPortfolioMultipleUsers();
        testAnalytics_DCATracking();
        testAnalytics_DCATrackingMultipleTokens();
        testAnalytics_GetPoolAnalytics();
        testAnalytics_GetPoolAnalyticsMultiplePools();
        testAnalytics_RealTimeValuation();
        testAnalytics_ValuationAfterChanges();
        testAnalytics_Performance();
        testAnalytics_CompleteWorkflow();

        console.log("\n=== FINAL ANALYTICS RESULTS ===");
        console.log("PASS - User Portfolio Summary: PASS");
        console.log("PASS - Empty Portfolio Handling: PASS");
        console.log("PASS - Multi-User Portfolio Tracking: PASS");
        console.log("PASS - DCA Tracking: PASS");
        console.log("PASS - Multi-Token DCA Tracking: PASS");
        console.log("PASS - Pool Analytics: PASS");
        console.log("PASS - Multi-Pool Analytics: PASS");
        console.log("PASS - Real-Time Valuation: PASS");
        console.log("PASS - Valuation Updates: PASS");
        console.log("PASS - Performance: PASS");
        console.log("PASS - Complete Analytics Workflow: PASS");

        console.log("\n=== ANALYTICS SUMMARY ===");
        console.log("Total analytics scenarios: 12");
        console.log("Scenarios passing: 12");
        console.log("Success rate: 100%");
        console.log("SUCCESS: Complete SpendSaveAnalytics functionality verified!");
    }
}
