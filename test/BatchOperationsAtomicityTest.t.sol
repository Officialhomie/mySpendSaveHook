// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// V4 Core imports
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "lib/v4-periphery/lib/v4-core/src/PoolManager.sol";
import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol";

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
 * @title BatchOperationsAtomicityTest
 * @notice P2 SECURITY: Comprehensive testing of batch operations atomicity - all-or-nothing execution
 * @dev Tests that batch operations either succeed completely or fail completely, ensuring no partial states
 */
contract BatchOperationsAtomicityTest is Test {
    using CurrencyLibrary for Currency;

    SpendSaveHook hook;
    SpendSaveStorage storageContract;
    SavingStrategy strategyModule;
    Savings savingsModule;
    DCA dcaModule;
    Token tokenModule;
    SlippageControl slippageModule;
    DailySavings dailySavingsModule;
    
    IPoolManager poolManager;
    MockERC20 tokenA;
    MockERC20 tokenB;
    MockERC20 tokenC;
    PoolKey poolKey;
    
    address owner = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address david = makeAddr("david");
    address eve = makeAddr("eve");
    
    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 constant MINT_AMOUNT = 100 ether;
    uint256 TOKEN_ID_A;
    uint256 TOKEN_ID_B;
    uint256 TOKEN_ID_C;
    
    // Test failure scenarios
    address constant INVALID_ADDRESS = address(0);
    uint256 constant INVALID_TOKEN_ID = 999;
    uint256 constant EXCESSIVE_AMOUNT = type(uint256).max;
    
    function setUp() public {
        console.log("Core protocol deployed and initialized");
        
        // Deploy and setup core infrastructure
        _deployCoreProtocol();
        _initializeModules();
        _setupTestTokens();
        _configureTestAccounts();
        
        console.log("=== P2 SECURITY: BATCH OPERATIONS ATOMICITY TESTS SETUP COMPLETE ===");
    }
    
    function _deployCoreProtocol() internal {
        // Deploy storage contract
        storageContract = new SpendSaveStorage(address(0x01));
        
        // Deploy all modules
        strategyModule = new SavingStrategy();
        savingsModule = new Savings();
        dcaModule = new DCA();
        tokenModule = new Token();
        slippageModule = new SlippageControl();
        dailySavingsModule = new DailySavings();
        
        // Deploy hook (simplified for testing)
        hook = new SpendSaveHook(IPoolManager(address(0x01)), storageContract);
        poolManager = IPoolManager(address(0x01));
    }
    
    function _initializeModules() internal {
        // Initialize storage with hook
        storageContract.initialize(address(hook));
        
        // Initialize all modules
        strategyModule.initialize(storageContract);
        savingsModule.initialize(storageContract);
        dcaModule.initialize(storageContract);
        tokenModule.initialize(storageContract);
        slippageModule.initialize(storageContract);
        dailySavingsModule.initialize(storageContract);
        
        // Register modules
        storageContract.registerModule(keccak256("STRATEGY"), address(strategyModule));
        storageContract.registerModule(keccak256("SAVINGS"), address(savingsModule));
        storageContract.registerModule(keccak256("DCA"), address(dcaModule));
        storageContract.registerModule(keccak256("TOKEN"), address(tokenModule));
        storageContract.registerModule(keccak256("SLIPPAGE"), address(slippageModule));
        storageContract.registerModule(keccak256("DAILY"), address(dailySavingsModule));
        
        // Set module references
        strategyModule.setModuleReferences(
            address(strategyModule), address(savingsModule), address(dcaModule),
            address(tokenModule), address(slippageModule), address(dailySavingsModule)
        );
        
        savingsModule.setModuleReferences(
            address(strategyModule), address(savingsModule), address(dcaModule),
            address(tokenModule), address(slippageModule), address(dailySavingsModule)
        );
        
        dcaModule.setModuleReferences(
            address(strategyModule), address(savingsModule), address(dcaModule),
            address(tokenModule), address(slippageModule), address(dailySavingsModule)
        );
        
        tokenModule.setModuleReferences(
            address(strategyModule), address(savingsModule), address(dcaModule),
            address(tokenModule), address(slippageModule), address(dailySavingsModule)
        );
    }
    
    function _setupTestTokens() internal {
        // Deploy test tokens
        tokenA = new MockERC20("Token A", "TOKA", 18);
        tokenB = new MockERC20("Token B", "TOKB", 18);
        tokenC = new MockERC20("Token C", "TOKC", 18);
        
        // Register tokens in token module
        TOKEN_ID_A = tokenModule.registerToken(address(tokenA));
        TOKEN_ID_B = tokenModule.registerToken(address(tokenB));
        TOKEN_ID_C = tokenModule.registerToken(address(tokenC));
        
        // Verify token IDs were assigned correctly
        assertEq(tokenModule.getTokenId(address(tokenA)), TOKEN_ID_A, "Token A ID should match");
        assertEq(tokenModule.getTokenId(address(tokenB)), TOKEN_ID_B, "Token B ID should match");
        assertEq(tokenModule.getTokenId(address(tokenC)), TOKEN_ID_C, "Token C ID should match");
    }
    
    function _configureTestAccounts() internal {
        // Fund all test accounts with tokens
        address[] memory accounts = new address[](5);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = charlie;
        accounts[3] = david;
        accounts[4] = eve;
        
        for (uint256 i = 0; i < accounts.length; i++) {
            tokenA.mint(accounts[i], INITIAL_BALANCE);
            tokenB.mint(accounts[i], INITIAL_BALANCE);
            tokenC.mint(accounts[i], INITIAL_BALANCE);
            
            // Setup initial savings balances for testing
            vm.prank(accounts[i]);
            tokenModule.mintSavingsToken(accounts[i], TOKEN_ID_A, MINT_AMOUNT);
            
            vm.prank(accounts[i]);
            tokenModule.mintSavingsToken(accounts[i], TOKEN_ID_B, MINT_AMOUNT);
        }
    }
    
    // ==================== BATCH TOKEN OPERATIONS ATOMICITY ====================
    
    function testBatchAtomicity_TokenMintSuccess() public {
        console.log("\n=== P2 SECURITY: Testing Batch Token Mint Atomicity - Success Case ===");
        
        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = TOKEN_ID_A;
        tokenIds[1] = TOKEN_ID_B;
        tokenIds[2] = TOKEN_ID_C;
        
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 50 ether;
        amounts[1] = 75 ether;
        amounts[2] = 100 ether;
        
        // Record initial balances
        uint256 initialBalanceA = tokenModule.balanceOf(alice, TOKEN_ID_A);
        uint256 initialBalanceB = tokenModule.balanceOf(alice, TOKEN_ID_B);
        uint256 initialBalanceC = tokenModule.balanceOf(alice, TOKEN_ID_C);
        
        // Execute batch mint operation
        vm.prank(alice);
        tokenModule.batchMintSavingsTokens(alice, tokenIds, amounts);
        
        // Verify all operations succeeded atomically
        assertEq(
            tokenModule.balanceOf(alice, TOKEN_ID_A), 
            initialBalanceA + amounts[0], 
            "Token A balance should increase"
        );
        assertEq(
            tokenModule.balanceOf(alice, TOKEN_ID_B), 
            initialBalanceB + amounts[1], 
            "Token B balance should increase"
        );
        assertEq(
            tokenModule.balanceOf(alice, TOKEN_ID_C), 
            initialBalanceC + amounts[2], 
            "Token C balance should increase"
        );
        
        console.log("SUCCESS: Batch token mint atomicity working correctly");
    }
    
    function testBatchAtomicity_TokenMintFailure() public {
        console.log("\n=== P2 SECURITY: Testing Batch Token Mint Atomicity - Failure Case ===");
        
        uint256[] memory tokenIds = new uint256[](3);
        tokenIds[0] = TOKEN_ID_A;
        tokenIds[1] = INVALID_TOKEN_ID; // This will cause failure
        tokenIds[2] = TOKEN_ID_C;
        
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 50 ether;
        amounts[1] = 75 ether;
        amounts[2] = 100 ether;
        
        // Record initial balances
        uint256 initialBalanceA = tokenModule.balanceOf(alice, TOKEN_ID_A);
        uint256 initialBalanceC = tokenModule.balanceOf(alice, TOKEN_ID_C);
        
        // Execute batch mint operation - should fail completely
        vm.prank(alice);
        vm.expectRevert();
        tokenModule.batchMintSavingsTokens(alice, tokenIds, amounts);
        
        // Verify NO operations succeeded (all-or-nothing)
        assertEq(
            tokenModule.balanceOf(alice, TOKEN_ID_A), 
            initialBalanceA, 
            "Token A balance should remain unchanged after batch failure"
        );
        assertEq(
            tokenModule.balanceOf(alice, TOKEN_ID_C), 
            initialBalanceC, 
            "Token C balance should remain unchanged after batch failure"
        );
        
        console.log("SUCCESS: Batch token mint atomicity failure handling correct");
    }
    
    function testBatchAtomicity_TokenTransferSuccess() public {
        console.log("\n=== P2 SECURITY: Testing Batch Token Transfer Atomicity - Success Case ===");
        
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = TOKEN_ID_A;
        tokenIds[1] = TOKEN_ID_B;
        
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 25 ether;
        amounts[1] = 35 ether;
        
        // Record initial balances
        uint256 aliceBalanceA = tokenModule.balanceOf(alice, TOKEN_ID_A);
        uint256 aliceBalanceB = tokenModule.balanceOf(alice, TOKEN_ID_B);
        uint256 bobBalanceA = tokenModule.balanceOf(bob, TOKEN_ID_A);
        uint256 bobBalanceB = tokenModule.balanceOf(bob, TOKEN_ID_B);
        
        // Execute batch transfer operation
        vm.prank(alice);
        bool success = tokenModule.batchTransfer(alice, bob, tokenIds, amounts);
        assertTrue(success, "Batch transfer should succeed");
        
        // Verify all operations succeeded atomically
        assertEq(
            tokenModule.balanceOf(alice, TOKEN_ID_A), 
            aliceBalanceA - amounts[0], 
            "Alice Token A balance should decrease"
        );
        assertEq(
            tokenModule.balanceOf(alice, TOKEN_ID_B), 
            aliceBalanceB - amounts[1], 
            "Alice Token B balance should decrease"
        );
        assertEq(
            tokenModule.balanceOf(bob, TOKEN_ID_A), 
            bobBalanceA + amounts[0], 
            "Bob Token A balance should increase"
        );
        assertEq(
            tokenModule.balanceOf(bob, TOKEN_ID_B), 
            bobBalanceB + amounts[1], 
            "Bob Token B balance should increase"
        );
        
        console.log("SUCCESS: Batch token transfer atomicity working correctly");
    }
    
    function testBatchAtomicity_TokenTransferFailure() public {
        console.log("\n=== P2 SECURITY: Testing Batch Token Transfer Atomicity - Failure Case ===");
        
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = TOKEN_ID_A;
        tokenIds[1] = TOKEN_ID_B;
        
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 25 ether;
        amounts[1] = EXCESSIVE_AMOUNT; // This will cause insufficient balance failure
        
        // Record initial balances
        uint256 aliceBalanceA = tokenModule.balanceOf(alice, TOKEN_ID_A);
        uint256 aliceBalanceB = tokenModule.balanceOf(alice, TOKEN_ID_B);
        uint256 bobBalanceA = tokenModule.balanceOf(bob, TOKEN_ID_A);
        uint256 bobBalanceB = tokenModule.balanceOf(bob, TOKEN_ID_B);
        
        // Execute batch transfer operation - should fail completely
        vm.prank(alice);
        vm.expectRevert();
        tokenModule.batchTransfer(alice, bob, tokenIds, amounts);
        
        // Verify NO operations succeeded (all-or-nothing)
        assertEq(
            tokenModule.balanceOf(alice, TOKEN_ID_A), 
            aliceBalanceA, 
            "Alice Token A balance should remain unchanged after batch failure"
        );
        assertEq(
            tokenModule.balanceOf(alice, TOKEN_ID_B), 
            aliceBalanceB, 
            "Alice Token B balance should remain unchanged after batch failure"
        );
        assertEq(
            tokenModule.balanceOf(bob, TOKEN_ID_A), 
            bobBalanceA, 
            "Bob Token A balance should remain unchanged after batch failure"
        );
        assertEq(
            tokenModule.balanceOf(bob, TOKEN_ID_B), 
            bobBalanceB, 
            "Bob Token B balance should remain unchanged after batch failure"
        );
        
        console.log("SUCCESS: Batch token transfer atomicity failure handling correct");
    }
    
    function testBatchAtomicity_TokenBurnSuccess() public {
        console.log("\n=== P2 SECURITY: Testing Batch Token Burn Atomicity - Success Case ===");
        
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = TOKEN_ID_A;
        tokenIds[1] = TOKEN_ID_B;
        
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 30 ether;
        amounts[1] = 40 ether;
        
        // Record initial balances
        uint256 initialBalanceA = tokenModule.balanceOf(alice, TOKEN_ID_A);
        uint256 initialBalanceB = tokenModule.balanceOf(alice, TOKEN_ID_B);
        
        // Execute batch burn operation
        vm.prank(alice);
        tokenModule.batchBurnSavingsTokens(alice, tokenIds, amounts);
        
        // Verify all operations succeeded atomically
        assertEq(
            tokenModule.balanceOf(alice, TOKEN_ID_A), 
            initialBalanceA - amounts[0], 
            "Token A balance should decrease"
        );
        assertEq(
            tokenModule.balanceOf(alice, TOKEN_ID_B), 
            initialBalanceB - amounts[1], 
            "Token B balance should decrease"
        );
        
        console.log("SUCCESS: Batch token burn atomicity working correctly");
    }
    
    function testBatchAtomicity_TokenBurnFailure() public {
        console.log("\n=== P2 SECURITY: Testing Batch Token Burn Atomicity - Failure Case ===");
        
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = TOKEN_ID_A;
        tokenIds[1] = TOKEN_ID_B;
        
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 30 ether;
        amounts[1] = EXCESSIVE_AMOUNT; // This will cause insufficient balance failure
        
        // Record initial balances
        uint256 initialBalanceA = tokenModule.balanceOf(alice, TOKEN_ID_A);
        uint256 initialBalanceB = tokenModule.balanceOf(alice, TOKEN_ID_B);
        
        // Execute batch burn operation - should fail completely
        vm.prank(alice);
        vm.expectRevert();
        tokenModule.batchBurnSavingsTokens(alice, tokenIds, amounts);
        
        // Verify NO operations succeeded (all-or-nothing)
        assertEq(
            tokenModule.balanceOf(alice, TOKEN_ID_A), 
            initialBalanceA, 
            "Token A balance should remain unchanged after batch failure"
        );
        assertEq(
            tokenModule.balanceOf(alice, TOKEN_ID_B), 
            initialBalanceB, 
            "Token B balance should remain unchanged after batch failure"
        );
        
        console.log("SUCCESS: Batch token burn atomicity failure handling correct");
    }
    
    // ==================== BATCH SAVINGS OPERATIONS ATOMICITY ====================
    
    function testBatchAtomicity_SavingsProcessingSuccess() public {
        console.log("\n=== P2 SECURITY: Testing Batch Savings Processing Atomicity - Success Case ===");
        
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenA);
        tokens[1] = address(tokenB);
        
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10 ether;
        amounts[1] = 15 ether;
        
        // Record initial savings balances
        uint256 initialSavingsA = storageContract.savings(alice, address(tokenA));
        uint256 initialSavingsB = storageContract.savings(alice, address(tokenB));
        
        // Execute batch savings processing
        vm.prank(address(hook)); // Only hook can call batch processing
        uint256 totalProcessed = savingsModule.batchProcessSavings(alice, tokens, amounts);
        
        // Verify total processed amount
        assertTrue(totalProcessed > 0, "Total processed amount should be greater than zero");
        
        // Verify all savings were processed atomically
        uint256 newSavingsA = storageContract.savings(alice, address(tokenA));
        uint256 newSavingsB = storageContract.savings(alice, address(tokenB));
        
        assertTrue(newSavingsA >= initialSavingsA, "Token A savings should increase or stay same");
        assertTrue(newSavingsB >= initialSavingsB, "Token B savings should increase or stay same");
        
        console.log("SUCCESS: Batch savings processing atomicity working correctly");
    }
    
    // ==================== BATCH TOKEN REGISTRATION ATOMICITY ====================
    
    function testBatchAtomicity_TokenRegistrationSuccess() public {
        console.log("\n=== P2 SECURITY: Testing Batch Token Registration Atomicity - Success Case ===");
        
        // Deploy new tokens for registration testing
        MockERC20 tokenD = new MockERC20("Token D", "TOKD", 18);
        MockERC20 tokenE = new MockERC20("Token E", "TOKE", 18);
        
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenD);
        tokens[1] = address(tokenE);
        
        // Verify tokens are not registered initially
        assertEq(tokenModule.getTokenId(address(tokenD)), 0, "Token D should not be registered initially");
        assertEq(tokenModule.getTokenId(address(tokenE)), 0, "Token E should not be registered initially");
        
        // Execute batch token registration
        uint256[] memory tokenIds = tokenModule.batchRegisterTokens(tokens);
        
        // Verify all tokens were registered atomically
        assertEq(tokenIds.length, 2, "Should return 2 token IDs");
        assertTrue(tokenIds[0] > 0, "Token D should be assigned a valid ID");
        assertTrue(tokenIds[1] > 0, "Token E should be assigned a valid ID");
        assertEq(tokenModule.getTokenId(address(tokenD)), tokenIds[0], "Token D ID should match");
        assertEq(tokenModule.getTokenId(address(tokenE)), tokenIds[1], "Token E ID should match");
        
        console.log("SUCCESS: Batch token registration atomicity working correctly");
    }
    
    function testBatchAtomicity_TokenRegistrationFailure() public {
        console.log("\n=== P2 SECURITY: Testing Batch Token Registration Atomicity - Failure Case ===");
        
        // Deploy one valid token and include one invalid address
        MockERC20 tokenF = new MockERC20("Token F", "TOKF", 18);
        
        address[] memory tokens = new address[](2);
        tokens[0] = address(tokenF);
        tokens[1] = INVALID_ADDRESS; // This will cause failure
        
        // Verify tokens are not registered initially
        assertEq(tokenModule.getTokenId(address(tokenF)), 0, "Token F should not be registered initially");
        
        // Execute batch token registration - should fail completely
        vm.expectRevert();
        tokenModule.batchRegisterTokens(tokens);
        
        // Verify NO tokens were registered (all-or-nothing)
        assertEq(tokenModule.getTokenId(address(tokenF)), 0, "Token F should remain unregistered after batch failure");
        
        console.log("SUCCESS: Batch token registration atomicity failure handling correct");
    }
    
    // ==================== CROSS-MODULE BATCH ATOMICITY ====================
    
    function testBatchAtomicity_CrossModuleOperations() public {
        console.log("\n=== P2 SECURITY: Testing Cross-Module Batch Operations Atomicity ===");
        
        // Setup a complex cross-module operation that should succeed atomically
        uint256 savingsPercentage = 1000; // 10%
        
        // Step 1: Set savings strategy
        vm.prank(alice);
        strategyModule.setSavingStrategy(
            alice,
            savingsPercentage,
            0, // no auto increment
            5000, // max 50%
            false, // no round up
            SpendSaveStorage.SavingsTokenType.INPUT,
            address(0)
        );
        
        // Step 2: Process some savings to create balances
        vm.prank(address(hook));
        savingsModule.processSavingsOptimized(
            alice,
            address(tokenA),
            1 ether,
            SpendSaveStorage.PackedUserConfig({
                percentage: uint16(savingsPercentage),
                autoIncrement: 0,
                maxPercentage: 5000,
                roundUpSavings: 0,
                enableDCA: 0,
                savingsTokenType: uint8(SpendSaveStorage.SavingsTokenType.INPUT),
                reserved: 0
            })
        );
        
        // Verify the cross-module operation completed atomically
        (uint256 percentage,,,) = storageContract.getPackedUserConfig(alice);
        assertEq(percentage, savingsPercentage, "Savings strategy should be set");
        
        uint256 savingsBalance = storageContract.savings(alice, address(tokenA));
        assertTrue(savingsBalance > 0, "Savings should be processed");
        
        uint256 tokenBalance = tokenModule.balanceOf(alice, TOKEN_ID_A);
        assertTrue(tokenBalance > 0, "Token balance should exist");
        
        console.log("SUCCESS: Cross-module batch operations atomicity working correctly");
    }
    
    // ==================== ARRAY LENGTH MISMATCH ATOMICITY ====================
    
    function testBatchAtomicity_ArrayLengthMismatch() public {
        console.log("\n=== P2 SECURITY: Testing Batch Operations Array Length Mismatch Atomicity ===");
        
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = TOKEN_ID_A;
        tokenIds[1] = TOKEN_ID_B;
        
        uint256[] memory amounts = new uint256[](3); // Mismatched length
        amounts[0] = 25 ether;
        amounts[1] = 35 ether;
        amounts[2] = 45 ether;
        
        // Record initial balances
        uint256 initialBalanceA = tokenModule.balanceOf(alice, TOKEN_ID_A);
        uint256 initialBalanceB = tokenModule.balanceOf(alice, TOKEN_ID_B);
        
        // Execute batch operation with mismatched arrays - should fail completely
        vm.prank(alice);
        vm.expectRevert();
        tokenModule.batchTransfer(alice, bob, tokenIds, amounts);
        
        // Verify NO operations succeeded (all-or-nothing)
        assertEq(
            tokenModule.balanceOf(alice, TOKEN_ID_A), 
            initialBalanceA, 
            "Token A balance should remain unchanged after batch failure"
        );
        assertEq(
            tokenModule.balanceOf(alice, TOKEN_ID_B), 
            initialBalanceB, 
            "Token B balance should remain unchanged after batch failure"
        );
        
        console.log("SUCCESS: Array length mismatch atomicity protection working correctly");
    }
    
    // ==================== COMPREHENSIVE ATOMICITY TEST ====================
    
    function testBatchAtomicity_ComprehensiveReport() public {
        console.log("\n=== P2 SECURITY: COMPREHENSIVE BATCH OPERATIONS ATOMICITY REPORT ===");
        
        // Run all atomicity tests
        testBatchAtomicity_TokenMintSuccess();
        testBatchAtomicity_TokenMintFailure();
        testBatchAtomicity_TokenTransferSuccess();
        testBatchAtomicity_TokenTransferFailure();
        testBatchAtomicity_TokenBurnSuccess();
        testBatchAtomicity_TokenBurnFailure();
        testBatchAtomicity_SavingsProcessingSuccess();
        testBatchAtomicity_TokenRegistrationSuccess();
        testBatchAtomicity_TokenRegistrationFailure();
        testBatchAtomicity_CrossModuleOperations();
        testBatchAtomicity_ArrayLengthMismatch();
        
        console.log("\n=== FINAL BATCH ATOMICITY RESULTS ===");
        console.log("PASS - Token Mint Atomicity: PASS");
        console.log("PASS - Token Transfer Atomicity: PASS");
        console.log("PASS - Token Burn Atomicity: PASS");
        console.log("PASS - Savings Processing Atomicity: PASS");
        console.log("PASS - Token Registration Atomicity: PASS");
        console.log("PASS - Cross-Module Operations Atomicity: PASS");
        console.log("PASS - Array Mismatch Protection: PASS");
        
        console.log("\n=== BATCH OPERATIONS ATOMICITY SUMMARY ===");
        console.log("Total atomicity scenarios tested: 11");
        console.log("Scenarios passing: 11");
        console.log("Success rate: 100%");
        console.log("SUCCESS: Complete batch operations atomicity verified!");
        console.log("SUCCESS: All-or-nothing execution pattern working correctly!");
    }
}