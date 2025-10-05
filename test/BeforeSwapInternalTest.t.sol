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
import {SwapParams} from "lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "lib/v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";

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
 * @title P1 CRITICAL: Hook _beforeSwapInternal Tests
 * @notice Focused testing of the most critical Hook functionality
 */
contract BeforeSwapInternalTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    
    // Core contracts
    SpendSaveHook public hook;
    SpendSaveStorage public storageContract;
    
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
    
    // Pool configuration
    PoolKey public poolKey;
    
    function setUp() public {
        // Create test accounts
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        
        // Deploy V4 infrastructure
        deployFreshManagerAndRouters();
        
        // Deploy tokens
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        
        // Ensure proper token ordering for V4
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        
        // Deploy core protocol
        _deployProtocol();
        
        // Initialize pool
        _initializePool();
        
        // Setup test accounts
        _setupTestAccounts();
        
        console.log("=== P1 CRITICAL: _beforeSwapInternal TESTS SETUP COMPLETE ===");
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
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        
        (address hookAddress, bytes32 salt) = HookMiner.find(
            owner,
            flags,
            type(SpendSaveHook).creationCode,
            abi.encode(IPoolManager(address(manager)), storageContract)
        );
        
        vm.prank(owner);
        hook = new SpendSaveHook{salt: salt}(
            IPoolManager(address(manager)), 
            storageContract
        );
        
        require(address(hook) == hookAddress, "Hook deployed at wrong address");
        
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
        
        // Initialize modules with storage reference (owner only can do this)
        vm.startPrank(owner);
        savingsModule.initialize(storageContract);
        strategyModule.initialize(storageContract);
        tokenModule.initialize(storageContract);
        dcaModule.initialize(storageContract);
        dailySavingsModule.initialize(storageContract);
        slippageModule.initialize(storageContract);
        
        // Set cross-module references (owner only can do this)
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
        
        // The hook will be able to detect modules are initialized via storage registry
        
        console.log("Core protocol deployed and initialized");
    }
    
    function _initializePool() internal {
        // Create pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        
        // Initialize pool
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        
        console.log("Initialized pool with SpendSave hook");
    }
    
    function _setupTestAccounts() internal {
        // Setup Alice with 10% INPUT savings using correct function signature
        vm.startPrank(alice);
        strategyModule.setSavingStrategy(
            alice,   // user
            1000,    // percentage: 10%
            0,       // autoIncrement
            0,       // maxPercentage
            false,   // roundUpSavings
            SpendSaveStorage.SavingsTokenType.INPUT, // savingsTokenType
            address(tokenA) // specificSavingsToken
        );
        vm.stopPrank();
        
        // Setup Bob with 5% OUTPUT savings and DCA using correct function signature
        vm.startPrank(bob);
        strategyModule.setSavingStrategy(
            bob,     // user
            500,     // percentage: 5%
            0,       // autoIncrement
            0,       // maxPercentage
            true,    // roundUpSavings
            SpendSaveStorage.SavingsTokenType.OUTPUT, // savingsTokenType
            address(0) // specificSavingsToken
        );
        
        // Enable DCA for Bob
        dcaModule.enableDCA(
            bob,                // user
            address(tokenB),    // targetToken (swap to tokenB)
            0.01 ether,        // minAmount
            500                // maxSlippage (5%)
        );
        vm.stopPrank();
        
        console.log("Test accounts configured");
    }
    
    // ==================== P1 CRITICAL: _beforeSwapInternal TESTS ====================
    
    function testBeforeSwapInternal_BasicFunctionality() public {
        console.log("\n=== P1 CRITICAL: Testing _beforeSwapInternal Basic Functionality ===");
        
        // Test data for Alice (10% INPUT savings)
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
            poolKey,
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
        
        // Verify delta calculation for INPUT savings (Alice has 10% INPUT savings)
        // For 1 ether input with 10% savings, should take 0.1 ether from user
        int128 specifiedDelta = BeforeSwapDeltaLibrary.getSpecifiedDelta(delta);
        assertTrue(specifiedDelta != 0, "Should modify delta for INPUT savings");
        assertTrue(selector == IHooks.beforeSwap.selector, "Should execute _beforeSwapInternal successfully");
        
        // Verify user's packed config was read (by checking it exists)
        (uint256 percentage, bool roundUpSavings, uint8 savingsTokenType, bool enableDCA) = 
            storageContract.getPackedUserConfig(alice);
        assertEq(percentage, 1000, "Should have correct percentage in storage");
        assertEq(uint8(savingsTokenType), uint8(SpendSaveStorage.SavingsTokenType.INPUT), "Should have INPUT savings type");
        assertFalse(enableDCA, "Should have DCA disabled for Alice");
        
        console.log("SUCCESS: Basic functionality working");
        console.log("SUCCESS: Gas used:", gasUsed);
        console.log("SUCCESS: Function executed without errors");
        console.log("SUCCESS: User config verified in storage");
    }
    
    function testBeforeSwapInternal_NoSavingsStrategy() public {
        console.log("\n=== P1 CRITICAL: Testing _beforeSwapInternal Fast Path (No Savings) ===");
        
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
            poolKey,
            params,
            hookData
        );
        
        uint256 gasUsed = gasBefore - gasleft();
        
        // Verify fast path execution
        assertEq(selector, IHooks.beforeSwap.selector, "Should return correct selector");
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), 0, "Should return zero delta for no savings");
        assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta), 0, "Should return zero unspecified delta");
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
        console.log("\n=== P1 CRITICAL: Testing _beforeSwapInternal OUTPUT Savings Type ===");
        
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
            poolKey,
            params,
            hookData
        );
        
        // For OUTPUT savings, beforeSwap should not modify delta
        // The savings will be processed in afterSwap
        assertEq(selector, IHooks.beforeSwap.selector, "Should return correct selector");
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), 0, "Should return zero specified delta for OUTPUT savings");
        assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta), 0, "Should return zero unspecified delta for OUTPUT savings");
        assertEq(fee, 0, "Should not modify fee");
        
        // Verify transient storage was still set for afterSwap processing
        SpendSaveStorage.SwapContext memory context = storageContract.getSwapContext(user);
        assertEq(context.currentPercentage, 500, "Should set correct percentage (5%)");
        assertTrue(context.hasStrategy, "Should mark strategy as active");
        assertEq(uint8(context.savingsTokenType), uint8(SpendSaveStorage.SavingsTokenType.OUTPUT), "Should set OUTPUT savings type");
        assertTrue(context.enableDCA, "Should enable DCA as configured");
        
        console.log("SUCCESS: OUTPUT savings type handled correctly");
        console.log("SUCCESS: No delta modification in beforeSwap for OUTPUT savings");
        console.log("SUCCESS: Transient storage prepared for afterSwap");
    }
    
    function testBeforeSwapInternal_GasOptimization() public {
        console.log("\n=== P1 CRITICAL: Testing _beforeSwapInternal Gas Optimization ===");
        
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        
        // Measure gas for different scenarios
        uint256[] memory gasUsed = new uint256[](3);
        
        // Test 1: User with savings strategy (Alice)
        uint256 gasBefore = gasleft();
        vm.prank(address(hook));
        hook._beforeSwapInternal(alice, poolKey, params, abi.encode(alice));
        gasUsed[0] = gasBefore - gasleft();
        
        // Test 2: User with no savings (fast path) (Charlie)
        gasBefore = gasleft();
        vm.prank(address(hook));
        hook._beforeSwapInternal(charlie, poolKey, params, abi.encode(charlie));
        gasUsed[1] = gasBefore - gasleft();
        
        // Test 3: Complex user config with DCA enabled (Bob)
        gasBefore = gasleft();
        vm.prank(address(hook));
        hook._beforeSwapInternal(bob, poolKey, params, abi.encode(bob));
        gasUsed[2] = gasBefore - gasleft();
        
        console.log("Gas usage analysis:");
        console.log("- With savings strategy:", gasUsed[0]);
        console.log("- No savings (fast path):", gasUsed[1]);
        console.log("- Complex config (DCA):", gasUsed[2]);
        
        // Verify gas optimization targets
        assertTrue(gasUsed[1] < gasUsed[0], "Fast path should use less gas");
        assertTrue(gasUsed[0] < 30000, "Should be gas efficient for beforeSwap");
        assertTrue(gasUsed[2] < 35000, "Should be gas efficient even with complex config");
        
        console.log("SUCCESS: Gas optimization targets met");
        console.log("SUCCESS: Fast path optimization working");
        console.log("SUCCESS: All scenarios under gas limits");
    }
    
    function testBeforeSwapInternal_TransientStorageIntegrity() public {
        console.log("\n=== P1 CRITICAL: Testing Transient Storage (EIP-1153) Integrity ===");
        
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        
        // Verify clean state initially
        SpendSaveStorage.SwapContext memory initialContext = storageContract.getSwapContext(alice);
        assertEq(initialContext.pendingSaveAmount, 0, "Should start with clean transient storage");
        assertFalse(initialContext.hasStrategy, "Should start with no strategy flag");
        
        // Execute beforeSwapInternal for Alice
        vm.prank(address(hook));
        hook._beforeSwapInternal(alice, poolKey, params, abi.encode(alice));
        
        // Verify transient storage was set correctly
        SpendSaveStorage.SwapContext memory aliceContext = storageContract.getSwapContext(alice);
        assertEq(aliceContext.pendingSaveAmount, 0.1 ether, "Should set save amount");
        assertEq(aliceContext.currentPercentage, 1000, "Should set percentage");
        assertTrue(aliceContext.hasStrategy, "Should set strategy flag");
        assertEq(uint8(aliceContext.savingsTokenType), uint8(SpendSaveStorage.SavingsTokenType.INPUT), "Should set savings type");
        assertFalse(aliceContext.roundUpSavings, "Should set round-up flag");
        assertFalse(aliceContext.enableDCA, "Should set DCA flag");
        
        // Test multiple users don't interfere (execute for Bob)
        vm.prank(address(hook));
        hook._beforeSwapInternal(bob, poolKey, params, abi.encode(bob));
        
        // Alice's context should be unchanged
        SpendSaveStorage.SwapContext memory aliceContextAfter = storageContract.getSwapContext(alice);
        assertEq(aliceContextAfter.pendingSaveAmount, 0.1 ether, "Alice's context should be preserved");
        
        // Bob should have his own context
        SpendSaveStorage.SwapContext memory bobContext = storageContract.getSwapContext(bob);
        assertEq(bobContext.currentPercentage, 500, "Bob should have 5% percentage");
        assertEq(uint8(bobContext.savingsTokenType), uint8(SpendSaveStorage.SavingsTokenType.OUTPUT), "Bob should have OUTPUT type");
        
        console.log("SUCCESS: Transient storage set correctly");
        console.log("SUCCESS: Multiple users isolated properly");
        console.log("SUCCESS: EIP-1153 transient storage working");
    }
    
    function testBeforeSwapInternal_EdgeCases() public {
        console.log("\n=== P1 CRITICAL: Testing _beforeSwapInternal Edge Cases ===");
        
        // Test 1: Zero amount swap
        SwapParams memory zeroParams = SwapParams({
            zeroForOne: true,
            amountSpecified: 0,
            sqrtPriceLimitX96: 0
        });
        
        vm.prank(address(hook));
        (bytes4 selector1, BeforeSwapDelta delta1, uint24 fee1) = hook._beforeSwapInternal(
            alice,
            poolKey,
            zeroParams,
            abi.encode(alice)
        );
        
        assertEq(selector1, IHooks.beforeSwap.selector, "Should handle zero amount");
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta1), 0, "Should return zero specified delta for zero amount");
        assertEq(BeforeSwapDeltaLibrary.getUnspecifiedDelta(delta1), 0, "Should return zero unspecified delta for zero amount");
        
        // Test 2: Maximum percentage (100%)
        vm.startPrank(alice);
        strategyModule.setSavingStrategy(
            alice,   // user
            10000,   // 100% savings
            0,       // autoIncrement
            0,       // maxPercentage
            false,   // roundUpSavings
            SpendSaveStorage.SavingsTokenType.INPUT, // savingsTokenType
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
            poolKey,
            maxParams,
            abi.encode(alice)
        );
        
        // With 100% savings, should take the entire input amount as specified delta
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta2), -1 ether, "Should take full amount for 100% savings");
        
        console.log("SUCCESS: Zero amount swap handled");
        console.log("SUCCESS: Maximum percentage (100%) handled");
        console.log("SUCCESS: Edge cases pass validation");
    }
    
    function testBeforeSwapInternal_UserExtractionFromHookData() public {
        console.log("\n=== P1 CRITICAL: Testing User Extraction from HookData ===");
        
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
            poolKey,
            params,
            hookData   // Contains actual user
        );
        
        // Should use Alice's savings strategy (10% INPUT savings)
        SpendSaveStorage.SwapContext memory context = storageContract.getSwapContext(actualUser);
        assertEq(context.currentPercentage, 1000, "Should use actual user's strategy (10%)");
        assertTrue(context.hasStrategy, "Should have actual user's strategy");
        
        // Delta should be calculated based on Alice's strategy, not sender's
        assertEq(BeforeSwapDeltaLibrary.getSpecifiedDelta(delta), -0.1 ether, "Should calculate delta using actual user's strategy");
        
        console.log("SUCCESS: User extraction from hookData working correctly");
        console.log("SUCCESS: Used actual user's strategy, not sender's");
        console.log("SUCCESS: Security boundary properly maintained");
    }
}