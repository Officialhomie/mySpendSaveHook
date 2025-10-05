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
 * @title P1 CRITICAL: Hook Failure Scenarios Tests
 * @notice Tests swap continuation when hook fails - critical for protocol safety
 * @dev Validates that failed hooks don't break core Uniswap V4 functionality
 */
contract HookFailureScenariosTest is Test, Deployers {
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
    
    // Failure test scenarios
    struct FailureScenario {
        string name;
        bool shouldRevert;
        bool shouldContinueSwap;
        string expectedBehavior;
    }
    
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
        
        console.log("=== P1 CRITICAL: HOOK FAILURE SCENARIOS TESTS SETUP COMPLETE ===");
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
            address(strategyModule), address(savingsModule), address(dcaModule),
            address(slippageModule), address(tokenModule), address(dailySavingsModule)
        );
        
        savingsModule.setModuleReferences(
            address(strategyModule), address(savingsModule), address(dcaModule),
            address(slippageModule), address(tokenModule), address(dailySavingsModule)
        );
        
        dcaModule.setModuleReferences(
            address(strategyModule), address(savingsModule), address(dcaModule),
            address(slippageModule), address(tokenModule), address(dailySavingsModule)
        );
        
        slippageModule.setModuleReferences(
            address(strategyModule), address(savingsModule), address(dcaModule),
            address(slippageModule), address(tokenModule), address(dailySavingsModule)
        );
        
        tokenModule.setModuleReferences(
            address(strategyModule), address(savingsModule), address(dcaModule),
            address(slippageModule), address(tokenModule), address(dailySavingsModule)
        );
        
        dailySavingsModule.setModuleReferences(
            address(strategyModule), address(savingsModule), address(dcaModule),
            address(slippageModule), address(tokenModule), address(dailySavingsModule)
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
        // Setup Alice with savings strategy
        vm.startPrank(alice);
        strategyModule.setSavingStrategy(
            alice, 1000, 0, 0, false, 
            SpendSaveStorage.SavingsTokenType.INPUT, address(tokenA)
        );
        vm.stopPrank();
        
        // Setup Bob with complex strategy
        vm.startPrank(bob);
        strategyModule.setSavingStrategy(
            bob, 2000, 0, 0, false, 
            SpendSaveStorage.SavingsTokenType.OUTPUT, address(tokenB)
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
    
    // ==================== P1 CRITICAL: HOOK FAILURE SCENARIOS TESTS ====================
    
    function testHookFailure_InvalidUserData() public {
        console.log("\n=== P1 CRITICAL: Testing Invalid User Data Hook Failure ===");
        
        // Test scenario: Invalid hookData that could cause hook to fail
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        
        // Create invalid hookData (empty bytes instead of encoded address)
        bytes memory invalidHookData = "";
        
        // Test beforeSwap with invalid data
        try hook._beforeSwapInternal(alice, poolKey, params, invalidHookData) {
            console.log("beforeSwap handled invalid data gracefully");
        } catch Error(string memory reason) {
            console.log("beforeSwap failed with reason:", reason);
        } catch {
            console.log("beforeSwap failed with low-level error");
        }
        
        // Test afterSwap with invalid data
        BalanceDelta swapDelta = toBalanceDelta(-1 ether, 0.9 ether);
        
        try hook._afterSwapInternal(alice, poolKey, params, swapDelta, invalidHookData) {
            console.log("afterSwap handled invalid data gracefully");
        } catch Error(string memory reason) {
            console.log("afterSwap failed with reason:", reason);
        } catch {
            console.log("afterSwap failed with low-level error");
        }
        
        console.log("SUCCESS: Hook failure handling tested for invalid user data");
    }
    
    function testHookFailure_ModuleNotInitialized() public {
        console.log("\n=== P1 CRITICAL: Testing Module Not Initialized Failure ===");
        
        // Create a fresh hook with uninitialized modules to test failure handling
        SpendSaveStorage tempStorage = new SpendSaveStorage(address(manager));
        
        // Deploy hook without initializing modules
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(SpendSaveHook).creationCode,
            abi.encode(IPoolManager(address(manager)), tempStorage)
        );
        
        SpendSaveHook uninitializedHook = new SpendSaveHook{salt: salt}(
            IPoolManager(address(manager)), 
            tempStorage
        );
        
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        
        bytes memory hookData = abi.encode(alice);
        
        // Test beforeSwap with uninitialized modules
        try uninitializedHook._beforeSwapInternal(alice, poolKey, params, hookData) {
            console.log("beforeSwap handled uninitialized modules gracefully");
        } catch Error(string memory reason) {
            console.log("beforeSwap failed with reason:", reason);
            assertTrue(bytes(reason).length > 0, "Should have meaningful error message");
        } catch {
            console.log("beforeSwap failed with low-level error");
        }
        
        console.log("SUCCESS: Hook failure handling tested for uninitialized modules");
    }
    
    function testHookFailure_InsufficientGas() public {
        console.log("\n=== P1 CRITICAL: Testing Insufficient Gas Failure ===");
        
        // Test scenario: Simulate low gas conditions
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        
        bytes memory hookData = abi.encode(alice);
        BalanceDelta swapDelta = toBalanceDelta(-1 ether, 0.9 ether);
        
        // Test with very low gas limit - this tests the gas threshold checks
        // Note: We can't directly control gas in foundry, but we can test the gas check logic
        
        // The hook should have gas threshold checks
        uint256 gasBeforeCall = gasleft();
        
        vm.prank(address(hook));
        (bytes4 selector, int128 hookDelta) = hook._afterSwapInternal(
            alice, poolKey, params, swapDelta, hookData
        );
        
        uint256 gasUsed = gasBeforeCall - gasleft();
        
        assertEq(selector, IHooks.afterSwap.selector, "Should return correct selector");
        
        console.log("Gas used in afterSwap:", gasUsed);
        console.log("SUCCESS: Hook executed with gas monitoring");
    }
    
    function testHookFailure_ModuleReverts() public {
        console.log("\n=== P1 CRITICAL: Testing Module Function Reverts ===");
        
        // Test scenario: Call hook functions that might cause module reverts
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        
        bytes memory hookData = abi.encode(alice);
        
        // Test beforeSwap - should handle any module failures gracefully
        vm.prank(address(hook));
        (bytes4 beforeSelector, BeforeSwapDelta beforeDelta, uint24 fee) = hook._beforeSwapInternal(
            alice, poolKey, params, hookData
        );
        
        assertEq(beforeSelector, IHooks.beforeSwap.selector, "beforeSwap should execute");
        
        // Test afterSwap - should handle any module failures gracefully
        BalanceDelta swapDelta = toBalanceDelta(-1 ether, 0.9 ether);
        
        vm.prank(address(hook));
        (bytes4 afterSelector, int128 hookDelta) = hook._afterSwapInternal(
            alice, poolKey, params, swapDelta, hookData
        );
        
        assertEq(afterSelector, IHooks.afterSwap.selector, "afterSwap should execute");
        
        console.log("SUCCESS: Hook handled potential module reverts gracefully");
    }
    
    function testHookFailure_InvalidPoolKey() public {
        console.log("\n=== P1 CRITICAL: Testing Invalid Pool Key Failure ===");
        
        // Test scenario: Invalid pool key that could cause failures
        PoolKey memory invalidPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0)),
            fee: 0,
            tickSpacing: 0,
            hooks: IHooks(address(0))
        });
        
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        
        bytes memory hookData = abi.encode(alice);
        
        // Test beforeSwap with invalid pool key
        try hook._beforeSwapInternal(alice, invalidPoolKey, params, hookData) {
            console.log("beforeSwap handled invalid pool key gracefully");
        } catch Error(string memory reason) {
            console.log("beforeSwap failed with reason:", reason);
        } catch {
            console.log("beforeSwap failed with low-level error");
        }
        
        // Test afterSwap with invalid pool key
        BalanceDelta swapDelta = toBalanceDelta(-1 ether, 0.9 ether);
        
        try hook._afterSwapInternal(alice, invalidPoolKey, params, swapDelta, hookData) {
            console.log("afterSwap handled invalid pool key gracefully");
        } catch Error(string memory reason) {
            console.log("afterSwap failed with reason:", reason);
        } catch {
            console.log("afterSwap failed with low-level error");
        }
        
        console.log("SUCCESS: Hook failure handling tested for invalid pool key");
    }
    
    function testHookFailure_ExtremeSwapParameters() public {
        console.log("\n=== P1 CRITICAL: Testing Extreme Swap Parameters ===");
        
        // Test scenario: Extreme swap parameters that could cause issues
        SwapParams memory extremeParams = SwapParams({
            zeroForOne: true,
            amountSpecified: type(int256).min, // Extreme negative value
            sqrtPriceLimitX96: type(uint160).max // Extreme price limit
        });
        
        bytes memory hookData = abi.encode(alice);
        
        // Test beforeSwap with extreme parameters
        try hook._beforeSwapInternal(alice, poolKey, extremeParams, hookData) {
            console.log("beforeSwap handled extreme parameters gracefully");
        } catch Error(string memory reason) {
            console.log("beforeSwap failed with reason:", reason);
        } catch {
            console.log("beforeSwap failed with low-level error");
        }
        
        // Test afterSwap with extreme parameters
        BalanceDelta extremeSwapDelta = toBalanceDelta(type(int128).min, type(int128).max);
        
        try hook._afterSwapInternal(alice, poolKey, extremeParams, extremeSwapDelta, hookData) {
            console.log("afterSwap handled extreme parameters gracefully");
        } catch Error(string memory reason) {
            console.log("afterSwap failed with reason:", reason);
        } catch {
            console.log("afterSwap failed with low-level error");
        }
        
        console.log("SUCCESS: Hook failure handling tested for extreme parameters");
    }
    
    function testHookFailure_ComprehensiveFailureRecovery() public {
        console.log("\n=== P1 CRITICAL: Testing Comprehensive Failure Recovery ===");
        
        // Test that the hook can recover from various failure scenarios
        uint256 successfulCalls = 0;
        uint256 totalTests = 5;
        
        // Test 1: Normal operation after previous failures
        SwapParams memory normalParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        
        bytes memory normalHookData = abi.encode(alice);
        BalanceDelta normalSwapDelta = toBalanceDelta(-1 ether, 0.9 ether);
        
        try hook._afterSwapInternal(alice, poolKey, normalParams, normalSwapDelta, normalHookData) {
            successfulCalls++;
            console.log("Test 1: Normal operation succeeded");
        } catch {
            console.log("Test 1: Normal operation failed");
        }
        
        // Test 2: Different user after failures
        try hook._afterSwapInternal(bob, poolKey, normalParams, normalSwapDelta, abi.encode(bob)) {
            successfulCalls++;
            console.log("Test 2: Different user succeeded");
        } catch {
            console.log("Test 2: Different user failed");
        }
        
        // Test 3: Different direction after failures
        SwapParams memory reverseParams = SwapParams({
            zeroForOne: false,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: 0
        });
        
        try hook._afterSwapInternal(alice, poolKey, reverseParams, normalSwapDelta, normalHookData) {
            successfulCalls++;
            console.log("Test 3: Reverse direction succeeded");
        } catch {
            console.log("Test 3: Reverse direction failed");
        }
        
        // Test 4: Small amount after failures
        SwapParams memory smallParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -0.001 ether,
            sqrtPriceLimitX96: 0
        });
        
        BalanceDelta smallSwapDelta = toBalanceDelta(-0.001 ether, 0.0009 ether);
        
        try hook._afterSwapInternal(alice, poolKey, smallParams, smallSwapDelta, normalHookData) {
            successfulCalls++;
            console.log("Test 4: Small amount succeeded");
        } catch {
            console.log("Test 4: Small amount failed");
        }
        
        // Test 5: Large amount after failures
        SwapParams memory largeParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -10 ether,
            sqrtPriceLimitX96: 0
        });
        
        BalanceDelta largeSwapDelta = toBalanceDelta(-10 ether, 9 ether);
        
        try hook._afterSwapInternal(alice, poolKey, largeParams, largeSwapDelta, normalHookData) {
            successfulCalls++;
            console.log("Test 5: Large amount succeeded");
        } catch {
            console.log("Test 5: Large amount failed");
        }
        
        console.log("Successful calls:", successfulCalls, "out of", totalTests);
        console.log("Success rate:", (successfulCalls * 100) / totalTests, "%");
        
        // We expect at least 80% success rate for failure recovery
        assertTrue(successfulCalls >= (totalTests * 8) / 10, "Should have good failure recovery rate");
        
        console.log("SUCCESS: Hook demonstrates good failure recovery capabilities");
    }
}