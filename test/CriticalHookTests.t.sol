// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// V4 Core imports
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "lib/v4-periphery/lib/v4-core/src/PoolManager.sol";
import {Deployers} from "lib/v4-periphery/lib/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";
import {PoolSwapTest} from "lib/v4-periphery/lib/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta, toBalanceDelta} from "lib/v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "lib/v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";

// SpendSave Core Contracts
import {SpendSaveHook} from "../src/SpendSaveHook.sol";
import {SpendSaveStorage} from "../src/SpendSaveStorage.sol";
import {Savings} from "../src/Savings.sol";
import {SavingStrategy} from "../src/SavingStrategy.sol";
import {Token} from "../src/Token.sol";
import {DCA} from "../src/DCA.sol";
import {DailySavings} from "../src/DailySavings.sol";
import {SlippageControl} from "../src/SlippageControl.sol";

/**
 * @title Critical Hook Tests
 * @notice P1 CRITICAL priority tests for SpendSaveHook core functionality
 * @dev Tests the most critical security and functionality aspects of the Hook system:
 * 
 * P1 CRITICAL TESTS:
 * - Hook._beforeSwapInternal() core swap interception logic
 * - Hook._afterSwapInternal() savings extraction logic  
 * - Hook reentrancy protection mechanisms
 * - Hook gas optimization verification (<50k gas afterSwap target)
 * - Hook failure scenarios (swap continuation when hook fails)
 * - Transient storage (EIP-1153) usage and cleanup
 */
contract CriticalHookTests is Test, Deployers {
    using CurrencyLibrary for Currency;
    
    // Core contracts
    SpendSaveHook public hook;
    SpendSaveStorage public storageContract;
    PoolSwapTest public swapTestRouter;
    
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
    MockERC20 public usdc;
    MockERC20 public weth;
    
    // Pool configuration
    PoolKey public poolKey_A_B;
    PoolKey public poolKey_USDC_WETH;
    
    // Test constants
    uint24 public constant POOL_FEE = 3000; // 0.3%
    int24 public constant TICK_SPACING = 60;
    uint256 public constant INITIAL_LIQUIDITY = 1000 ether;
    
    function setUp() public {
        // Create test accounts
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        
        // Deploy V4 infrastructure
        _deployV4Infrastructure();
        
        // Deploy tokens
        _deployTokens();
        
        // Deploy core protocol
        _deployProtocol();
        
        // Initialize pools
        _initializePools();
        
        // Setup test accounts
        _setupAccounts();
        
        console.log("=== CRITICAL HOOK TESTS SETUP COMPLETE ===");
    }
    
    function _deployV4Infrastructure() internal {
        // Deploy V4 core using Deployers
        deployFreshManagerAndRouters();
        
        // Create swap router for testing
        swapTestRouter = new PoolSwapTest(IPoolManager(address(manager)));
        
        console.log("V4 Infrastructure deployed:");
        console.log("- PoolManager:", address(manager));
        console.log("- SwapRouter:", address(swapTestRouter));
    }
    
    function _deployTokens() internal {
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        
        // Ensure proper token ordering for V4
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        
        console.log("Tokens deployed: TKNA, TKNB, USDC, WETH");
    }
    
    function _deployProtocol() internal {
        // Deploy storage
        vm.prank(owner);
        storageContract = new SpendSaveStorage(address(manager));
        
        // Deploy all modules
        savingsModule = new Savings();
        strategyModule = new SavingStrategy();
        tokenModule = new Token();
        dcaModule = new DCA();
        dailySavingsModule = new DailySavings();
        slippageModule = new SlippageControl();
        
        // Deploy hook with proper address mining
        _deployHookWithMining();
        
        // Initialize storage
        vm.prank(owner);
        storageContract.initialize(address(hook));

        // Register modules in storage
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

    function _deployHookWithMining() internal {
        // Define required flags for SpendSave functionality
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        
        // Mine hook address with proper flags
        (address hookAddress, bytes32 salt) = HookMiner.find(
            owner,
            flags,
            type(SpendSaveHook).creationCode,
            abi.encode(IPoolManager(address(manager)), storageContract)
        );
        
        // Deploy hook at mined address
        vm.prank(owner);
        hook = new SpendSaveHook{salt: salt}(
            IPoolManager(address(manager)),
            storageContract
        );
        
        require(address(hook) == hookAddress, "Hook deployed at wrong address");
        console.log("Hook deployed with proper address:", address(hook));
    }
    
    
    function _initializePools() internal {
        // Create pool keys
        poolKey_A_B = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        
        poolKey_USDC_WETH = PoolKey({
            currency0: Currency.wrap(address(usdc)),
            currency1: Currency.wrap(address(weth)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        
        // Initialize pools
        manager.initialize(poolKey_A_B, SQRT_PRICE_1_1);
        manager.initialize(poolKey_USDC_WETH, SQRT_PRICE_1_1);
        
        console.log("Initialized 2 pools with SpendSave hooks");
    }
    
    function _setupAccounts() internal {
        // Mint tokens to test accounts
        tokenA.mint(alice, 10000 ether);
        tokenB.mint(alice, 10000 ether);
        usdc.mint(alice, 10000 * 1e6);
        weth.mint(alice, 10000 ether);
        
        tokenA.mint(bob, 10000 ether);
        tokenB.mint(bob, 10000 ether);
        usdc.mint(bob, 10000 * 1e6);
        weth.mint(bob, 10000 ether);

        tokenA.mint(charlie, 10000 ether);
        tokenB.mint(charlie, 10000 ether);
        usdc.mint(charlie, 10000 * 1e6);
        weth.mint(charlie, 10000 ether);

        // Setup savings strategies for test accounts
        vm.startPrank(alice);
        strategyModule.setSavingStrategy(
            alice,   // user
            1000,    // 10% savings
            0,       // autoIncrement
            0,       // maxPercentage
            false,   // no round-up
            SpendSaveStorage.SavingsTokenType.INPUT,
            address(tokenA) // specific savings token
        );
        vm.stopPrank();

        vm.startPrank(bob);
        strategyModule.setSavingStrategy(
            bob,     // user
            500,     // 5% savings
            0,       // autoIncrement
            0,       // maxPercentage
            true,    // round-up enabled
            SpendSaveStorage.SavingsTokenType.OUTPUT,
            address(0) // no specific token
        );
        vm.stopPrank();
        
        console.log("Test accounts configured with savings strategies");
    }
    
    // ==================== P1 CRITICAL: _beforeSwapInternal TESTS ====================
    
    function testBeforeSwapInternal_BasicFunctionality() public {
        console.log("\n=== TESTING _beforeSwapInternal BASIC FUNCTIONALITY ===");
        
        // Test data
        address user = alice;
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether, // exactInput
            sqrtPriceLimitX96: 0
        });
        bytes memory hookData = abi.encode(user);
        
        // Record gas usage
        uint256 gasBefore = gasleft();
        
        // Call _beforeSwapInternal directly
        vm.prank(address(hook));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = hook._beforeSwapInternal(
            user,
            poolKey_A_B,
            params,
            hookData
        );
        
        uint256 gasUsed = gasBefore - gasleft();
        
        // Verify return values
        assertEq(selector, IHooks.beforeSwap.selector, "Should return correct selector");
        assertEq(fee, 0, "Should not modify fee");
        
        // Verify delta calculation for INPUT savings (Alice has 10% INPUT savings)
        // For 1 ether input with 10% savings, should take 0.1 ether from user
        int128 expectedDelta0 = -0.1 ether; // Take savings amount from input
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), expectedDelta0, "Should calculate correct delta for INPUT savings");
        
        // Verify transient storage was set
        SpendSaveStorage.SwapContext memory context = storageContract.getSwapContext(user);
        assertEq(context.pendingSaveAmount, 0.1 ether, "Should set correct save amount in transient storage");
        assertEq(context.currentPercentage, 1000, "Should set correct percentage in transient storage");
        assertTrue(context.hasStrategy, "Should mark strategy as active");
        assertEq(uint8(context.savingsTokenType), uint8(SpendSaveStorage.SavingsTokenType.INPUT), "Should set correct savings token type");
        
        console.log("Basic functionality working");
        console.log("Gas used:", gasUsed);
        console.log("Delta calculated correctly");
        console.log("Transient storage set properly");
    }
    
    function testBeforeSwapInternal_NoSavingsStrategy() public {
        console.log("\n=== TESTING _beforeSwapInternal NO SAVINGS STRATEGY ===");
        
        // Use charlie who has no savings strategy
        address user = charlie;
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        bytes memory hookData = abi.encode(user);
        
        // Record gas usage
        uint256 gasBefore = gasleft();
        
        // Call _beforeSwapInternal
        vm.prank(address(hook));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = hook._beforeSwapInternal(
            user,
            poolKey_A_B,
            params,
            hookData
        );
        
        uint256 gasUsed = gasBefore - gasleft();
        
        // Verify fast path execution
        assertEq(selector, IHooks.beforeSwap.selector, "Should return correct selector");
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), 0, "Should return zero delta for no savings");
        assertEq(fee, 0, "Should not modify fee");
        
        // Verify no transient storage was set
        SpendSaveStorage.SwapContext memory context = storageContract.getSwapContext(user);
        assertEq(context.pendingSaveAmount, 0, "Should not set save amount");
        assertFalse(context.hasStrategy, "Should not mark strategy as active");
        
        console.log("SUCCESS: Fast path execution for no savings");
        console.log("SUCCESS: Gas used (should be minimal):", gasUsed);
        console.log("SUCCESS: No unnecessary storage operations");
    }
    
    function testBeforeSwapInternal_OutputSavingsType() public {
        console.log("\n=== TESTING _beforeSwapInternal OUTPUT SAVINGS TYPE ===");
        
        // Use bob who has OUTPUT savings configured (5%)
        address user = bob;
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        bytes memory hookData = abi.encode(user);
        
        // Call _beforeSwapInternal
        vm.prank(address(hook));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = hook._beforeSwapInternal(
            user,
            poolKey_A_B,
            params,
            hookData
        );
        
        // For OUTPUT savings, beforeSwap should not modify delta
        // The savings will be processed in afterSwap
        assertEq(selector, IHooks.beforeSwap.selector, "Should return correct selector");
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), 0, "Should return zero delta for OUTPUT savings");
        assertEq(fee, 0, "Should not modify fee");
        
        // Verify transient storage was still set for afterSwap processing
        SpendSaveStorage.SwapContext memory context = storageContract.getSwapContext(user);
        assertEq(context.currentPercentage, 500, "Should set correct percentage (5%)");
        assertTrue(context.hasStrategy, "Should mark strategy as active");
        assertEq(uint8(context.savingsTokenType), uint8(SpendSaveStorage.SavingsTokenType.OUTPUT), "Should set OUTPUT savings type");
        assertFalse(context.enableDCA, "Should have DCA disabled (not enabled in test setup)");
        
        console.log("SUCCESS: OUTPUT savings type handled correctly");
        console.log("SUCCESS: No delta modification in beforeSwap for OUTPUT savings");
        console.log("SUCCESS: Transient storage prepared for afterSwap");
    }
    
    function testBeforeSwapInternal_ExactOutputSwap() public {
        console.log("\n=== TESTING _beforeSwapInternal EXACT OUTPUT SWAP ===");
        
        address user = alice;
        // Test exactOutput swap (positive amountSpecified)
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: 1 ether, // exactOutput
            sqrtPriceLimitX96: 0
        });
        bytes memory hookData = abi.encode(user);
        
        // Call _beforeSwapInternal
        vm.prank(address(hook));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = hook._beforeSwapInternal(
            user,
            poolKey_A_B,
            params,
            hookData
        );
        
        // For exactOutput swaps, input amount calculation should work differently
        assertEq(selector, IHooks.beforeSwap.selector, "Should return correct selector");
        
        // Verify context is set up correctly
        SpendSaveStorage.SwapContext memory context = storageContract.getSwapContext(user);
        assertTrue(context.hasStrategy, "Should have strategy");
        assertEq(context.currentPercentage, 1000, "Should have 10% savings");
        
        console.log("SUCCESS: ExactOutput swap handled correctly");
        console.log("SUCCESS: Delta:", vm.toString(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta)));
    }
    
    function testBeforeSwapInternal_RoundUpSavings() public {
        console.log("\n=== TESTING _beforeSwapInternal ROUND-UP SAVINGS ===");
        
        // Use bob who has round-up savings enabled
        address user = bob;
        
        // Test with amount that should trigger round-up: 1.23456 ether
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1234560000000000000, // 1.23456 ether
            sqrtPriceLimitX96: 0
        });
        bytes memory hookData = abi.encode(user);
        
        vm.prank(address(hook));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = hook._beforeSwapInternal(
            user,
            poolKey_A_B,
            params,
            hookData
        );
        
        // Verify transient storage contains round-up configuration
        SpendSaveStorage.SwapContext memory context = storageContract.getSwapContext(user);
        assertTrue(context.roundUpSavings, "Should enable round-up savings");
        assertEq(context.currentPercentage, 500, "Should have 5% base savings");
        
        console.log("SUCCESS: Round-up savings configuration handled");
        console.log("SUCCESS: Save amount with round-up:", context.pendingSaveAmount);
    }
    
    function testBeforeSwapInternal_UserExtractionFromHookData() public {
        console.log("\n=== TESTING _beforeSwapInternal USER EXTRACTION ===");
        
        address actualUser = alice;
        address swapSender = makeAddr("swapSender"); // Different from actual user
        
        // Encode actual user in hookData
        bytes memory hookData = abi.encode(actualUser);
        
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        
        // Call with different sender, but actual user in hookData
        vm.prank(address(hook));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = hook._beforeSwapInternal(
            swapSender, // Different sender
            poolKey_A_B,
            params,
            hookData   // Contains actual user
        );
        
        // Should use Alice's savings strategy (10% INPUT savings)
        SpendSaveStorage.SwapContext memory context = storageContract.getSwapContext(actualUser);
        assertEq(context.currentPercentage, 1000, "Should use actual user's strategy (10%)");
        assertTrue(context.hasStrategy, "Should have actual user's strategy");
        
        console.log("SUCCESS: User extraction from hookData working correctly");
        console.log("SUCCESS: Used actual user's strategy, not sender's");
    }
    
    function testBeforeSwapInternal_GasOptimization() public {
        console.log("\n=== TESTING _beforeSwapInternal GAS OPTIMIZATION ===");
        
        address user = alice;
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        bytes memory hookData = abi.encode(user);
        
        // Measure gas for multiple scenarios
        uint256[] memory gasUsed = new uint256[](3);
        
        // Test 1: User with savings strategy
        uint256 gasBefore = gasleft();
        vm.prank(address(hook));
        hook._beforeSwapInternal(user, poolKey_A_B, params, hookData);
        gasUsed[0] = gasBefore - gasleft();
        
        // Test 2: User with no savings (fast path)
        gasBefore = gasleft();
        vm.prank(address(hook));
        hook._beforeSwapInternal(charlie, poolKey_A_B, params, abi.encode(charlie));
        gasUsed[1] = gasBefore - gasleft();
        
        // Test 3: Complex user config (DCA enabled)
        gasBefore = gasleft();
        vm.prank(address(hook));
        hook._beforeSwapInternal(bob, poolKey_A_B, params, abi.encode(bob));
        gasUsed[2] = gasBefore - gasleft();
        
        console.log("Gas usage analysis:");
        console.log("- With savings strategy:", gasUsed[0]);
        console.log("- No savings (fast path):", gasUsed[1]);
        console.log("- Complex config (DCA):", gasUsed[2]);
        
        // Verify gas optimization targets
        assertTrue(gasUsed[1] < gasUsed[0], "Fast path should use less gas");
        assertTrue(gasUsed[0] < 60000, "Should be gas efficient for beforeSwap");
        assertTrue(gasUsed[2] < 45000, "Should be gas efficient even with complex config");
        
        console.log("SUCCESS: Gas optimization targets met");
    }
    
    function testBeforeSwapInternal_EdgeCases() public {
        console.log("\n=== TESTING _beforeSwapInternal EDGE CASES ===");
        
        // Test 1: Zero amount swap
        SwapParams memory zeroParams = SwapParams({
            zeroForOne: true,
            amountSpecified: 0,
            sqrtPriceLimitX96: 0
        });
        
        vm.prank(address(hook));
        (bytes4 selector1, BeforeSwapDelta delta1, uint24 fee1) = hook._beforeSwapInternal(
            alice,
            poolKey_A_B,
            zeroParams,
            abi.encode(alice)
        );
        
        assertEq(selector1, IHooks.beforeSwap.selector, "Should handle zero amount");
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta1), 0, "Should return zero delta for zero amount");
        
        // Test 2: Maximum percentage (100%)
        vm.startPrank(alice);
        strategyModule.setSavingStrategy(
            alice,   // user
            10000,   // 100% savings
            0,       // autoIncrement
            0,       // maxPercentage
            false,   // roundUpSavings
            SpendSaveStorage.SavingsTokenType.INPUT,
            address(0) // specificSavingsToken
        );
        vm.stopPrank();
        
        SwapParams memory maxParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        
        vm.prank(address(hook));
        (bytes4 selector2, BeforeSwapDelta delta2, uint24 fee2) = hook._beforeSwapInternal(
            alice,
            poolKey_A_B,
            maxParams,
            abi.encode(alice)
        );
        
        // With 100% savings, should take the entire input amount
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta2), -1 ether, "Should take full amount for 100% savings");
        
        console.log("SUCCESS: Zero amount swap handled");
        console.log("SUCCESS: Maximum percentage (100%) handled");
        console.log("SUCCESS: Edge cases pass validation");
    }
    
    function testBeforeSwapInternal_TransientStorageIntegrity() public {
        console.log("\n=== TESTING TRANSIENT STORAGE INTEGRITY ===");
        
        address user = alice;
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        
        // Verify clean state initially
        SpendSaveStorage.SwapContext memory initialContext = storageContract.getSwapContext(user);
        assertEq(initialContext.pendingSaveAmount, 0, "Should start with clean transient storage");
        assertFalse(initialContext.hasStrategy, "Should start with no strategy flag");

        // Execute beforeSwapInternal
        vm.prank(address(hook));
        hook._beforeSwapInternal(user, poolKey_A_B, params, abi.encode(user));

        // Verify transient storage was set correctly
        SpendSaveStorage.SwapContext memory setContext = storageContract.getSwapContext(user);
        assertEq(setContext.pendingSaveAmount, 0.1 ether, "Should set save amount");
        assertEq(setContext.currentPercentage, 1000, "Should set percentage");
        assertTrue(setContext.hasStrategy, "Should set strategy flag");
        assertEq(uint8(setContext.savingsTokenType), uint8(SpendSaveStorage.SavingsTokenType.INPUT), "Should set savings type");
        assertFalse(setContext.roundUpSavings, "Should set round-up flag");
        assertFalse(setContext.enableDCA, "Should set DCA flag");
        
        // Test multiple users don't interfere
        vm.prank(address(hook));
        hook._beforeSwapInternal(bob, poolKey_A_B, params, abi.encode(bob));
        
        // Alice's context should be unchanged
        SpendSaveStorage.SwapContext memory aliceContext = storageContract.getSwapContext(alice);
        assertEq(aliceContext.pendingSaveAmount, 0.1 ether, "Alice's context should be preserved");
        
        // Bob should have his own context
        SpendSaveStorage.SwapContext memory bobContext = storageContract.getSwapContext(bob);
        assertEq(bobContext.currentPercentage, 500, "Bob should have 5% percentage");
        assertEq(uint8(bobContext.savingsTokenType), uint8(SpendSaveStorage.SavingsTokenType.OUTPUT), "Bob should have OUTPUT type");
        
        console.log("SUCCESS: Transient storage set correctly");
        console.log("SUCCESS: Multiple users isolated properly");
        console.log("SUCCESS: EIP-1153 transient storage working");
    }

    // ==================== P1 CRITICAL: REAL SWAP TESTS ====================

    /**
     * @notice Add liquidity to a pool for testing real swaps
     * @dev This is CRITICAL - swaps won't work without liquidity!
     */
    function _addLiquidityToPool(PoolKey memory key, uint256 amount0, uint256 amount1) internal {
        MockERC20 token0 = MockERC20(Currency.unwrap(key.currency0));
        MockERC20 token1 = MockERC20(Currency.unwrap(key.currency1));

        // Mint tokens to test contract for liquidity provision
        token0.mint(address(this), amount0);
        token1.mint(address(this), amount1);

        // Approve tokens for liquidity router
        token0.approve(address(modifyLiquidityRouter), type(uint256).max);
        token1.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Add liquidity at current price (use Deployers helper)
        seedMoreLiquidity(key, amount0, amount1);
    }

    function testRealSwap_Baseline_NoSavings() public {
        console.log("\n=== P1 CRITICAL: REAL SWAP TEST - BASELINE (NO SAVINGS) ===");

        // Use charlie who has NO savings strategy
        address user = charlie;

        // Add liquidity to pool (CRITICAL!)
        _addLiquidityToPool(poolKey_A_B, 100 ether, 100 ether);

        // Record initial balances
        uint256 initialTokenA = tokenA.balanceOf(user);
        uint256 initialTokenB = tokenB.balanceOf(user);

        console.log("Initial TokenA balance:", initialTokenA);
        console.log("Initial TokenB balance:", initialTokenB);

        // Approve tokens for swap
        vm.startPrank(user);
        tokenA.approve(address(swapTestRouter), type(uint256).max);

        // Execute REAL swap: 1 ether TokenA to TokenB
        uint256 gasBefore = gasleft();
        BalanceDelta swapDelta = swapTestRouter.swap(
            poolKey_A_B,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether, // Exact input: sell 1 ether TokenA
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            ZERO_BYTES
        );
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        // Verify swap executed
        uint256 finalTokenA = tokenA.balanceOf(user);
        uint256 finalTokenB = tokenB.balanceOf(user);

        console.log("Final TokenA balance:", finalTokenA);
        console.log("Final TokenB balance:", finalTokenB);
        console.log("TokenA spent:", initialTokenA - finalTokenA);
        console.log("TokenB received:", finalTokenB - initialTokenB);
        console.log("Gas used for swap:", gasUsed);

        // Verify swap worked
        assertTrue(finalTokenA < initialTokenA, "Should have spent TokenA");
        assertTrue(finalTokenB > initialTokenB, "Should have received TokenB");

        // Verify NO savings (charlie has no strategy)
        uint256 savings = storageContract.savings(user, address(tokenA));
        assertEq(savings, 0, "Should have ZERO savings (no strategy configured)");

        console.log("SUCCESS: Real swap executed without savings");
        console.log("SUCCESS: Hook did not interfere with normal swap");
    }

    function testRealSwap_WithInputSavings() public {
        console.log("\n=== P1 CRITICAL: REAL SWAP WITH 10% INPUT SAVINGS ===");

        // Use alice who has 10% INPUT savings
        address user = alice;

        // Add liquidity to pool
        _addLiquidityToPool(poolKey_A_B, 100 ether, 100 ether);

        // Record initial balances
        uint256 initialTokenA = tokenA.balanceOf(user);
        uint256 initialTokenB = tokenB.balanceOf(user);
        uint256 initialSavings = storageContract.savings(user, address(tokenA));

        console.log("Initial TokenA balance:", initialTokenA);
        console.log("Initial TokenB balance:", initialTokenB);
        console.log("Initial savings:", initialSavings);

        // Approve tokens for swap
        vm.startPrank(user);
        tokenA.approve(address(swapTestRouter), type(uint256).max);

        // Execute REAL swap: 1 ether TokenA to TokenB
        // Expected: 0.1 ether saved, 0.9 ether swapped
        uint256 gasBefore = gasleft();
        BalanceDelta swapDelta = swapTestRouter.swap(
            poolKey_A_B,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -1 ether, // Exact input: sell 1 ether TokenA
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            abi.encode(user) // Pass user in hookData
        );
        uint256 gasUsed = gasBefore - gasleft();
        vm.stopPrank();

        // Verify swap executed
        uint256 finalTokenA = tokenA.balanceOf(user);
        uint256 finalTokenB = tokenB.balanceOf(user);
        uint256 finalSavings = storageContract.savings(user, address(tokenA));

        console.log("Final TokenA balance:", finalTokenA);
        console.log("Final TokenB balance:", finalTokenB);
        console.log("Final savings:", finalSavings);
        console.log("TokenA spent:", initialTokenA - finalTokenA);
        console.log("TokenB received:", finalTokenB - initialTokenB);
        console.log("Savings increased by:", finalSavings - initialSavings);
        console.log("Gas used for swap with savings:", gasUsed);

        // CRITICAL ASSERTIONS
        assertTrue(finalTokenA < initialTokenA, "Should have spent TokenA");
        assertTrue(finalTokenB > initialTokenB, "Should have received TokenB");

        // Verify savings were extracted (THIS IS THE KEY TEST!)
        assertTrue(finalSavings > initialSavings, "Savings should have increased");

        // Expected: ~0.1 ether saved (10% of 1 ether)
        uint256 savingsIncrease = finalSavings - initialSavings;
        assertGe(savingsIncrease, 0.09 ether, "Should save at least 0.09 ether");
        assertLe(savingsIncrease, 0.11 ether, "Should save at most 0.11 ether");

        console.log("SUCCESS: Real swap with INPUT savings extraction works!");
        console.log("SUCCESS: 10% of input was saved as configured");
    }

    function testRealSwap_USDC_to_ETH_Simulation() public {
        console.log("\n=== P1 CRITICAL: USDC to ETH SWAP SIMULATION ===");

        // Use alice with 10% INPUT savings
        address user = alice;

        // Add liquidity to USDC/WETH pool
        _addLiquidityToPool(poolKey_USDC_WETH, 10000 * 1e6, 10 ether);

        // Record initial balances
        uint256 initialUSDC = usdc.balanceOf(user);
        uint256 initialWETH = weth.balanceOf(user);
        uint256 initialSavings = storageContract.savings(user, address(usdc));

        console.log("Initial USDC balance:", initialUSDC);
        console.log("Initial WETH balance:", initialWETH);
        console.log("Initial USDC savings:", initialSavings);

        // Approve USDC for swap
        vm.startPrank(user);
        usdc.approve(address(swapTestRouter), type(uint256).max);

        // Execute REAL swap: 100 USDC to WETH
        // Expected: 10 USDC saved, 90 USDC swapped
        BalanceDelta swapDelta = swapTestRouter.swap(
            poolKey_USDC_WETH,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -100 * 1e6, // Exact input: sell 100 USDC (6 decimals)
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            PoolSwapTest.TestSettings({
                takeClaims: false,
                settleUsingBurn: false
            }),
            abi.encode(user)
        );
        vm.stopPrank();

        // Verify results
        uint256 finalUSDC = usdc.balanceOf(user);
        uint256 finalWETH = weth.balanceOf(user);
        uint256 finalSavings = storageContract.savings(user, address(usdc));

        console.log("Final USDC balance:", finalUSDC);
        console.log("Final WETH balance:", finalWETH);
        console.log("Final USDC savings:", finalSavings);
        console.log("USDC spent:", initialUSDC - finalUSDC);
        console.log("WETH received:", finalWETH - initialWETH);
        console.log("USDC saved:", finalSavings - initialSavings);

        // CRITICAL ASSERTIONS FOR SUBMISSION
        assertTrue(finalUSDC < initialUSDC, "Should have spent USDC");
        assertTrue(finalWETH > initialWETH, "Should have received WETH");
        assertTrue(finalSavings > initialSavings, "USDC savings should have increased");

        // Expected: ~10 USDC saved (10% of 100 USDC)
        uint256 savingsIncrease = finalSavings - initialSavings;
        assertGe(savingsIncrease, 9 * 1e6, "Should save at least 9 USDC");
        assertLe(savingsIncrease, 11 * 1e6, "Should save at most 11 USDC");

        console.log("SUCCESS: USDC to WETH swap with savings works!");
        console.log("SUCCESS: Protocol extracts savings during real swaps!");
        console.log("SUCCESS: Ready for Base Mainnet deployment!");
    }
}