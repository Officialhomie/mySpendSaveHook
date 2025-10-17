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
 * @title AdminFunctionsTest
 * @notice P9 ADMIN: Comprehensive testing of owner-only functions, treasury management, fee adjustments
 * @dev Tests emergency mechanisms, parameter configuration, and access control
 */
contract AdminFunctionsTest is Test, Deployers {
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
    address public treasury;
    address public unauthorizedUser;

    // Test tokens
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;

    // Pool configuration
    PoolKey public poolKey;

    // Test parameters
    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 constant INITIAL_SAVINGS = 100 ether;
    uint256 constant TREASURY_FEE = 100; // 1% fee

    // Token IDs
    uint256 public tokenAId;
    uint256 public tokenBId;
    uint256 public tokenCId;

    // Events
    event TreasuryFeeUpdated(uint256 oldFee, uint256 newFee);
    event EmergencyStop(address indexed caller, string reason);
    event ModuleRegistered(bytes32 indexed moduleId, address indexed moduleAddress);
    event ModuleAuthorizationChanged(address indexed module, bool authorized);

    function setUp() public {
        // Create test accounts
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        treasury = makeAddr("treasury");
        unauthorizedUser = makeAddr("unauthorized");

        // Deploy V4 infrastructure
        deployFreshManagerAndRouters();

        // Deploy tokens
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        tokenC = new MockERC20("Token C", "TKNC", 18);

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

        console.log("=== P9 ADMIN: TESTS SETUP COMPLETE ===");
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
        // Fund all test accounts with tokens
        address[] memory accounts = new address[](4);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = treasury;
        accounts[3] = unauthorizedUser;

        for (uint256 i = 0; i < accounts.length; i++) {
            tokenA.mint(accounts[i], INITIAL_BALANCE);
            tokenB.mint(accounts[i], INITIAL_BALANCE);
            tokenC.mint(accounts[i], INITIAL_BALANCE);
        }

        // Register tokens and get their IDs
        tokenAId = tokenModule.registerToken(address(tokenA));
        tokenBId = tokenModule.registerToken(address(tokenB));
        tokenCId = tokenModule.registerToken(address(tokenC));

        // Setup treasury
        vm.prank(owner);
        storageContract.setTreasury(treasury);

        console.log("Test accounts configured with tokens and treasury");
    }

    // ==================== OWNER-ONLY FUNCTIONS TESTS ====================

    function testAdmin_TreasuryManagement() public {
        console.log("\n=== P9 ADMIN: Testing Treasury Management ===");

        // Set treasury
        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        storageContract.setTreasury(newTreasury);

        assertEq(storageContract.treasury(), newTreasury, "Treasury should be updated");

        // Test treasury fee adjustment
        uint256 newFee = 200; // 2%
        vm.prank(owner);
        storageContract.setTreasuryFee(newFee);

        assertEq(storageContract.treasuryFee(), newFee, "Treasury fee should be updated");

        console.log("Treasury management working correctly");
        console.log("SUCCESS: Treasury management working");
    }

    function testAdmin_TreasuryManagementUnauthorized() public {
        console.log("\n=== P9 ADMIN: Testing Treasury Management Unauthorized ===");

        address newTreasury = makeAddr("newTreasury");

        // Unauthorized user tries to set treasury
        vm.prank(unauthorizedUser);
        vm.expectRevert("Ownable: caller is not the owner");
        storageContract.setTreasury(newTreasury);

        // Unauthorized user tries to set treasury fee
        vm.prank(unauthorizedUser);
        vm.expectRevert("Ownable: caller is not the owner");
        storageContract.setTreasuryFee(200);

        console.log("SUCCESS: Treasury management authorization working");
    }

    function testAdmin_FeeCollectionAndDistribution() public {
        console.log("\n=== P9 ADMIN: Testing Fee Collection and Distribution ===");

        // Setup user with savings strategy
        vm.prank(alice);
        strategyModule.setSavingStrategy(
            alice,
            2000, // 20% savings
            0,
            10000,
            false,
            SpendSaveStorage.SavingsTokenType.INPUT,
            address(0)
        );

        // Process savings to generate fees
        uint256 swapAmount = 100 ether;
        SpendSaveStorage.SwapContext memory context;
        context.inputAmount = swapAmount;
        context.inputToken = address(tokenA);
        context.user = alice;

        vm.prank(address(savingsModule));
        savingsModule.processSavings(alice, address(tokenA), 20 ether, context);

        // Check treasury balance
        uint256 treasuryBalanceBefore = tokenA.balanceOf(treasury);
        uint256 expectedFee = (20 ether * TREASURY_FEE) / 10000; // 1% of 20 ether

        // Treasury should have received fees
        uint256 treasuryBalanceAfter = tokenA.balanceOf(treasury);
        assertEq(treasuryBalanceAfter, treasuryBalanceBefore + expectedFee, "Treasury should receive fees");

        console.log("Fee collection and distribution working correctly");
        console.log("Fee collected:", expectedFee);
        console.log("SUCCESS: Fee collection and distribution working");
    }

    // ==================== EMERGENCY MECHANISMS TESTS ====================

    function testAdmin_EmergencyStop() public {
        console.log("\n=== P9 ADMIN: Testing Emergency Stop ===");

        // Owner activates emergency stop
        vm.prank(owner);
        storageContract.emergencyPause();

        // Verify emergency stop is active
        assertTrue(storageContract.emergencyStopped(), "Emergency stop should be active");

        // Try to perform operations that should be blocked
        vm.prank(alice);
        vm.expectRevert("Emergency stopped");
        strategyModule.setSavingStrategy(
            alice,
            2000,
            0,
            10000,
            false,
            SpendSaveStorage.SavingsTokenType.INPUT,
            address(0)
        );

        // Owner deactivates emergency stop
        vm.prank(owner);
        storageContract.emergencyUnpause();

        // Verify emergency stop is deactivated
        assertFalse(storageContract.emergencyStopped(), "Emergency stop should be deactivated");

        // Operations should work now
        vm.prank(alice);
        strategyModule.setSavingStrategy(
            alice,
            2000,
            0,
            10000,
            false,
            SpendSaveStorage.SavingsTokenType.INPUT,
            address(0)
        );

        console.log("Emergency stop mechanism working correctly");
        console.log("SUCCESS: Emergency stop working");
    }

    function testAdmin_EmergencyStopUnauthorized() public {
        console.log("\n=== P9 ADMIN: Testing Emergency Stop Unauthorized ===");

        // Unauthorized user tries to activate emergency stop
        vm.prank(unauthorizedUser);
        vm.expectRevert("Ownable: caller is not the owner");
        storageContract.emergencyPause();

        // Unauthorized user tries to deactivate emergency stop
        vm.prank(unauthorizedUser);
        vm.expectRevert("Ownable: caller is not the owner");
        storageContract.emergencyUnpause();

        console.log("SUCCESS: Emergency stop authorization working");
    }

    function testAdmin_StrategyDisable() public {
        console.log("\n=== P9 ADMIN: Testing Strategy Disable ===");

        // Setup user strategy
        vm.prank(alice);
        strategyModule.setSavingStrategy(
            alice,
            2000,
            0,
            10000,
            false,
            SpendSaveStorage.SavingsTokenType.INPUT,
            address(0)
        );

        // Verify strategy is active
        (uint256 percentage,,,) = storageContract.getPackedUserConfig(alice);
        assertEq(percentage, 2000, "Strategy should be active");

        // Owner disables strategy
        vm.prank(owner);
        storageContract.disableUserStrategy(alice);

        // Verify strategy is disabled
        (percentage,,,) = storageContract.getPackedUserConfig(alice);
        assertEq(percentage, 0, "Strategy should be disabled");

        console.log("Strategy disable working correctly");
        console.log("SUCCESS: Strategy disable working");
    }

    function testAdmin_StrategyDisableUnauthorized() public {
        console.log("\n=== P9 ADMIN: Testing Strategy Disable Unauthorized ===");

        // Unauthorized user tries to disable strategy
        vm.prank(unauthorizedUser);
        vm.expectRevert("Ownable: caller is not the owner");
        storageContract.disableUserStrategy(alice);

        console.log("SUCCESS: Strategy disable authorization working");
    }

    // ==================== PARAMETER CONFIGURATION TESTS ====================

    function testAdmin_ParameterConfiguration() public {
        console.log("\n=== P9 ADMIN: Testing Parameter Configuration ===");

        // Configure slippage tolerance
        vm.prank(owner);
        storageContract.setUserSlippageTolerance(alice, 300); // 3%

        assertEq(storageContract.userSlippageTolerance(alice), 300, "Slippage tolerance should be set");

        // Configure token-specific slippage
        vm.prank(owner);
        storageContract.setTokenSlippageTolerance(alice, address(tokenA), 500); // 5%

        assertEq(storageContract.tokenSlippageTolerance(alice, address(tokenA)), 500, "Token slippage should be set");

        // Configure percentage limits
        vm.prank(owner);
        storageContract.setMaxSavingsPercentage(8000); // 80%

        assertEq(storageContract.maxSavingsPercentage(), 8000, "Max savings percentage should be set");

        console.log("Parameter configuration working correctly");
        console.log("SUCCESS: Parameter configuration working");
    }

    function testAdmin_ParameterConfigurationUnauthorized() public {
        console.log("\n=== P9 ADMIN: Testing Parameter Configuration Unauthorized ===");

        // Unauthorized user tries to configure parameters
        vm.prank(unauthorizedUser);
        vm.expectRevert("Ownable: caller is not the owner");
        storageContract.setUserSlippageTolerance(alice, 300);

        vm.prank(unauthorizedUser);
        vm.expectRevert("Ownable: caller is not the owner");
        storageContract.setTokenSlippageTolerance(alice, address(tokenA), 500);

        vm.prank(unauthorizedUser);
        vm.expectRevert("Ownable: caller is not the owner");
        storageContract.setMaxSavingsPercentage(8000);

        console.log("SUCCESS: Parameter configuration authorization working");
    }

    function testAdmin_ParameterValidation() public {
        console.log("\n=== P9 ADMIN: Testing Parameter Validation ===");

        // Test invalid slippage tolerance (too high)
        vm.prank(owner);
        vm.expectRevert("Invalid slippage tolerance");
        storageContract.setUserSlippageTolerance(alice, 10000); // 100% - too high

        // Test invalid max savings percentage (too high)
        vm.prank(owner);
        vm.expectRevert("Invalid max savings percentage");
        storageContract.setMaxSavingsPercentage(15000); // 150% - too high

        console.log("SUCCESS: Parameter validation working");
    }

    // ==================== ACCESS CONTROL TESTS ====================

    function testAdmin_ModuleAuthorization() public {
        console.log("\n=== P9 ADMIN: Testing Module Authorization ===");

        // Verify modules are authorized
        assertTrue(storageContract.isAuthorizedModule(address(savingsModule)), "Savings module should be authorized");
        assertTrue(storageContract.isAuthorizedModule(address(strategyModule)), "Strategy module should be authorized");
        assertTrue(storageContract.isAuthorizedModule(address(tokenModule)), "Token module should be authorized");

        // Owner can authorize new modules
        address newModule = makeAddr("newModule");
        vm.prank(owner);
        storageContract.registerModule(keccak256("NEW_MODULE"), newModule);

        assertTrue(storageContract.isAuthorizedModule(newModule), "New module should be authorized");

        // Owner can revoke authorization
        vm.prank(owner);
        storageContract.revokeModuleAuthorization(newModule);

        assertFalse(storageContract.isAuthorizedModule(newModule), "New module should be unauthorized");

        console.log("Module authorization working correctly");
        console.log("SUCCESS: Module authorization working");
    }

    function testAdmin_ModuleAuthorizationUnauthorized() public {
        console.log("\n=== P9 ADMIN: Testing Module Authorization Unauthorized ===");

        address newModule = makeAddr("newModule");

        // Unauthorized user tries to register module
        vm.prank(unauthorizedUser);
        vm.expectRevert("Ownable: caller is not the owner");
        storageContract.registerModule(keccak256("UNAUTHORIZED_MODULE"), newModule);

        // Unauthorized user tries to revoke authorization
        vm.prank(unauthorizedUser);
        vm.expectRevert("Ownable: caller is not the owner");
        storageContract.revokeModuleAuthorization(address(savingsModule));

        console.log("SUCCESS: Module authorization access control working");
    }

    function testAdmin_OwnershipTransfer() public {
        console.log("\n=== P9 ADMIN: Testing Ownership Transfer ===");

        address newOwner = makeAddr("newOwner");

        // Owner initiates ownership transfer
        vm.prank(owner);
        storageContract.transferOwnership(newOwner);

        // New owner accepts ownership
        vm.prank(newOwner);
        storageContract.acceptOwnership();

        // Verify ownership transfer
        assertEq(storageContract.owner(), newOwner, "Ownership should be transferred");

        // New owner should be able to perform admin functions
        vm.prank(newOwner);
        storageContract.setTreasuryFee(150);

        assertEq(storageContract.treasuryFee(), 150, "New owner should be able to set treasury fee");

        console.log("Ownership transfer working correctly");
        console.log("SUCCESS: Ownership transfer working");
    }

    function testAdmin_OwnershipTransferUnauthorized() public {
        console.log("\n=== P9 ADMIN: Testing Ownership Transfer Unauthorized ===");

        address newOwner = makeAddr("newOwner");

        // Unauthorized user tries to transfer ownership
        vm.prank(unauthorizedUser);
        vm.expectRevert("Ownable: caller is not the owner");
        storageContract.transferOwnership(newOwner);

        // Unauthorized user tries to accept ownership
        vm.prank(unauthorizedUser);
        vm.expectRevert("Ownable: caller is not the owner");
        storageContract.acceptOwnership();

        console.log("SUCCESS: Ownership transfer authorization working");
    }

    // ==================== INTEGRATION TESTS ====================

    function testAdmin_CompleteWorkflow() public {
        console.log("\n=== P9 ADMIN: Testing Complete Admin Workflow ===");

        // 1. Setup initial configuration
        vm.prank(owner);
        storageContract.setTreasuryFee(200); // 2%

        vm.prank(owner);
        storageContract.setMaxSavingsPercentage(9000); // 90%

        // 2. Configure user parameters
        vm.prank(owner);
        storageContract.setUserSlippageTolerance(alice, 250); // 2.5%

        // 3. Setup user strategy
        vm.prank(alice);
        strategyModule.setSavingStrategy(
            alice,
            2000,
            0,
            10000,
            false,
            SpendSaveStorage.SavingsTokenType.INPUT,
            address(0)
        );

        // 4. Process savings to generate fees
        SpendSaveStorage.SwapContext memory context;
        context.inputAmount = 100 ether;
        context.inputToken = address(tokenA);
        context.user = alice;

        vm.prank(address(savingsModule));
        savingsModule.processSavings(alice, address(tokenA), 20 ether, context);

        // 5. Verify treasury received fees
        uint256 expectedFee = (20 ether * 200) / 10000; // 2% of 20 ether
        assertEq(tokenA.balanceOf(treasury), expectedFee, "Treasury should receive correct fees");

        // 6. Test emergency mechanisms
        vm.prank(owner);
        storageContract.emergencyPause();

        // Operations should be blocked
        vm.prank(alice);
        vm.expectRevert("Emergency stopped");
        strategyModule.setSavingStrategy(
            alice,
            3000,
            0,
            10000,
            false,
            SpendSaveStorage.SavingsTokenType.INPUT,
            address(0)
        );

        // 7. Deactivate emergency and test normal operation
        vm.prank(owner);
        storageContract.emergencyUnpause();

        vm.prank(alice);
        strategyModule.setSavingStrategy(
            alice,
            3000,
            0,
            10000,
            false,
            SpendSaveStorage.SavingsTokenType.INPUT,
            address(0)
        );

        console.log("Complete admin workflow successful");
        console.log("SUCCESS: Complete admin workflow verified");
    }

    function testAdmin_ComprehensiveReport() public {
        console.log("\n=== P9 ADMIN: COMPREHENSIVE REPORT ===");

        // Run all admin tests
        testAdmin_TreasuryManagement();
        testAdmin_TreasuryManagementUnauthorized();
        testAdmin_FeeCollectionAndDistribution();
        testAdmin_EmergencyStop();
        testAdmin_EmergencyStopUnauthorized();
        testAdmin_StrategyDisable();
        testAdmin_StrategyDisableUnauthorized();
        testAdmin_ParameterConfiguration();
        testAdmin_ParameterConfigurationUnauthorized();
        testAdmin_ParameterValidation();
        testAdmin_ModuleAuthorization();
        testAdmin_ModuleAuthorizationUnauthorized();
        testAdmin_OwnershipTransfer();
        testAdmin_OwnershipTransferUnauthorized();
        testAdmin_CompleteWorkflow();

        console.log("\n=== FINAL ADMIN RESULTS ===");
        console.log("PASS - Treasury Management: PASS");
        console.log("PASS - Treasury Management Unauthorized: PASS");
        console.log("PASS - Fee Collection and Distribution: PASS");
        console.log("PASS - Emergency Stop: PASS");
        console.log("PASS - Emergency Stop Unauthorized: PASS");
        console.log("PASS - Strategy Disable: PASS");
        console.log("PASS - Strategy Disable Unauthorized: PASS");
        console.log("PASS - Parameter Configuration: PASS");
        console.log("PASS - Parameter Configuration Unauthorized: PASS");
        console.log("PASS - Parameter Validation: PASS");
        console.log("PASS - Module Authorization: PASS");
        console.log("PASS - Module Authorization Unauthorized: PASS");
        console.log("PASS - Ownership Transfer: PASS");
        console.log("PASS - Ownership Transfer Unauthorized: PASS");
        console.log("PASS - Complete Admin Workflow: PASS");

        console.log("\n=== ADMIN SUMMARY ===");
        console.log("Total admin scenarios: 15");
        console.log("Scenarios passing: 15");
        console.log("Success rate: 100%");
        console.log("SUCCESS: Complete admin functionality verified!");
    }
}

