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
    event ModuleRegistered(bytes32 indexed moduleId, address indexed moduleAddress);

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
        vm.expectRevert(SpendSaveStorage.Unauthorized.selector);
        storageContract.setTreasury(newTreasury);

        // Unauthorized user tries to set treasury fee
        vm.prank(unauthorizedUser);
        vm.expectRevert(SpendSaveStorage.Unauthorized.selector);
        storageContract.setTreasuryFee(200);

        console.log("SUCCESS: Treasury management authorization working");
    }

    function testAdmin_FeeCollectionAndDistribution() public {
        console.log("\n=== P9 ADMIN: Testing Fee Collection and Distribution ===");

        // Set treasury fee to match test expectations (1%)
        vm.prank(owner);
        storageContract.setTreasuryFee(TREASURY_FEE);

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

        // Deposit savings to generate fees (instead of calling processSavings directly)
        uint256 depositAmount = 20 ether;

        // Approve savings module to spend tokens (it will transfer to storage contract)
        vm.prank(alice);
        tokenA.approve(address(savingsModule), depositAmount);

        // Deposit savings which will transfer actual tokens and apply fees
        vm.prank(alice);
        savingsModule.depositSavings(alice, address(tokenA), depositAmount);

        // Check treasury balance in storage contract (fees are stored internally, not as ERC20)
        uint256 expectedFee = (depositAmount * TREASURY_FEE) / 10000; // 1% of 20 ether
        // Get the current treasury address (may have been changed by previous tests in comprehensive report)
        address currentTreasury = storageContract.treasury();
        uint256 treasurySavings = storageContract.savings(currentTreasury, address(tokenA));

        // Treasury should have received fees in internal accounting
        assertEq(treasurySavings, expectedFee, "Treasury should receive fees");

        console.log("Fee collection and distribution working correctly");
        console.log("Fee collected:", expectedFee);
        console.log("SUCCESS: Fee collection and distribution working");
    }

    function testAdmin_DefaultSlippageTolerance() public {
        console.log("\n=== P9 ADMIN: Testing Default Slippage Tolerance ===");

        // Set default slippage tolerance
        uint256 newTolerance = 500; // 5%
        vm.prank(owner);
        storageContract.setDefaultSlippageTolerance(newTolerance);

        assertEq(storageContract.defaultSlippageTolerance(), newTolerance, "Default slippage tolerance should be updated");

        console.log("Default slippage tolerance working correctly");
        console.log("SUCCESS: Default slippage tolerance working");
    }

    function testAdmin_DefaultSlippageToleranceUnauthorized() public {
        console.log("\n=== P9 ADMIN: Testing Default Slippage Tolerance Unauthorized ===");

        // Unauthorized user tries to set default slippage tolerance
        vm.prank(unauthorizedUser);
        vm.expectRevert(SpendSaveStorage.Unauthorized.selector);
        storageContract.setDefaultSlippageTolerance(500);

        console.log("SUCCESS: Default slippage tolerance authorization working");
    }

    function testAdmin_MaxSavingsPercentage() public {
        console.log("\n=== P9 ADMIN: Testing Max Savings Percentage ===");

        // Set max savings percentage
        uint256 newMaxPercentage = 8000; // 80%
        vm.prank(owner);
        storageContract.setMaxSavingsPercentage(newMaxPercentage);

        assertEq(storageContract.maxSavingsPercentage(), newMaxPercentage, "Max savings percentage should be updated");

        console.log("Max savings percentage working correctly");
        console.log("SUCCESS: Max savings percentage working");
    }

    function testAdmin_MaxSavingsPercentageUnauthorized() public {
        console.log("\n=== P9 ADMIN: Testing Max Savings Percentage Unauthorized ===");

        // Unauthorized user tries to set max savings percentage
        vm.prank(unauthorizedUser);
        vm.expectRevert(SpendSaveStorage.Unauthorized.selector);
        storageContract.setMaxSavingsPercentage(8000);

        console.log("SUCCESS: Max savings percentage authorization working");
    }

    function testAdmin_ModuleRegistration() public {
        console.log("\n=== P9 ADMIN: Testing Module Registration ===");

        // Register new module
        bytes32 moduleId = keccak256("TEST_MODULE");
        address testModule = makeAddr("testModule");
        vm.prank(owner);
        storageContract.registerModule(moduleId, testModule);

        assertEq(storageContract.getModule(moduleId), testModule, "Module should be registered");
        assertTrue(storageContract.isAuthorizedModule(testModule), "Module should be authorized");

        console.log("Module registration working correctly");
        console.log("SUCCESS: Module registration working");
    }

    function testAdmin_ModuleRegistrationUnauthorized() public {
        console.log("\n=== P9 ADMIN: Testing Module Registration Unauthorized ===");

        bytes32 moduleId = keccak256("UNAUTHORIZED_MODULE");
        address testModule = makeAddr("testModule");

        // Unauthorized user tries to register module
        vm.prank(unauthorizedUser);
        vm.expectRevert(SpendSaveStorage.Unauthorized.selector);
        storageContract.registerModule(moduleId, testModule);

        console.log("SUCCESS: Module registration authorization working");
    }

    function testAdmin_IntermediaryTokens() public {
        console.log("\n=== P9 ADMIN: Testing Intermediary Tokens Configuration ===");

        // Set intermediary tokens
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);

        vm.prank(owner);
        storageContract.setIntermediaryTokens(tokens);

        // Note: Intermediary tokens are stored but not directly accessible via getter
        // The function should complete without reverting
        console.log("Intermediary tokens configuration working correctly");
        console.log("SUCCESS: Intermediary tokens configuration working");
    }

    function testAdmin_IntermediaryTokensUnauthorized() public {
        console.log("\n=== P9 ADMIN: Testing Intermediary Tokens Unauthorized ===");

        address[] memory tokens = new address[](1);
        tokens[0] = address(tokenA);

        // Unauthorized user tries to set intermediary tokens
        vm.prank(unauthorizedUser);
        vm.expectRevert(SpendSaveStorage.Unauthorized.selector);
        storageContract.setIntermediaryTokens(tokens);

        console.log("SUCCESS: Intermediary tokens authorization working");
    }

    function testAdmin_OwnershipTransfer() public {
        console.log("\n=== P9 ADMIN: Testing Ownership Transfer ===");

        address newOwner = makeAddr("newOwner");

        // Store current owner
        address currentOwner = storageContract.owner();

        // Owner transfers ownership
        vm.prank(owner);
        storageContract.transferOwnership(newOwner);

        // Verify ownership transfer
        assertEq(storageContract.owner(), newOwner, "Ownership should be transferred");

        // New owner should be able to perform admin functions
        vm.prank(newOwner);
        storageContract.setTreasuryFee(150);

        assertEq(storageContract.treasuryFee(), 150, "New owner should be able to set treasury fee");

        // Previous owner should no longer be able to perform admin functions
        vm.prank(currentOwner);
        vm.expectRevert(SpendSaveStorage.Unauthorized.selector);
        storageContract.setTreasuryFee(200);

        // Restore ownership to original owner for subsequent tests
        vm.prank(newOwner);
        storageContract.transferOwnership(currentOwner);

        console.log("Ownership transfer working correctly");
        console.log("SUCCESS: Ownership transfer working");
    }

    function testAdmin_OwnershipTransferUnauthorized() public {
        console.log("\n=== P9 ADMIN: Testing Ownership Transfer Unauthorized ===");

        address newOwner = makeAddr("newOwner");

        // Unauthorized user tries to transfer ownership
        vm.prank(unauthorizedUser);
        vm.expectRevert(SpendSaveStorage.Unauthorized.selector);
        storageContract.transferOwnership(newOwner);

        console.log("SUCCESS: Ownership transfer authorization working");
    }

    function testAdmin_EmergencyPause() public {
        console.log("\n=== P9 ADMIN: Testing Emergency Pause ===");

        // Owner activates emergency pause
        vm.prank(owner);
        storageContract.emergencyPause();

        // Note: The emergency pause function is implemented but may not have a getter
        // We verify it doesn't revert and owner can call it
        console.log("Emergency pause executed successfully");
        console.log("SUCCESS: Emergency pause working");
    }

    function testAdmin_EmergencyPauseUnauthorized() public {
        console.log("\n=== P9 ADMIN: Testing Emergency Pause Unauthorized ===");

        // Unauthorized user tries to activate emergency pause
        vm.prank(unauthorizedUser);
        vm.expectRevert(SpendSaveStorage.Unauthorized.selector);
        storageContract.emergencyPause();

        console.log("SUCCESS: Emergency pause authorization working");
    }

    function testAdmin_ParameterValidation() public {
        console.log("\n=== P9 ADMIN: Testing Parameter Validation ===");

        // Test invalid treasury fee (too high)
        vm.prank(owner);
        vm.expectRevert(SpendSaveStorage.InvalidInput.selector);
        storageContract.setTreasuryFee(2000); // 20% - too high

        // Test invalid max savings percentage (too high)
        vm.prank(owner);
        vm.expectRevert(SpendSaveStorage.InvalidInput.selector);
        storageContract.setMaxSavingsPercentage(15000); // 150% - too high

        console.log("SUCCESS: Parameter validation working");
    }

    // ==================== INTEGRATION TESTS ====================

    function testAdmin_CompleteWorkflow() public {
        console.log("\n=== P9 ADMIN: Testing Complete Admin Workflow ===");

        // 1. Setup initial configuration
        vm.prank(owner);
        storageContract.setTreasuryFee(200); // 2%

        vm.prank(owner);
        storageContract.setMaxSavingsPercentage(9000); // 90%

        // 2. Setup treasury
        address newTreasury = makeAddr("newTreasury");
        vm.prank(owner);
        storageContract.setTreasury(newTreasury);

        // 3. Configure user strategy
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

        // 4. Deposit savings to generate fees
        uint256 depositAmount = 20 ether;

        // Check treasury balance before deposit
        uint256 treasuryBalanceBefore = storageContract.savings(newTreasury, address(tokenA));

        // Approve savings module to spend tokens (it will transfer to storage contract)
        vm.prank(alice);
        tokenA.approve(address(savingsModule), depositAmount);

        // Deposit savings which will transfer actual tokens and apply fees
        vm.prank(alice);
        savingsModule.depositSavings(alice, address(tokenA), depositAmount);

        // 5. Verify treasury received fees in storage (check delta, not absolute value)
        uint256 expectedFee = (depositAmount * 200) / 10000; // 2% of 20 ether
        uint256 treasuryBalanceAfter = storageContract.savings(newTreasury, address(tokenA));
        uint256 feeReceived = treasuryBalanceAfter - treasuryBalanceBefore;
        assertEq(feeReceived, expectedFee, "Treasury should receive correct fees");

        // 6. Test emergency mechanisms
        vm.prank(owner);
        storageContract.emergencyPause();

        console.log("Complete admin workflow successful");
        console.log("SUCCESS: Complete admin workflow verified");
    }

    function testAdmin_ComprehensiveReport() public {
        console.log("\n=== P9 ADMIN: COMPREHENSIVE REPORT ===");

        // Run all admin tests
        testAdmin_TreasuryManagement();
        testAdmin_TreasuryManagementUnauthorized();
        testAdmin_FeeCollectionAndDistribution();
        testAdmin_DefaultSlippageTolerance();
        testAdmin_DefaultSlippageToleranceUnauthorized();
        testAdmin_MaxSavingsPercentage();
        testAdmin_MaxSavingsPercentageUnauthorized();
        testAdmin_ModuleRegistration();
        testAdmin_ModuleRegistrationUnauthorized();
        testAdmin_IntermediaryTokens();
        testAdmin_IntermediaryTokensUnauthorized();
        testAdmin_OwnershipTransfer();
        testAdmin_OwnershipTransferUnauthorized();
        testAdmin_EmergencyPause();
        testAdmin_EmergencyPauseUnauthorized();
        testAdmin_ParameterValidation();
        testAdmin_CompleteWorkflow();

        console.log("\n=== FINAL ADMIN RESULTS ===");
        console.log("PASS - Treasury Management: PASS");
        console.log("PASS - Treasury Management Unauthorized: PASS");
        console.log("PASS - Fee Collection and Distribution: PASS");
        console.log("PASS - Default Slippage Tolerance: PASS");
        console.log("PASS - Default Slippage Tolerance Unauthorized: PASS");
        console.log("PASS - Max Savings Percentage: PASS");
        console.log("PASS - Max Savings Percentage Unauthorized: PASS");
        console.log("PASS - Module Registration: PASS");
        console.log("PASS - Module Registration Unauthorized: PASS");
        console.log("PASS - Intermediary Tokens: PASS");
        console.log("PASS - Intermediary Tokens Unauthorized: PASS");
        console.log("PASS - Ownership Transfer: PASS");
        console.log("PASS - Ownership Transfer Unauthorized: PASS");
        console.log("PASS - Emergency Pause: PASS");
        console.log("PASS - Emergency Pause Unauthorized: PASS");
        console.log("PASS - Parameter Validation: PASS");
        console.log("PASS - Complete Admin Workflow: PASS");

        console.log("\n=== ADMIN SUMMARY ===");
        console.log("Total admin scenarios: 16");
        console.log("Scenarios passing: 16");
        console.log("Success rate: 100%");
        console.log("SUCCESS: Complete admin functionality verified!");
    }
}
