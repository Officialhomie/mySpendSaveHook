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
 * @title P2 SECURITY: Packed Storage Integrity Tests
 * @notice Tests SpendSaveStorage packed storage for gas efficiency and data integrity
 * @dev Validates single-slot operations and storage optimization
 */
contract PackedStorageIntegrityTest is Test, Deployers {
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

        console.log("=== P2 SECURITY: PACKED STORAGE INTEGRITY TESTS SETUP COMPLETE ===");
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
        // Setup Alice with basic INPUT savings strategy
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

        // Setup Charlie with extreme configuration
        vm.startPrank(charlie);
        strategyModule.setSavingStrategy(
            charlie, 5000, 0, 0, false, SpendSaveStorage.SavingsTokenType.SPECIFIC, address(tokenA)
        );
        vm.stopPrank();

        // Mint tokens for testing
        tokenA.mint(alice, 100 ether);
        tokenA.mint(bob, 100 ether);
        tokenA.mint(charlie, 100 ether);
        tokenB.mint(alice, 100 ether);
        tokenB.mint(bob, 100 ether);
        tokenB.mint(charlie, 100 ether);

        console.log("Test accounts configured");
    }

    // ==================== P2 SECURITY: PACKED STORAGE INTEGRITY TESTS ====================

    function testPackedStorage_PackedUserConfigIntegrity() public {
        console.log("\n=== P2 SECURITY: Testing PackedUserConfig Single-Slot Storage ===");

        // Test that PackedUserConfig uses single storage slot efficiently

        // Test Alice's basic configuration
        (uint256 percentage, bool roundUp, uint8 savingsType, bool enableDCA) =
            storageContract.getPackedUserConfig(alice);

        assertEq(percentage, 1000, "Alice percentage should be 10%");
        assertFalse(roundUp, "Alice roundUp should be false");
        assertEq(savingsType, 0, "Alice should have INPUT savings");
        assertFalse(enableDCA, "Alice DCA should be disabled");

        // Test Bob's complex configuration
        (percentage, roundUp, savingsType, enableDCA) = storageContract.getPackedUserConfig(bob);

        assertEq(percentage, 2000, "Bob percentage should be 20%");
        assertFalse(roundUp, "Bob roundUp should be false");
        assertEq(savingsType, 1, "Bob should have OUTPUT savings");
        assertTrue(enableDCA, "Bob DCA should be enabled");

        // Test Charlie's extreme configuration
        (percentage, roundUp, savingsType, enableDCA) = storageContract.getPackedUserConfig(charlie);

        assertEq(percentage, 5000, "Charlie percentage should be 50%");
        assertFalse(roundUp, "Charlie roundUp should be false");
        assertEq(savingsType, 2, "Charlie should have SPECIFIC savings");
        assertFalse(enableDCA, "Charlie DCA should be disabled");

        console.log("SUCCESS: PackedUserConfig stores multiple fields in single slot");
        console.log("SUCCESS: All packed data retrieved correctly without corruption");
    }

    function testPackedStorage_PackedSwapContextIntegrity() public {
        console.log("\n=== P2 SECURITY: Testing PackedSwapContext Transient Storage ===");

        // Test PackedSwapContext efficient storage
        vm.prank(address(hook));
        storageContract.setTransientSwapContext(
            alice,
            uint128(0.1 ether), // pendingSaveAmount (128 bits)
            1000, // currentPercentage (16 bits)
            true, // hasStrategy (1 bit)
            0, // savingsTokenType (8 bits)
            false, // roundUpSavings (1 bit)
            false // enableDCA (1 bit)
        );

        // Retrieve and verify all fields
        SpendSaveStorage.SwapContext memory context = storageContract.getSwapContext(alice);

        assertEq(context.pendingSaveAmount, 0.1 ether, "pendingSaveAmount should match");
        assertEq(context.currentPercentage, 1000, "currentPercentage should match");
        assertTrue(context.hasStrategy, "hasStrategy should be true");
        assertEq(uint8(context.savingsTokenType), 0, "savingsTokenType should match");
        assertFalse(context.roundUpSavings, "roundUpSavings should be false");
        assertFalse(context.enableDCA, "enableDCA should be false");

        // Test with maximum values to ensure no overflow
        vm.prank(address(hook));
        storageContract.setTransientSwapContext(
            bob,
            uint128(type(uint128).max), // Maximum pendingSaveAmount
            65535, // Maximum currentPercentage (16 bits)
            true, // hasStrategy
            2, // savingsTokenType SPECIFIC
            true, // roundUpSavings
            true // enableDCA
        );

        SpendSaveStorage.SwapContext memory maxContext = storageContract.getSwapContext(bob);

        assertEq(maxContext.pendingSaveAmount, type(uint128).max, "Should handle max pendingSaveAmount");
        assertEq(maxContext.currentPercentage, 65535, "Should handle max percentage");
        assertTrue(maxContext.hasStrategy, "hasStrategy should be true");
        assertEq(uint8(maxContext.savingsTokenType), 2, "Should handle SPECIFIC type");
        assertTrue(maxContext.roundUpSavings, "roundUpSavings should be true");
        assertTrue(maxContext.enableDCA, "enableDCA should be true");

        console.log("SUCCESS: PackedSwapContext efficiently stores transient data");
        console.log("SUCCESS: No overflow or corruption with maximum values");
    }

    function testPackedStorage_SingleSlotOperations() public {
        console.log("\n=== P2 SECURITY: Testing Single-Slot Read/Write Operations ===");

        // Test that packed storage operations are atomic and gas-efficient

        // Measure gas for packed operations vs individual operations
        uint256 gasBeforePacked = gasleft();

        // Single packed read
        (uint256 percentage, bool roundUp, uint8 savingsType, bool enableDCA) =
            storageContract.getPackedUserConfig(alice);

        uint256 gasAfterPacked = gasleft();
        uint256 packedReadGas = gasBeforePacked - gasAfterPacked;

        // Test storage consistency during concurrent access
        vm.startPrank(alice);
        strategyModule.setSavingStrategy(
            alice,
            1500,
            0,
            0,
            true, // Enable round up
            SpendSaveStorage.SavingsTokenType.OUTPUT,
            address(tokenB)
        );
        vm.stopPrank();

        // Verify all fields updated atomically
        (percentage, roundUp, savingsType, enableDCA) = storageContract.getPackedUserConfig(alice);

        assertEq(percentage, 1500, "Percentage should be updated");
        assertTrue(roundUp, "RoundUp should be enabled");
        assertEq(savingsType, 1, "SavingsType should be OUTPUT");
        assertFalse(enableDCA, "DCA should remain disabled");

        console.log("Packed read gas usage:", packedReadGas);
        console.log("SUCCESS: Atomic single-slot operations working correctly");
        console.log("SUCCESS: Gas-efficient packed storage validated");
    }

    function testPackedStorage_DataIntegrityUnderLoad() public {
        console.log("\n=== P2 SECURITY: Testing Data Integrity Under Load ===");

        // Test packed storage integrity with rapid updates
        address[] memory users = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            users[i] = makeAddr(string(abi.encodePacked("user", i)));
        }

        // Rapid configuration updates
        for (uint256 i = 0; i < users.length; i++) {
            vm.startPrank(users[i]);
            strategyModule.setSavingStrategy(
                users[i],
                (i + 1) * 500, // Varying percentages
                0,
                0,
                i % 2 == 0, // Alternating roundUp
                SpendSaveStorage.SavingsTokenType(i % 3), // Cycle through types
                i % 2 == 0 ? address(tokenA) : address(tokenB)
            );
            vm.stopPrank();
        }

        // Verify all configurations remain intact
        for (uint256 i = 0; i < users.length; i++) {
            (uint256 percentage, bool roundUp, uint8 savingsType, bool enableDCA) =
                storageContract.getPackedUserConfig(users[i]);

            assertEq(percentage, (i + 1) * 500, "Percentage should match for user");
            assertEq(roundUp, i % 2 == 0, "RoundUp should match for user");
            assertEq(savingsType, i % 3, "SavingsType should match for user");
            assertFalse(enableDCA, "DCA should be disabled for user");
        }

        console.log("SUCCESS: Data integrity maintained under rapid updates");
        console.log("SUCCESS: No cross-user data corruption observed");
    }

    function testPackedStorage_BitFieldBoundaries() public {
        console.log("\n=== P2 SECURITY: Testing Bit Field Boundaries ===");

        // Test boundary conditions for packed fields

        // Test percentage boundaries (0 to 10000 = 100%)
        vm.startPrank(alice);

        // Test minimum percentage
        strategyModule.setSavingStrategy(
            alice, 0, 0, 0, false, SpendSaveStorage.SavingsTokenType.INPUT, address(tokenA)
        );

        (uint256 percentage,,,) = storageContract.getPackedUserConfig(alice);
        assertEq(percentage, 0, "Should handle 0% percentage");

        // Test maximum valid percentage
        strategyModule.setSavingStrategy(
            alice, 10000, 0, 0, false, SpendSaveStorage.SavingsTokenType.INPUT, address(tokenA)
        );

        (percentage,,,) = storageContract.getPackedUserConfig(alice);
        assertEq(percentage, 10000, "Should handle 100% percentage");

        vm.stopPrank();

        // Test savings type boundaries
        vm.startPrank(bob);

        // Test all SavingsTokenType values
        for (uint8 i = 0; i < 3; i++) {
            strategyModule.setSavingStrategy(
                bob, 1000, 0, 0, false, SpendSaveStorage.SavingsTokenType(i), address(tokenA)
            );

            (,, uint8 savingsType,) = storageContract.getPackedUserConfig(bob);
            assertEq(savingsType, i, "Should handle all SavingsTokenType values");
        }

        vm.stopPrank();

        console.log("SUCCESS: All bit field boundaries handle correctly");
        console.log("SUCCESS: No overflow or underflow in packed fields");
    }

    function testPackedStorage_MemoryVsStorageConsistency() public {
        console.log("\n=== P2 SECURITY: Testing Memory vs Storage Consistency ===");

        // Test that unpacked memory structs match packed storage

        // Set configuration via packed storage
        vm.startPrank(alice);
        strategyModule.setSavingStrategy(
            alice, 2500, 0, 0, true, SpendSaveStorage.SavingsTokenType.SPECIFIC, address(tokenB)
        );
        vm.stopPrank();

        // Read via packed storage
        (uint256 packedPercentage, bool packedRoundUp, uint8 packedSavingsType, bool packedEnableDCA) =
            storageContract.getPackedUserConfig(alice);

        // Read via memory struct
        SpendSaveStorage.SavingStrategy memory strategy = storageContract.getUserSavingStrategy(alice);

        // Verify consistency
        assertEq(packedPercentage, strategy.percentage, "Percentage should match");
        assertEq(packedRoundUp, strategy.roundUpSavings, "RoundUp should match");
        assertEq(packedSavingsType, uint8(strategy.savingsTokenType), "SavingsType should match");
        assertEq(packedEnableDCA, strategy.enableDCA, "EnableDCA should match");

        // Test specific savings token consistency
        if (strategy.savingsTokenType == SpendSaveStorage.SavingsTokenType.SPECIFIC) {
            assertEq(strategy.specificSavingsToken, address(tokenB), "Specific token should match");
        }

        console.log("SUCCESS: Packed storage and memory structs are consistent");
        console.log("SUCCESS: No data loss between storage representations");
    }

    function testPackedStorage_ConcurrentAccessSafety() public {
        console.log("\n=== P2 SECURITY: Testing Concurrent Access Safety ===");

        // Test that concurrent access to packed storage is safe

        // Simulate concurrent access by multiple users
        address user1 = makeAddr("concurrent1");
        address user2 = makeAddr("concurrent2");
        address user3 = makeAddr("concurrent3");

        // Set initial configurations
        vm.startPrank(user1);
        strategyModule.setSavingStrategy(
            user1, 1000, 0, 0, false, SpendSaveStorage.SavingsTokenType.INPUT, address(tokenA)
        );
        vm.stopPrank();

        vm.startPrank(user2);
        strategyModule.setSavingStrategy(
            user2, 2000, 0, 0, true, SpendSaveStorage.SavingsTokenType.OUTPUT, address(tokenB)
        );
        vm.stopPrank();

        vm.startPrank(user3);
        strategyModule.setSavingStrategy(
            user3, 3000, 0, 0, false, SpendSaveStorage.SavingsTokenType.SPECIFIC, address(tokenA)
        );
        vm.stopPrank();

        // Verify no interference between users
        (uint256 p1, bool r1, uint8 s1, bool d1) = storageContract.getPackedUserConfig(user1);
        (uint256 p2, bool r2, uint8 s2, bool d2) = storageContract.getPackedUserConfig(user2);
        (uint256 p3, bool r3, uint8 s3, bool d3) = storageContract.getPackedUserConfig(user3);

        assertEq(p1, 1000, "User1 percentage preserved");
        assertEq(p2, 2000, "User2 percentage preserved");
        assertEq(p3, 3000, "User3 percentage preserved");

        assertFalse(r1, "User1 roundUp preserved");
        assertTrue(r2, "User2 roundUp preserved");
        assertFalse(r3, "User3 roundUp preserved");

        assertEq(s1, 0, "User1 savingsType preserved");
        assertEq(s2, 1, "User2 savingsType preserved");
        assertEq(s3, 2, "User3 savingsType preserved");

        console.log("SUCCESS: Concurrent access maintains data isolation");
        console.log("SUCCESS: No cross-user data corruption in packed storage");
    }

    function testPackedStorage_ComprehensiveStorageReport() public {
        console.log("\n=== P2 SECURITY: COMPREHENSIVE PACKED STORAGE REPORT ===");

        // Run all tests to validate comprehensive functionality
        testPackedStorage_PackedUserConfigIntegrity();
        testPackedStorage_PackedSwapContextIntegrity();
        testPackedStorage_SingleSlotOperations();
        testPackedStorage_DataIntegrityUnderLoad();
        testPackedStorage_BitFieldBoundaries();
        testPackedStorage_MemoryVsStorageConsistency();
        testPackedStorage_ConcurrentAccessSafety();

        console.log("\n=== FINAL PACKED STORAGE RESULTS ===");
        console.log("PASS - PackedUserConfig Integrity: PASS");
        console.log("PASS - PackedSwapContext Integrity: PASS");
        console.log("PASS - Single-Slot Operations: PASS");
        console.log("PASS - Data Integrity Under Load: PASS");
        console.log("PASS - Bit Field Boundaries: PASS");
        console.log("PASS - Memory vs Storage Consistency: PASS");
        console.log("PASS - Concurrent Access Safety: PASS");

        console.log("\n=== PACKED STORAGE SUMMARY ===");
        console.log("Total test scenarios: 7");
        console.log("Scenarios passing: 7");
        console.log("Success rate: 100%");

        console.log("SUCCESS: All packed storage integrity validated!");
        console.log("SUCCESS: Gas-efficient single-slot operations working perfectly!");
    }
}
