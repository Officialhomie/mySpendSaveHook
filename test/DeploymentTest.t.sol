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
import {IHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";

// SpendSave Contracts
import {SpendSaveHook} from "../src/SpendSaveHook.sol";
import {SpendSaveStorage} from "../src/SpendSaveStorage.sol";
import {SavingStrategy} from "../src/SavingStrategy.sol";
import {Savings} from "../src/Savings.sol";
import {DCA} from "../src/DCA.sol";
import {Token} from "../src/Token.sol";
import {SlippageControl} from "../src/SlippageControl.sol";
import {DailySavings} from "../src/DailySavings.sol";

/**
 * @title DeploymentTest
 * @notice P10 DEPLOY: Comprehensive testing of complete end-to-end deployment sequence verification
 * @dev Tests network-specific configurations, hook address mining, flag compliance, and deployment failure recovery
 */
contract DeploymentTest is Test, Deployers {
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

    // Test tokens
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    // Pool configuration
    PoolKey public poolKey;

    function setUp() public {
        // Create test accounts
        owner = makeAddr("owner");
        alice = makeAddr("alice");

        // Deploy V4 infrastructure
        deployFreshManagerAndRouters();

        // Deploy tokens
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);

        // Ensure proper token ordering for V4
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }

        console.log("=== P10 DEPLOY: DEPLOYMENT TESTS SETUP COMPLETE ===");
    }

    // ==================== END-TO-END DEPLOYMENT SEQUENCE TESTS ====================

    function testDeploy_CompleteEndToEndDeployment() public {
        console.log("\n=== P10 DEPLOY: Testing Complete End-to-End Deployment ===");

        // Step 1: Deploy storage contract
        vm.prank(owner);
        storageContract = new SpendSaveStorage(address(manager));

        assertEq(storageContract.owner(), owner, "Storage should have correct owner");
        assertEq(storageContract.poolManager(), address(manager), "Storage should reference correct pool manager");

        // Step 2: Deploy all modules
        vm.startPrank(owner);
        savingsModule = new Savings();
        strategyModule = new SavingStrategy();
        tokenModule = new Token();
        dcaModule = new DCA();
        dailySavingsModule = new DailySavings();
        slippageModule = new SlippageControl();
        vm.stopPrank();

        // Step 3: Deploy hook with proper address mining
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

        assertEq(address(hook), hookAddress, "Hook should be deployed at mined address");

        // Step 4: Initialize storage
        vm.prank(owner);
        storageContract.initialize(address(hook));

        assertEq(storageContract.spendSaveHook(), address(hook), "Storage should reference hook");

        // Step 5: Register modules
        vm.startPrank(owner);
        storageContract.registerModule(keccak256("SAVINGS"), address(savingsModule));
        storageContract.registerModule(keccak256("STRATEGY"), address(strategyModule));
        storageContract.registerModule(keccak256("TOKEN"), address(tokenModule));
        storageContract.registerModule(keccak256("DCA"), address(dcaModule));
        storageContract.registerModule(keccak256("DAILY"), address(dailySavingsModule));
        storageContract.registerModule(keccak256("SLIPPAGE"), address(slippageModule));
        vm.stopPrank();

        // Verify all modules are registered
        assertEq(storageContract.getModule(keccak256("SAVINGS")), address(savingsModule), "Savings module should be registered");
        assertEq(storageContract.getModule(keccak256("STRATEGY")), address(strategyModule), "Strategy module should be registered");
        assertEq(storageContract.getModule(keccak256("TOKEN")), address(tokenModule), "Token module should be registered");
        assertEq(storageContract.getModule(keccak256("DCA")), address(dcaModule), "DCA module should be registered");
        assertEq(storageContract.getModule(keccak256("DAILY")), address(dailySavingsModule), "Daily module should be registered");
        assertEq(storageContract.getModule(keccak256("SLIPPAGE")), address(slippageModule), "Slippage module should be registered");

        // Step 6: Initialize modules
        vm.startPrank(owner);
        savingsModule.initialize(storageContract);
        strategyModule.initialize(storageContract);
        tokenModule.initialize(storageContract);
        dcaModule.initialize(storageContract);
        dailySavingsModule.initialize(storageContract);
        slippageModule.initialize(storageContract);
        vm.stopPrank();

        // Step 7: Set cross-module references - must be called by owner
        vm.startPrank(owner);
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

        // Step 8: Initialize pool
        poolKey = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        console.log("Complete end-to-end deployment successful");
        console.log("SUCCESS: Complete end-to-end deployment working");
    }

    function testDeploy_DeploymentSequenceVerification() public {
        console.log("\n=== P10 DEPLOY: Testing Deployment Sequence Verification ===");

        // Deploy storage
        vm.prank(owner);
        storageContract = new SpendSaveStorage(address(manager));

        // Deploy modules
        vm.startPrank(owner);
        savingsModule = new Savings();
        strategyModule = new SavingStrategy();
        tokenModule = new Token();
        dcaModule = new DCA();
        dailySavingsModule = new DailySavings();
        slippageModule = new SlippageControl();
        vm.stopPrank();

        // Deploy hook
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

        // Verify deployment state
        assertEq(storageContract.owner(), owner, "Owner should be set correctly");
        assertEq(storageContract.spendSaveHook(), address(hook), "Hook should be set correctly");
        assertEq(storageContract.poolManager(), address(manager), "Pool manager should be set correctly");

        // Verify all modules are registered
        assertEq(storageContract.getModule(keccak256("SAVINGS")), address(savingsModule), "All modules should be registered");
        assertEq(storageContract.getModule(keccak256("STRATEGY")), address(strategyModule), "All modules should be registered");
        assertEq(storageContract.getModule(keccak256("TOKEN")), address(tokenModule), "All modules should be registered");
        assertEq(storageContract.getModule(keccak256("DCA")), address(dcaModule), "All modules should be registered");
        assertEq(storageContract.getModule(keccak256("DAILY")), address(dailySavingsModule), "All modules should be registered");
        assertEq(storageContract.getModule(keccak256("SLIPPAGE")), address(slippageModule), "All modules should be registered");

        console.log("Deployment sequence verification successful");
        console.log("SUCCESS: Deployment sequence verification working");
    }

    // ==================== NETWORK-SPECIFIC CONFIGURATION TESTS ====================

    function testDeploy_BaseMainnetConfiguration() public {
        console.log("\n=== P10 DEPLOY: Testing Base Mainnet Configuration ===");

        // Set chain ID to Base mainnet
        vm.chainId(8453);

        // Deploy with Base mainnet specific settings
        vm.prank(owner);
        storageContract = new SpendSaveStorage(address(manager));

        // Configure Base mainnet specific parameters
        vm.prank(owner);
        storageContract.setTreasuryFee(150); // 1.5% fee for mainnet

        vm.prank(owner);
        storageContract.setMaxSavingsPercentage(7500); // 75% max for mainnet

        // Verify Base mainnet configuration
        assertEq(storageContract.treasuryFee(), 150, "Base mainnet treasury fee should be set");
        assertEq(storageContract.maxSavingsPercentage(), 7500, "Base mainnet max savings should be set");

        console.log("Base mainnet configuration working correctly");
        console.log("SUCCESS: Base mainnet configuration working");
    }

    function testDeploy_BaseSepoliaConfiguration() public {
        console.log("\n=== P10 DEPLOY: Testing Base Sepolia Configuration ===");

        // Set chain ID to Base Sepolia
        vm.chainId(84532);

        // Deploy with Base Sepolia specific settings
        vm.prank(owner);
        storageContract = new SpendSaveStorage(address(manager));

        // Configure Base Sepolia specific parameters (higher fees for testnet)
        vm.prank(owner);
        storageContract.setTreasuryFee(300); // 3% fee for testnet

        vm.prank(owner);
        storageContract.setMaxSavingsPercentage(9000); // 90% max for testnet

        // Verify Base Sepolia configuration
        assertEq(storageContract.treasuryFee(), 300, "Base Sepolia treasury fee should be set");
        assertEq(storageContract.maxSavingsPercentage(), 9000, "Base Sepolia max savings should be set");

        console.log("Base Sepolia configuration working correctly");
        console.log("SUCCESS: Base Sepolia configuration working");
    }

    function testDeploy_NetworkSpecificModuleConfiguration() public {
        console.log("\n=== P10 DEPLOY: Testing Network-Specific Module Configuration ===");

        // Deploy on Base mainnet
        vm.chainId(8453);

        vm.prank(owner);
        storageContract = new SpendSaveStorage(address(manager));

        // Deploy modules with network-specific initialization
        vm.startPrank(owner);
        savingsModule = new Savings();
        strategyModule = new SavingStrategy();
        tokenModule = new Token();
        vm.stopPrank();

        // Initialize with storage reference
        vm.startPrank(owner);
        savingsModule.initialize(storageContract);
        strategyModule.initialize(storageContract);
        tokenModule.initialize(storageContract);
        vm.stopPrank();

        // Register modules
        vm.startPrank(owner);
        storageContract.registerModule(keccak256("SAVINGS"), address(savingsModule));
        storageContract.registerModule(keccak256("STRATEGY"), address(strategyModule));
        storageContract.registerModule(keccak256("TOKEN"), address(tokenModule));
        vm.stopPrank();

        // Verify modules work correctly on Base mainnet
        assertTrue(storageContract.isAuthorizedModule(address(savingsModule)), "Modules should be authorized");
        assertEq(storageContract.getModule(keccak256("SAVINGS")), address(savingsModule), "Modules should be registered");

        console.log("Network-specific module configuration working");
        console.log("SUCCESS: Network-specific module configuration working");
    }

    // ==================== HOOK ADDRESS MINING TESTS ====================

    function testDeploy_HookAddressMining() public {
        console.log("\n=== P10 DEPLOY: Testing Hook Address Mining ===");

        // Deploy storage
        vm.prank(owner);
        storageContract = new SpendSaveStorage(address(manager));

        // Define hook flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        // Mine hook address
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

        // Verify hook deployed at correct address
        assertEq(address(hook), hookAddress, "Hook should be deployed at mined address");

        // Verify hook has correct flags (flags are in bottom 14 bits, not top 12)
        uint160 hookFlags = uint160(address(hook)) & Hooks.ALL_HOOK_MASK;
        assertEq(hookFlags, flags, "Hook should have correct flags");

        console.log("Hook address mining successful");
        console.log("Hook address:", hookAddress);
        console.log("SUCCESS: Hook address mining working");
    }

    function testDeploy_HookFlagCompliance() public {
        console.log("\n=== P10 DEPLOY: Testing Hook Flag Compliance ===");

        // Test different flag combinations
        uint160 flags1 = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        uint160 flags2 = uint160(Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG);

        // Mine addresses for different flag combinations
        (address hookAddress1,) = HookMiner.find(
            owner,
            flags1,
            type(SpendSaveHook).creationCode,
            abi.encode(IPoolManager(address(manager)), storageContract)
        );

        (address hookAddress2,) = HookMiner.find(
            owner,
            flags2,
            type(SpendSaveHook).creationCode,
            abi.encode(IPoolManager(address(manager)), storageContract)
        );

        // Verify different addresses for different flags
        assertNotEq(hookAddress1, hookAddress2, "Different flags should produce different addresses");

        // Verify both addresses have correct flags (flags are in bottom 14 bits)
        uint160 hookFlags1 = uint160(hookAddress1) & Hooks.ALL_HOOK_MASK;
        uint160 hookFlags2 = uint160(hookAddress2) & Hooks.ALL_HOOK_MASK;

        assertEq(hookFlags1, flags1, "Hook 1 should have correct flags");
        assertEq(hookFlags2, flags2, "Hook 2 should have correct flags");

        console.log("Hook flag compliance working correctly");
        console.log("Hook 1 address:", hookAddress1, "Flags:", hookFlags1);
        console.log("Hook 2 address:", hookAddress2, "Flags:", hookFlags2);
        console.log("SUCCESS: Hook flag compliance working");
    }

    function testDeploy_HookInitialization() public {
        console.log("\n=== P10 DEPLOY: Testing Hook Initialization ===");

        // Deploy complete protocol
        vm.prank(owner);
        storageContract = new SpendSaveStorage(address(manager));

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

        // Initialize storage with hook
        vm.prank(owner);
        storageContract.initialize(address(hook));

        // Verify hook initialization
        assertEq(storageContract.spendSaveHook(), address(hook), "Hook should be initialized in storage");
        assertEq(address(hook.poolManager()), address(manager), "Hook should reference correct pool manager");
        assertEq(address(hook.storage_()), address(storageContract), "Hook should reference correct storage");

        console.log("Hook initialization working correctly");
        console.log("SUCCESS: Hook initialization working");
    }

    // ==================== DEPLOYMENT FAILURE RECOVERY TESTS ====================

    function testDeploy_DeploymentFailureRecovery() public {
        console.log("\n=== P10 DEPLOY: Testing Deployment Failure Recovery ===");

        // Simulate deployment failure scenarios and recovery

        // Scenario 1: Invalid pool manager address
        vm.expectRevert(SpendSaveStorage.InvalidInput.selector);
        new SpendSaveStorage(address(0));

        // Scenario 2: Invalid storage address in hook
        vm.prank(owner);
        storageContract = new SpendSaveStorage(address(manager));

        vm.expectRevert(SpendSaveHook.StorageNotInitialized.selector);
        new SpendSaveHook(IPoolManager(address(manager)), SpendSaveStorage(address(0)));

        // Scenario 3: Hook deployed at wrong address
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

        // Deploy at wrong address (without salt)
        vm.prank(owner);
        SpendSaveHook wrongHook = new SpendSaveHook(
            IPoolManager(address(manager)),
            storageContract
        );

        assertNotEq(address(wrongHook), hookAddress, "Wrong deployment should be at different address");

        // Correct deployment with salt
        vm.prank(owner);
        hook = new SpendSaveHook{salt: salt}(
            IPoolManager(address(manager)),
            storageContract
        );

        assertEq(address(hook), hookAddress, "Correct deployment should be at mined address");

        console.log("Deployment failure recovery working correctly");
        console.log("SUCCESS: Deployment failure recovery working");
    }

    function testDeploy_DeploymentStateConsistency() public {
        console.log("\n=== P10 DEPLOY: Testing Deployment State Consistency ===");

        // Deploy complete protocol
        vm.prank(owner);
        storageContract = new SpendSaveStorage(address(manager));

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

        vm.prank(owner);
        storageContract.initialize(address(hook));

        // Verify state consistency across contracts
        assertEq(storageContract.owner(), owner, "Owner should be consistent");
        assertEq(storageContract.spendSaveHook(), address(hook), "Hook reference should be consistent");
        assertEq(address(hook.poolManager()), address(manager), "Pool manager reference should be consistent");
        assertEq(address(hook.storage_()), address(storageContract), "Storage reference should be consistent");

        console.log("Deployment state consistency verified");
        console.log("SUCCESS: Deployment state consistency working");
    }

    // ==================== INTEGRATION TESTS ====================

    function testDeploy_CompleteWorkflow() public {
        console.log("\n=== P10 DEPLOY: Testing Complete Deployment Workflow ===");

        // 1. Deploy storage
        vm.prank(owner);
        storageContract = new SpendSaveStorage(address(manager));

        // 2. Deploy modules
        vm.startPrank(owner);
        savingsModule = new Savings();
        strategyModule = new SavingStrategy();
        tokenModule = new Token();
        dcaModule = new DCA();
        dailySavingsModule = new DailySavings();
        slippageModule = new SlippageControl();
        vm.stopPrank();

        // 3. Deploy hook with address mining
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

        // 4. Initialize storage
        vm.prank(owner);
        storageContract.initialize(address(hook));

        // 5. Register and initialize modules
        vm.startPrank(owner);
        storageContract.registerModule(keccak256("SAVINGS"), address(savingsModule));
        storageContract.registerModule(keccak256("STRATEGY"), address(strategyModule));
        storageContract.registerModule(keccak256("TOKEN"), address(tokenModule));
        storageContract.registerModule(keccak256("DCA"), address(dcaModule));
        storageContract.registerModule(keccak256("DAILY"), address(dailySavingsModule));
        storageContract.registerModule(keccak256("SLIPPAGE"), address(slippageModule));
        vm.stopPrank();

        vm.startPrank(owner);
        savingsModule.initialize(storageContract);
        strategyModule.initialize(storageContract);
        tokenModule.initialize(storageContract);
        dcaModule.initialize(storageContract);
        dailySavingsModule.initialize(storageContract);
        slippageModule.initialize(storageContract);

        // 6. Set cross-module references - must be called by owner
        strategyModule.setModuleReferences(
            address(strategyModule),
            address(savingsModule),
            address(dcaModule),
            address(slippageModule),
            address(tokenModule),
            address(dailySavingsModule)
        );
        vm.stopPrank();

        // 7. Initialize pool
        poolKey = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // 8. Verify complete deployment
        assertEq(storageContract.owner(), owner, "Owner should be correct");
        assertEq(storageContract.spendSaveHook(), address(hook), "Hook should be correct");
        assertEq(address(hook), hookAddress, "Hook address should match mined address");
        assertTrue(storageContract.isAuthorizedModule(address(savingsModule)), "Modules should be authorized");

        console.log("Complete deployment workflow successful");
        console.log("SUCCESS: Complete deployment workflow verified");
    }

    function testDeploy_ComprehensiveReport() public {
        console.log("\n=== P10 DEPLOY: COMPREHENSIVE REPORT ===");

        // Run all deployment tests
        testDeploy_CompleteEndToEndDeployment();
        testDeploy_DeploymentSequenceVerification();
        testDeploy_BaseMainnetConfiguration();
        testDeploy_BaseSepoliaConfiguration();
        testDeploy_NetworkSpecificModuleConfiguration();
        testDeploy_HookAddressMining();
        testDeploy_HookFlagCompliance();
        testDeploy_HookInitialization();
        testDeploy_DeploymentFailureRecovery();
        testDeploy_DeploymentStateConsistency();
        testDeploy_CompleteWorkflow();

        console.log("\n=== FINAL DEPLOYMENT RESULTS ===");
        console.log("PASS - Complete End-to-End Deployment: PASS");
        console.log("PASS - Deployment Sequence Verification: PASS");
        console.log("PASS - Base Mainnet Configuration: PASS");
        console.log("PASS - Base Sepolia Configuration: PASS");
        console.log("PASS - Network-Specific Module Configuration: PASS");
        console.log("PASS - Hook Address Mining: PASS");
        console.log("PASS - Hook Flag Compliance: PASS");
        console.log("PASS - Hook Initialization: PASS");
        console.log("PASS - Deployment Failure Recovery: PASS");
        console.log("PASS - Deployment State Consistency: PASS");
        console.log("PASS - Complete Deployment Workflow: PASS");

        console.log("\n=== DEPLOYMENT SUMMARY ===");
        console.log("Total deployment scenarios: 11");
        console.log("Scenarios passing: 11");
        console.log("Success rate: 100%");
        console.log("SUCCESS: Complete deployment functionality verified!");
    }
}

