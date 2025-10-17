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
import {SpendSaveHook} from "../src/SpendSaveHook.sol";
import {SpendSaveStorage} from "../src/SpendSaveStorage.sol";
import {SavingStrategy} from "../src/SavingStrategy.sol";
import {Savings} from "../src/Savings.sol";
import {DCA} from "../src/DCA.sol";
import {Token} from "../src/Token.sol";
import {SlippageControl} from "../src/SlippageControl.sol";
import {DailySavings} from "../src/DailySavings.sol";

/**
 * @title ERC6909ComplianceTest
 * @notice P2 SECURITY: Comprehensive testing of ERC6909 token standard compliance in Token module
 * @dev Tests all ERC6909 functions, events, and behaviors according to the standard
 */
contract ERC6909ComplianceTest is Test {
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
    PoolKey poolKey;
    
    address owner = address(this);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
    address recipient = makeAddr("recipient");
    address attacker = makeAddr("attacker");
    
    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 TOKEN_ID_A;
    uint256 TOKEN_ID_B;
    uint256 constant MINT_AMOUNT = 100 ether;
    
    event Transfer(
        address caller,
        address indexed from,
        address indexed to,
        uint256 indexed id,
        uint256 amount
    );
    
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 indexed id,
        uint256 amount
    );
    
    function setUp() public {
        console.log("Core protocol deployed and initialized");
        
        // Deploy and setup core infrastructure
        _deployCoreProtocol();
        _initializeModules();
        _setupTestTokens();
        _configureTestAccounts();
        
        console.log("=== P2 SECURITY: ERC6909 COMPLIANCE TESTS SETUP COMPLETE ===");
    }
    
    function _deployCoreProtocol() internal {
        // Deploy storage contract (needs poolManager address)
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
        bytes32 strategyId = keccak256("STRATEGY");
        bytes32 savingsId = keccak256("SAVINGS");
        bytes32 dcaId = keccak256("DCA");
        bytes32 tokenId = keccak256("TOKEN");
        bytes32 slippageId = keccak256("SLIPPAGE");
        bytes32 dailyId = keccak256("DAILY");
        
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
        
        // Register tokens in token module
        uint256 tokenIdA = tokenModule.registerToken(address(tokenA));
        uint256 tokenIdB = tokenModule.registerToken(address(tokenB));
        
        // Store the actual token IDs for use in tests
        TOKEN_ID_A = tokenIdA;
        TOKEN_ID_B = tokenIdB;
        
        // Verify token IDs were assigned correctly
        assertEq(tokenModule.getTokenId(address(tokenA)), tokenIdA, "Token A ID should match");
        assertEq(tokenModule.getTokenId(address(tokenB)), tokenIdB, "Token B ID should match");
    }
    
    function _configureTestAccounts() internal {
        // Fund test accounts
        tokenA.mint(alice, INITIAL_BALANCE);
        tokenA.mint(bob, INITIAL_BALANCE);
        tokenA.mint(charlie, INITIAL_BALANCE);
        
        tokenB.mint(alice, INITIAL_BALANCE);
        tokenB.mint(bob, INITIAL_BALANCE);
        tokenB.mint(charlie, INITIAL_BALANCE);
        
        // Setup some initial savings balances for testing
        vm.prank(alice);
        tokenModule.mintSavingsToken(alice, TOKEN_ID_A, MINT_AMOUNT);
        
        vm.prank(bob);
        tokenModule.mintSavingsToken(bob, TOKEN_ID_B, MINT_AMOUNT);
    }
    
    // ==================== ERC6909 CORE FUNCTIONS ====================
    
    function testERC6909_BalanceOf() public {
        console.log("\n=== P2 SECURITY: Testing ERC6909 balanceOf function ===");
        
        // Test alice's balance for Token A
        uint256 aliceBalanceA = tokenModule.balanceOf(alice, TOKEN_ID_A);
        assertEq(aliceBalanceA, MINT_AMOUNT, "Alice should have correct Token A balance");
        
        // Test bob's balance for Token B
        uint256 bobBalanceB = tokenModule.balanceOf(bob, TOKEN_ID_B);
        assertEq(bobBalanceB, MINT_AMOUNT, "Bob should have correct Token B balance");
        
        // Test zero balance for non-existent tokens
        uint256 charlieBalance = tokenModule.balanceOf(charlie, TOKEN_ID_A);
        assertEq(charlieBalance, 0, "Charlie should have zero balance");
        
        // Test balance for non-existent token ID
        uint256 nonExistentBalance = tokenModule.balanceOf(alice, 999);
        assertEq(nonExistentBalance, 0, "Non-existent token should have zero balance");
        
        console.log("SUCCESS: ERC6909 balanceOf function working correctly");
    }
    
    function testERC6909_Allowance() public {
        console.log("\n=== P2 SECURITY: Testing ERC6909 allowance function ===");
        
        // Initially should be zero
        uint256 initialAllowance = tokenModule.allowance(alice, bob, TOKEN_ID_A);
        assertEq(initialAllowance, 0, "Initial allowance should be zero");
        
        // Set allowance
        uint256 approvalAmount = 50 ether;
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, TOKEN_ID_A, approvalAmount);
        bool approveSuccess = tokenModule.approve(bob, TOKEN_ID_A, approvalAmount);
        assertTrue(approveSuccess, "Approval should succeed");
        
        // Check allowance was set
        uint256 newAllowance = tokenModule.allowance(alice, bob, TOKEN_ID_A);
        assertEq(newAllowance, approvalAmount, "Allowance should be set correctly");
        
        // Test allowance for different token ID should be zero
        uint256 differentTokenAllowance = tokenModule.allowance(alice, bob, TOKEN_ID_B);
        assertEq(differentTokenAllowance, 0, "Different token allowance should be zero");
        
        console.log("SUCCESS: ERC6909 allowance function working correctly");
    }
    
    function testERC6909_Approve() public {
        console.log("\n=== P2 SECURITY: Testing ERC6909 approve function ===");
        
        uint256 approvalAmount = 75 ether;
        
        // Test successful approval
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, TOKEN_ID_A, approvalAmount);
        bool success = tokenModule.approve(bob, TOKEN_ID_A, approvalAmount);
        assertTrue(success, "Approval should succeed");
        
        // Verify allowance was set
        uint256 allowance = tokenModule.allowance(alice, bob, TOKEN_ID_A);
        assertEq(allowance, approvalAmount, "Allowance should match approval amount");
        
        // Test approval override (setting new amount)
        uint256 newApprovalAmount = 25 ether;
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, TOKEN_ID_A, newApprovalAmount);
        success = tokenModule.approve(bob, TOKEN_ID_A, newApprovalAmount);
        assertTrue(success, "Approval override should succeed");
        
        // Verify new allowance
        allowance = tokenModule.allowance(alice, bob, TOKEN_ID_A);
        assertEq(allowance, newApprovalAmount, "Allowance should be updated");
        
        // Test approval to zero (revoke)
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Approval(alice, bob, TOKEN_ID_A, 0);
        success = tokenModule.approve(bob, TOKEN_ID_A, 0);
        assertTrue(success, "Approval revocation should succeed");
        
        allowance = tokenModule.allowance(alice, bob, TOKEN_ID_A);
        assertEq(allowance, 0, "Allowance should be revoked");
        
        console.log("SUCCESS: ERC6909 approve function working correctly");
    }
    
    function testERC6909_Transfer() public {
        console.log("\n=== P2 SECURITY: Testing ERC6909 transfer function ===");
        
        uint256 transferAmount = 30 ether;
        uint256 initialAliceBalance = tokenModule.balanceOf(alice, TOKEN_ID_A);
        uint256 initialBobBalance = tokenModule.balanceOf(bob, TOKEN_ID_A);
        
        // Test successful transfer
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, alice, bob, TOKEN_ID_A, transferAmount);
        bool success = tokenModule.transfer(alice, bob, TOKEN_ID_A, transferAmount);
        assertTrue(success, "Transfer should succeed");
        
        // Verify balances updated correctly
        uint256 newAliceBalance = tokenModule.balanceOf(alice, TOKEN_ID_A);
        uint256 newBobBalance = tokenModule.balanceOf(bob, TOKEN_ID_A);
        
        assertEq(newAliceBalance, initialAliceBalance - transferAmount, "Alice balance should decrease");
        assertEq(newBobBalance, initialBobBalance + transferAmount, "Bob balance should increase");
        
        // Test transfer to self
        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit Transfer(alice, alice, alice, TOKEN_ID_A, transferAmount);
        success = tokenModule.transfer(alice, alice, TOKEN_ID_A, transferAmount);
        assertTrue(success, "Self transfer should succeed");
        
        // Balance should remain the same for self transfer
        uint256 balanceAfterSelfTransfer = tokenModule.balanceOf(alice, TOKEN_ID_A);
        assertEq(balanceAfterSelfTransfer, newAliceBalance, "Self transfer should not change balance");
        
        console.log("SUCCESS: ERC6909 transfer function working correctly");
    }
    
    function testERC6909_Transfer_InsufficientBalance() public {
        console.log("\n=== P2 SECURITY: Testing ERC6909 transfer insufficient balance ===");
        
        uint256 charlieBalance = tokenModule.balanceOf(charlie, TOKEN_ID_A);
        assertEq(charlieBalance, 0, "Charlie should start with zero balance");
        
        // Test transfer with insufficient balance
        vm.prank(charlie);
        vm.expectRevert();
        tokenModule.transfer(charlie, alice, TOKEN_ID_A, 1 ether);
        
        // Test transfer more than available balance
        uint256 aliceBalance = tokenModule.balanceOf(alice, TOKEN_ID_A);
        vm.prank(alice);
        vm.expectRevert();
        tokenModule.transfer(alice, bob, TOKEN_ID_A, aliceBalance + 1);
        
        console.log("SUCCESS: ERC6909 transfer insufficient balance protection working");
    }
    
    function testERC6909_TransferFrom() public {
        console.log("\n=== P2 SECURITY: Testing ERC6909 transferFrom function ===");
        
        uint256 approvalAmount = 60 ether;
        uint256 transferAmount = 40 ether;
        
        // First approve bob to spend alice's tokens
        vm.prank(alice);
        tokenModule.approve(bob, TOKEN_ID_A, approvalAmount);
        
        uint256 initialAliceBalance = tokenModule.balanceOf(alice, TOKEN_ID_A);
        uint256 initialCharlieBalance = tokenModule.balanceOf(charlie, TOKEN_ID_A);
        
        // Test transferFrom with approval
        vm.prank(bob);
        vm.expectEmit(true, true, true, true);
        emit Transfer(bob, alice, charlie, TOKEN_ID_A, transferAmount);
        bool success = tokenModule.transferFrom(alice, charlie, TOKEN_ID_A, transferAmount);
        assertTrue(success, "TransferFrom should succeed with approval");
        
        // Verify balances updated
        uint256 newAliceBalance = tokenModule.balanceOf(alice, TOKEN_ID_A);
        uint256 newCharlieBalance = tokenModule.balanceOf(charlie, TOKEN_ID_A);
        
        assertEq(newAliceBalance, initialAliceBalance - transferAmount, "Alice balance should decrease");
        assertEq(newCharlieBalance, initialCharlieBalance + transferAmount, "Charlie balance should increase");
        
        // Verify allowance was decreased
        uint256 remainingAllowance = tokenModule.allowance(alice, bob, TOKEN_ID_A);
        assertEq(remainingAllowance, approvalAmount - transferAmount, "Allowance should be decreased");
        
        console.log("SUCCESS: ERC6909 transferFrom function working correctly");
    }
    
    function testERC6909_TransferFrom_InsufficientAllowance() public {
        console.log("\n=== P2 SECURITY: Testing ERC6909 transferFrom insufficient allowance ===");
        
        uint256 approvalAmount = 20 ether;
        uint256 transferAmount = 30 ether; // More than approved
        
        // Approve smaller amount
        vm.prank(alice);
        tokenModule.approve(bob, TOKEN_ID_A, approvalAmount);
        
        // Test transferFrom with insufficient allowance
        vm.prank(bob);
        vm.expectRevert();
        tokenModule.transferFrom(alice, charlie, TOKEN_ID_A, transferAmount);
        
        // Test transferFrom without any approval
        vm.prank(charlie);
        vm.expectRevert();
        tokenModule.transferFrom(alice, bob, TOKEN_ID_A, 1 ether);
        
        console.log("SUCCESS: ERC6909 transferFrom insufficient allowance protection working");
    }
    
    // ==================== ERC6909 BATCH OPERATIONS ====================
    
    function testERC6909_BatchTransfer() public {
        console.log("\n=== P2 SECURITY: Testing ERC6909 batch transfer operations ===");
        
        // Setup: Alice has both tokens, transfer both to Bob
        vm.prank(alice);
        tokenModule.mintSavingsToken(alice, TOKEN_ID_B, MINT_AMOUNT);
        
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = TOKEN_ID_A;
        tokenIds[1] = TOKEN_ID_B;
        
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 25 ether;
        amounts[1] = 35 ether;
        
        uint256 aliceBalanceA = tokenModule.balanceOf(alice, TOKEN_ID_A);
        uint256 aliceBalanceB = tokenModule.balanceOf(alice, TOKEN_ID_B);
        uint256 bobBalanceA = tokenModule.balanceOf(bob, TOKEN_ID_A);
        uint256 bobBalanceB = tokenModule.balanceOf(bob, TOKEN_ID_B);
        
        // Test batch transfer to single recipient
        vm.prank(alice);
        bool success = tokenModule.batchTransfer(alice, bob, tokenIds, amounts);
        assertTrue(success, "Batch transfer should succeed");
        
        // Verify all transfers occurred
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
        
        console.log("SUCCESS: ERC6909 batch transfer operations working correctly");
    }
    
    function testERC6909_BatchTransfer_InvalidArrays() public {
        console.log("\n=== P2 SECURITY: Testing ERC6909 batch transfer array validation ===");
        
        // Test mismatched array lengths
        uint256[] memory tokenIds = new uint256[](1); // Different length
        tokenIds[0] = TOKEN_ID_A;
        
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 25 ether;
        amounts[1] = 35 ether;
        
        vm.prank(alice);
        vm.expectRevert();
        tokenModule.batchTransfer(alice, bob, tokenIds, amounts);
        
        console.log("SUCCESS: ERC6909 batch transfer array validation working");
    }
    
    // ==================== ERC6909 METADATA ====================
    
    function testERC6909_Metadata() public {
        console.log("\n=== P2 SECURITY: Testing ERC6909 metadata functions ===");
        console.log("TOKEN_ID_A:", TOKEN_ID_A);
        console.log("TOKEN_ID_B:", TOKEN_ID_B);
        
        // Test name function
        string memory nameA = tokenModule.name(TOKEN_ID_A);
        assertEq(nameA, "SpendSave Token A", "Token A name should be correct");
        
        string memory nameB = tokenModule.name(TOKEN_ID_B);
        assertEq(nameB, "SpendSave Token B", "Token B name should be correct");
        
        // Test symbol function
        string memory symbolA = tokenModule.symbol(TOKEN_ID_A);
        assertEq(symbolA, "ssTOKA", "Token A symbol should be correct");
        
        string memory symbolB = tokenModule.symbol(TOKEN_ID_B);
        assertEq(symbolB, "ssTOKB", "Token B symbol should be correct");
        
        // Test decimals function
        uint8 decimalsA = tokenModule.decimals(TOKEN_ID_A);
        assertEq(decimalsA, 18, "Token A decimals should be 18");
        
        uint8 decimalsB = tokenModule.decimals(TOKEN_ID_B);
        assertEq(decimalsB, 18, "Token B decimals should be 18");
        
        // Test non-existent token metadata - should revert for security
        vm.expectRevert("Token not registered");
        tokenModule.name(999);
        
        console.log("SUCCESS: ERC6909 metadata functions working correctly");
    }
    
    // ==================== ERC6909 MINT/BURN OPERATIONS ====================
    
    function testERC6909_MintBurn() public {
        console.log("\n=== P2 SECURITY: Testing ERC6909 mint and burn operations ===");
        
        uint256 mintAmount = 50 ether;
        uint256 burnAmount = 30 ether;
        
        uint256 initialBalance = tokenModule.balanceOf(charlie, TOKEN_ID_A);
        
        // Test minting
        vm.prank(charlie);
        tokenModule.mintSavingsToken(charlie, TOKEN_ID_A, mintAmount);
        
        uint256 balanceAfterMint = tokenModule.balanceOf(charlie, TOKEN_ID_A);
        assertEq(balanceAfterMint, initialBalance + mintAmount, "Balance should increase after mint");
        
        // Test burning
        vm.prank(charlie);
        tokenModule.burnSavingsToken(charlie, TOKEN_ID_A, burnAmount);
        
        uint256 balanceAfterBurn = tokenModule.balanceOf(charlie, TOKEN_ID_A);
        assertEq(balanceAfterBurn, balanceAfterMint - burnAmount, "Balance should decrease after burn");
        
        console.log("SUCCESS: ERC6909 mint and burn operations working correctly");
    }
    
    function testERC6909_BurnInsufficientBalance() public {
        console.log("\n=== P2 SECURITY: Testing ERC6909 burn insufficient balance ===");
        
        uint256 charlieBalance = tokenModule.balanceOf(charlie, TOKEN_ID_B);
        
        // Try to burn more than available
        vm.prank(charlie);
        vm.expectRevert();
        tokenModule.burnSavingsToken(charlie, TOKEN_ID_B, charlieBalance + 1 ether);
        
        console.log("SUCCESS: ERC6909 burn insufficient balance protection working");
    }
    
    // ==================== ERC6909 AUTHORIZATION COMPLIANCE ====================
    
    function testERC6909_AuthorizationCompliance() public {
        console.log("\n=== P2 SECURITY: Testing ERC6909 authorization compliance ===");
        
        // Test that unauthorized users cannot transfer on behalf of others
        vm.prank(attacker);
        vm.expectRevert();
        tokenModule.transfer(alice, bob, TOKEN_ID_A, 1 ether);
        
        // Test that unauthorized users cannot mint for others
        vm.prank(attacker);
        vm.expectRevert();
        tokenModule.mintSavingsToken(alice, TOKEN_ID_A, 1 ether);
        
        // Test that unauthorized users cannot burn for others
        vm.prank(attacker);
        vm.expectRevert();
        tokenModule.burnSavingsToken(alice, TOKEN_ID_A, 1 ether);
        
        console.log("SUCCESS: ERC6909 authorization compliance working correctly");
    }
    
    // ==================== ERC6909 EDGE CASES ====================
    
    function testERC6909_ZeroAmountOperations() public {
        console.log("\n=== P2 SECURITY: Testing ERC6909 zero amount operations ===");
        
        uint256 aliceBalance = tokenModule.balanceOf(alice, TOKEN_ID_A);
        
        // Test zero amount transfer (should succeed)
        vm.prank(alice);
        bool success = tokenModule.transfer(alice, bob, TOKEN_ID_A, 0);
        assertTrue(success, "Zero amount transfer should succeed");
        
        // Verify balance unchanged
        uint256 newAliceBalance = tokenModule.balanceOf(alice, TOKEN_ID_A);
        assertEq(newAliceBalance, aliceBalance, "Zero transfer should not change balance");
        
        // Test zero amount approval
        vm.prank(alice);
        success = tokenModule.approve(bob, TOKEN_ID_A, 0);
        assertTrue(success, "Zero amount approval should succeed");
        
        // Test zero amount mint (should revert)
        vm.prank(alice);
        vm.expectRevert();
        tokenModule.mintSavingsToken(alice, TOKEN_ID_A, 0);
        
        // Test zero amount burn (should revert)
        vm.prank(alice);
        vm.expectRevert();
        tokenModule.burnSavingsToken(alice, TOKEN_ID_A, 0);
        
        console.log("SUCCESS: ERC6909 zero amount operations working correctly");
    }
    
    function testERC6909_ComprehensiveCompliance() public {
        console.log("\n=== P2 SECURITY: COMPREHENSIVE ERC6909 COMPLIANCE REPORT ===");
        
        // Run all compliance tests
        testERC6909_BalanceOf();
        testERC6909_Allowance();
        testERC6909_Approve();
        testERC6909_Transfer();
        testERC6909_Transfer_InsufficientBalance();
        testERC6909_TransferFrom();
        testERC6909_TransferFrom_InsufficientAllowance();
        testERC6909_BatchTransfer();
        testERC6909_BatchTransfer_InvalidArrays();
        testERC6909_Metadata();
        testERC6909_MintBurn();
        testERC6909_BurnInsufficientBalance();
        testERC6909_AuthorizationCompliance();
        testERC6909_ZeroAmountOperations();
        
        console.log("\n=== FINAL ERC6909 COMPLIANCE RESULTS ===");
        console.log("PASS - balanceOf function: PASS");
        console.log("PASS - allowance function: PASS"); 
        console.log("PASS - approve function: PASS");
        console.log("PASS - transfer function: PASS");
        console.log("PASS - transferFrom function: PASS");
        console.log("PASS - batch operations: PASS");
        console.log("PASS - metadata functions: PASS");
        console.log("PASS - mint/burn operations: PASS");
        console.log("PASS - authorization compliance: PASS");
        console.log("PASS - edge case handling: PASS");
        
        console.log("\n=== ERC6909 COMPLIANCE SUMMARY ===");
        console.log("Total ERC6909 functions tested: 14");
        console.log("Functions passing: 14");
        console.log("Success rate: 100%");
        console.log("SUCCESS: Complete ERC6909 standard compliance verified!");
    }
}