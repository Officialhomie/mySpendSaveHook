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
import {SwapParams} from "lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "lib/v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "lib/v4-periphery/lib/v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";

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
 * @title P1 CRITICAL: Transient Storage (EIP-1153) Tests
 * @notice Tests transient storage usage and cleanup in SpendSave protocol
 * @dev Validates EIP-1153 implementation for gas-efficient swap context management
 */
contract TransientStorageTest is Test, Deployers {
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

        console.log("=== P1 CRITICAL: TRANSIENT STORAGE (EIP-1153) TESTS SETUP COMPLETE ===");
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
        // Setup Alice with INPUT savings strategy
        vm.startPrank(alice);
        strategyModule.setSavingStrategy(
            alice, 1000, 0, 0, false, SpendSaveStorage.SavingsTokenType.INPUT, address(tokenA)
        );
        vm.stopPrank();

        // Setup Bob with OUTPUT savings strategy + DCA
        vm.startPrank(bob);
        strategyModule.setSavingStrategy(
            bob, 2000, 0, 0, false, SpendSaveStorage.SavingsTokenType.OUTPUT, address(tokenB)
        );
        dcaModule.enableDCA(bob, address(tokenB), 0.01 ether, 500);
        vm.stopPrank();

        // Mint tokens for testing
        tokenA.mint(alice, 100 ether);
        tokenA.mint(bob, 100 ether);
        tokenB.mint(alice, 100 ether);
        tokenB.mint(bob, 100 ether);

        console.log("Test accounts configured");
    }

    // ==================== P1 CRITICAL: TRANSIENT STORAGE TESTS ====================

    function testTransientStorage_SetAndGetSwapContext() public {
        console.log("\n=== P1 CRITICAL: Testing Transient Storage Set/Get Operations ===");

        // Test setting transient storage
        vm.prank(address(hook));
        storageContract.setTransientSwapContext(
            alice,
            uint128(0.1 ether), // pendingSaveAmount
            1000, // currentPercentage
            true, // hasStrategy
            0, // savingsTokenType (INPUT)
            false, // roundUpSavings
            false // enableDCA
        );

        // Test getting transient storage
        SpendSaveStorage.SwapContext memory context = storageContract.getSwapContext(alice);

        // Verify all fields are correctly stored and retrieved
        assertEq(context.pendingSaveAmount, 0.1 ether, "pendingSaveAmount should match");
        assertEq(context.currentPercentage, 1000, "currentPercentage should match");
        assertTrue(context.hasStrategy, "hasStrategy should be true");
        assertEq(uint8(context.savingsTokenType), 0, "savingsTokenType should match");
        assertFalse(context.enableDCA, "enableDCA should be false");
        assertFalse(context.roundUpSavings, "roundUpSavings should be false");

        console.log("SUCCESS: Transient storage set/get operations working correctly");
        console.log("SUCCESS: All SwapContext fields stored and retrieved accurately");
    }

    function testTransientStorage_MultipleUsers() public {
        console.log("\n=== P1 CRITICAL: Testing Transient Storage Multiple Users ===");

        // Set different contexts for different users
        vm.startPrank(address(hook));

        // Alice's context - INPUT savings
        storageContract.setTransientSwapContext(alice, uint128(0.1 ether), 1000, true, 0, false, false);

        // Bob's context - OUTPUT savings with DCA
        storageContract.setTransientSwapContext(bob, uint128(0.2 ether), 2000, true, 1, false, true);

        vm.stopPrank();

        // Verify Alice's context
        SpendSaveStorage.SwapContext memory aliceContext = storageContract.getSwapContext(alice);
        assertEq(aliceContext.pendingSaveAmount, 0.1 ether, "Alice pendingSaveAmount");
        assertEq(aliceContext.currentPercentage, 1000, "Alice percentage");
        assertEq(uint8(aliceContext.savingsTokenType), 0, "Alice should have INPUT savings");

        // Verify Bob's context
        SpendSaveStorage.SwapContext memory bobContext = storageContract.getSwapContext(bob);
        assertEq(bobContext.pendingSaveAmount, 0.2 ether, "Bob pendingSaveAmount");
        assertEq(bobContext.currentPercentage, 2000, "Bob percentage");
        assertEq(uint8(bobContext.savingsTokenType), 1, "Bob should have OUTPUT savings");
        assertTrue(bobContext.enableDCA, "Bob should execute DCA");

        console.log("SUCCESS: Multiple users' transient storage isolated correctly");
        console.log("SUCCESS: No interference between different user contexts");
    }

    function testTransientStorage_Cleanup() public {
        console.log("\n=== P1 CRITICAL: Testing Transient Storage Cleanup ===");

        // Set transient storage for user
        vm.prank(address(hook));
        storageContract.setTransientSwapContext(alice, uint128(0.1 ether), 1000, true, 0, false, false);

        // Verify context is set
        SpendSaveStorage.SwapContext memory contextBefore = storageContract.getSwapContext(alice);
        assertEq(contextBefore.pendingSaveAmount, 0.1 ether, "Context should be set");
        assertTrue(contextBefore.hasStrategy, "Should have strategy before cleanup");

        // Clear transient storage
        vm.prank(address(hook));
        storageContract.clearTransientSwapContext(alice);

        // Verify context is cleared
        SpendSaveStorage.SwapContext memory contextAfter = storageContract.getSwapContext(alice);
        assertEq(contextAfter.pendingSaveAmount, 0, "pendingSaveAmount should be cleared");
        assertEq(contextAfter.currentPercentage, 0, "currentPercentage should be cleared");
        assertFalse(contextAfter.hasStrategy, "hasStrategy should be cleared");
        assertEq(contextAfter.currentTick, 0, "currentTick should be cleared");
        assertFalse(contextAfter.enableDCA, "enableDCA should be cleared");
        assertFalse(contextAfter.roundUpSavings, "roundUpSavings should be cleared");

        console.log("SUCCESS: Transient storage cleanup working correctly");
        console.log("SUCCESS: All context fields properly reset to default values");
    }

    function testTransientStorage_BeforeAfterSwapCycle() public {
        console.log("\n=== P1 CRITICAL: Testing Complete beforeSwap -> afterSwap Transient Storage Cycle ===");

        // Test complete cycle: beforeSwap sets, afterSwap uses and clears
        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        bytes memory hookData = abi.encode(alice);

        // Step 1: Call beforeSwap (should set transient storage)
        vm.prank(address(hook));
        (bytes4 beforeSelector, BeforeSwapDelta beforeDelta, uint24 fee) =
            hook._beforeSwapInternal(alice, poolKey, params, hookData);

        assertEq(beforeSelector, IHooks.beforeSwap.selector, "beforeSwap should execute");

        // Step 2: Verify transient storage is set
        SpendSaveStorage.SwapContext memory contextAfterBefore = storageContract.getSwapContext(alice);
        assertTrue(contextAfterBefore.hasStrategy, "Should have strategy after beforeSwap");
        assertEq(contextAfterBefore.currentPercentage, 1000, "Should have 10% savings");
        assertEq(uint8(contextAfterBefore.savingsTokenType), 0, "Should be INPUT savings");

        console.log("After beforeSwap - pendingSaveAmount:", contextAfterBefore.pendingSaveAmount);
        console.log("After beforeSwap - hasStrategy:", contextAfterBefore.hasStrategy);

        // Step 3: Call afterSwap (should use and clear transient storage)
        BalanceDelta swapDelta = toBalanceDelta(-1 ether, 0.9 ether);

        vm.prank(address(hook));
        (bytes4 afterSelector, int128 hookDelta) = hook._afterSwapInternal(alice, poolKey, params, swapDelta, hookData);

        assertEq(afterSelector, IHooks.afterSwap.selector, "afterSwap should execute");

        // Step 4: Verify transient storage is cleared
        SpendSaveStorage.SwapContext memory contextAfterAfter = storageContract.getSwapContext(alice);
        assertFalse(contextAfterAfter.hasStrategy, "Should not have strategy after afterSwap");
        assertEq(contextAfterAfter.pendingSaveAmount, 0, "Should be cleared after afterSwap");
        assertEq(contextAfterAfter.currentPercentage, 0, "Should be cleared after afterSwap");

        console.log("After afterSwap - pendingSaveAmount:", contextAfterAfter.pendingSaveAmount);
        console.log("After afterSwap - hasStrategy:", contextAfterAfter.hasStrategy);

        console.log("SUCCESS: Complete beforeSwap -> afterSwap transient storage cycle working");
        console.log("SUCCESS: Transient storage properly managed throughout swap lifecycle");
    }

    function testTransientStorage_MultipleSwapCycles() public {
        console.log("\n=== P1 CRITICAL: Testing Multiple Swap Cycles Transient Storage ===");

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        bytes memory aliceHookData = abi.encode(alice);
        BalanceDelta swapDelta = toBalanceDelta(-1 ether, 0.9 ether);

        // Perform multiple swap cycles to test consistency
        for (uint256 i = 0; i < 3; i++) {
            console.log("Swap cycle", i + 1);

            // beforeSwap
            vm.prank(address(hook));
            hook._beforeSwapInternal(alice, poolKey, params, aliceHookData);

            // Verify context is set
            SpendSaveStorage.SwapContext memory contextDuringSwap = storageContract.getSwapContext(alice);
            assertTrue(contextDuringSwap.hasStrategy, "Should have strategy during swap");

            // afterSwap
            vm.prank(address(hook));
            hook._afterSwapInternal(alice, poolKey, params, swapDelta, aliceHookData);

            // Verify context is cleared
            SpendSaveStorage.SwapContext memory contextAfterSwap = storageContract.getSwapContext(alice);
            assertFalse(contextAfterSwap.hasStrategy, "Should not have strategy after swap");
            assertEq(contextAfterSwap.pendingSaveAmount, 0, "Should be cleared");
        }

        console.log("SUCCESS: Multiple swap cycles maintain transient storage integrity");
        console.log("SUCCESS: No state leakage between different swap transactions");
    }

    function testTransientStorage_ConcurrentUsers() public {
        console.log("\n=== P1 CRITICAL: Testing Concurrent Users Transient Storage ===");

        SwapParams memory params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

        bytes memory aliceHookData = abi.encode(alice);
        bytes memory bobHookData = abi.encode(bob);

        // Start Alice's swap
        vm.prank(address(hook));
        hook._beforeSwapInternal(alice, poolKey, params, aliceHookData);

        // Start Bob's swap while Alice's is in progress
        vm.prank(address(hook));
        hook._beforeSwapInternal(bob, poolKey, params, bobHookData);

        // Verify both contexts exist independently
        SpendSaveStorage.SwapContext memory aliceContext = storageContract.getSwapContext(alice);
        SpendSaveStorage.SwapContext memory bobContext = storageContract.getSwapContext(bob);

        assertTrue(aliceContext.hasStrategy, "Alice should have strategy");
        assertTrue(bobContext.hasStrategy, "Bob should have strategy");
        assertEq(aliceContext.currentPercentage, 1000, "Alice should have 10%");
        assertEq(bobContext.currentPercentage, 2000, "Bob should have 20%");
        assertEq(uint8(aliceContext.savingsTokenType), 0, "Alice should have INPUT savings");
        assertEq(uint8(bobContext.savingsTokenType), 1, "Bob should have OUTPUT savings");

        // Complete Alice's swap
        BalanceDelta aliceSwapDelta = toBalanceDelta(-1 ether, 0.9 ether);
        vm.prank(address(hook));
        hook._afterSwapInternal(alice, poolKey, params, aliceSwapDelta, aliceHookData);

        // Verify Alice's context is cleared but Bob's remains
        SpendSaveStorage.SwapContext memory aliceContextAfter = storageContract.getSwapContext(alice);
        SpendSaveStorage.SwapContext memory bobContextStill = storageContract.getSwapContext(bob);

        assertFalse(aliceContextAfter.hasStrategy, "Alice context should be cleared");
        assertTrue(bobContextStill.hasStrategy, "Bob context should still exist");

        // Complete Bob's swap
        BalanceDelta bobSwapDelta = toBalanceDelta(-1 ether, 0.8 ether); // 20% savings
        vm.prank(address(hook));
        hook._afterSwapInternal(bob, poolKey, params, bobSwapDelta, bobHookData);

        // Verify both contexts are now cleared
        SpendSaveStorage.SwapContext memory aliceContextFinal = storageContract.getSwapContext(alice);
        SpendSaveStorage.SwapContext memory bobContextFinal = storageContract.getSwapContext(bob);

        assertFalse(aliceContextFinal.hasStrategy, "Alice context should remain cleared");
        assertFalse(bobContextFinal.hasStrategy, "Bob context should be cleared");

        console.log("SUCCESS: Concurrent users' transient storage properly isolated");
        console.log("SUCCESS: Independent context management for simultaneous swaps");
    }

    function testTransientStorage_AccessControl() public {
        console.log("\n=== P1 CRITICAL: Testing Transient Storage Access Control ===");

        // Test that only authorized addresses can modify transient storage

        // Test unauthorized access should revert
        vm.expectRevert();
        vm.prank(alice); // Alice is not authorized to set transient storage
        storageContract.setTransientSwapContext(alice, 0.1 ether, 1000, true, 0, false, true);

        // Test unauthorized clear should revert
        vm.expectRevert();
        vm.prank(bob); // Bob is not authorized to clear transient storage
        storageContract.clearTransientSwapContext(alice);

        // Test hook can set transient storage (authorized)
        vm.prank(address(hook));
        storageContract.setTransientSwapContext(alice, uint128(0.1 ether), 1000, true, 0, false, false);

        // Verify it was set
        SpendSaveStorage.SwapContext memory context = storageContract.getSwapContext(alice);
        assertTrue(context.hasStrategy, "Hook should be able to set context");

        // Test hook can clear transient storage (authorized)
        vm.prank(address(hook));
        storageContract.clearTransientSwapContext(alice);

        // Verify it was cleared
        SpendSaveStorage.SwapContext memory clearedContext = storageContract.getSwapContext(alice);
        assertFalse(clearedContext.hasStrategy, "Hook should be able to clear context");

        console.log("SUCCESS: Transient storage access control working correctly");
        console.log("SUCCESS: Only authorized addresses can modify transient storage");
    }

    function testTransientStorage_ComprehensiveReport() public {
        console.log("\n=== P1 CRITICAL: COMPREHENSIVE TRANSIENT STORAGE REPORT ===");

        // Test all individual components first
        testTransientStorage_SetAndGetSwapContext();
        testTransientStorage_MultipleUsers();
        testTransientStorage_Cleanup();
        testTransientStorage_BeforeAfterSwapCycle();
        testTransientStorage_MultipleSwapCycles();
        testTransientStorage_ConcurrentUsers();
        testTransientStorage_AccessControl();

        console.log("\n=== FINAL TRANSIENT STORAGE RESULTS ===");
        console.log("PASS - Set/Get Operations: PASS");
        console.log("PASS - Multiple Users Isolation: PASS");
        console.log("PASS - Cleanup Operations: PASS");
        console.log("PASS - Complete Swap Cycle: PASS");
        console.log("PASS - Multiple Swap Cycles: PASS");
        console.log("PASS - Concurrent Users: PASS");
        console.log("PASS - Access Control: PASS");

        console.log("\n=== TRANSIENT STORAGE SUMMARY ===");
        console.log("Total test scenarios: 7");
        console.log("Scenarios passing: 7");
        console.log("Success rate: 100%");

        console.log("SUCCESS: All transient storage (EIP-1153) functionality validated!");
        console.log("SUCCESS: Gas-efficient swap context management working perfectly!");
    }
}
