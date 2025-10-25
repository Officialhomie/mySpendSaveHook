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
import {PoolId, PoolIdLibrary} from "lib/v4-periphery/lib/v4-core/src/types/PoolId.sol";
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
 * @title TokenModuleLifecycleTest
 * @notice P6 TOKEN: Comprehensive testing of Token module ERC6909 registration and complete lifecycle
 * @dev Tests token registration, minting, burning, transfers, approvals, and batch operations
 */
contract TokenModuleLifecycleTest is Test, Deployers {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    // Core contracts
    SpendSaveHook public hook;
    SpendSaveStorage public storageContract;
    Token public tokenModule;

    // All modules
    Savings public savingsModule;
    SavingStrategy public strategyModule;
    DCA public dcaModule;
    DailySavings public dailySavingsModule;
    SlippageControl public slippageModule;

    // Test accounts
    address public owner;
    address public alice;
    address public bob;
    address public charlie;
    address public treasury;

    // Test tokens
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;
    MockERC20 public tokenD;

    // Pool configuration
    PoolKey public poolKey;

    // Test parameters
    uint256 constant INITIAL_BALANCE = 1000 ether;

    // Token IDs
    uint256 public tokenAId;
    uint256 public tokenBId;
    uint256 public tokenCId;
    uint256 public tokenDId;

    // Events
    event TokenRegistered(address indexed token, uint256 indexed tokenId);
    event SavingsTokenMinted(address indexed user, address indexed token, uint256 tokenId, uint256 amount);
    event SavingsTokenBurned(address indexed user, address indexed token, uint256 tokenId, uint256 amount);
    event Transfer(address caller, address indexed sender, address indexed receiver, uint256 indexed id, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 indexed id, uint256 amount);

    function setUp() public {
        // Create test accounts
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        treasury = makeAddr("treasury");

        // Deploy V4 infrastructure
        deployFreshManagerAndRouters();

        // Deploy tokens
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        tokenC = new MockERC20("Token C", "TKNC", 18);
        tokenD = new MockERC20("Token D", "TKND", 18);

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

        console.log("=== P6 TOKEN: LIFECYCLE TESTS SETUP COMPLETE ===");
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
        accounts[2] = charlie;
        accounts[3] = treasury;

        for (uint256 i = 0; i < accounts.length; i++) {
            tokenA.mint(accounts[i], INITIAL_BALANCE);
            tokenB.mint(accounts[i], INITIAL_BALANCE);
            tokenC.mint(accounts[i], INITIAL_BALANCE);
            tokenD.mint(accounts[i], INITIAL_BALANCE);
        }

        // Register tokens and get their IDs
        tokenAId = tokenModule.registerToken(address(tokenA));
        tokenBId = tokenModule.registerToken(address(tokenB));
        tokenCId = tokenModule.registerToken(address(tokenC));
        tokenDId = tokenModule.registerToken(address(tokenD));

        console.log("Token IDs - A");
        console.log(tokenAId);
        console.log("B");
        console.log(tokenBId);
        console.log("C");
        console.log(tokenCId);
        console.log("D");
        console.log(tokenDId);
        console.log("Test accounts configured with tokens");
    }

    // ==================== TOKEN MODULE LIFECYCLE TESTS ====================

    function testTokenModule_TokenRegistration() public {
        console.log("\n=== P6 TOKEN: Testing Token Registration ===");

        // Test registering a new token
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        uint256 newTokenId = tokenModule.registerToken(address(newToken));

        // Verify token was registered
        assertTrue(newTokenId > 0, "New token should get a valid ID");
        assertEq(tokenModule.getTokenId(address(newToken)), newTokenId, "Token ID should be stored correctly");

        console.log("New token registered with ID");
        console.log(newTokenId);
        console.log("SUCCESS: Token registration working");
    }

    function testTokenModule_TokenRegistrationDuplicate() public {
        console.log("\n=== P6 TOKEN: Testing Duplicate Token Registration ===");

        // Test registering the same token again
        uint256 firstId = tokenModule.registerToken(address(tokenA));
        uint256 secondId = tokenModule.registerToken(address(tokenA));

        // Should return the same ID
        assertEq(firstId, secondId, "Duplicate registration should return same ID");
        assertEq(firstId, tokenAId, "Should return original token ID");

        console.log("SUCCESS: Duplicate token registration handled correctly");
    }

    function testTokenModule_BatchTokenRegistration() public {
        console.log("\n=== P6 TOKEN: Testing Batch Token Registration ===");

        // Test batch registering multiple tokens
        address[] memory tokens = new address[](3);
        tokens[0] = address(tokenA); // Already registered
        tokens[1] = address(tokenB); // Already registered
        MockERC20 newToken1 = new MockERC20("Batch Token 1", "BT1", 18);
        MockERC20 newToken2 = new MockERC20("Batch Token 2", "BT2", 18);
        tokens[2] = address(newToken1);

        uint256[] memory tokenIds = tokenModule.batchRegisterTokens(tokens);

        // Verify batch registration
        assertEq(tokenIds.length, 3, "Should return correct number of IDs");
        assertEq(tokenIds[0], tokenAId, "First token should have correct ID");
        assertEq(tokenIds[1], tokenBId, "Second token should have correct ID");
        assertTrue(tokenIds[2] > 0, "Third token should get a valid ID");

        console.log("Batch registration successful");
        console.log("SUCCESS: Batch token registration working");
    }

    function testTokenModule_MintSavingsToken() public {
        console.log("\n=== P6 TOKEN: Testing Mint Savings Token ===");

        uint256 mintAmount = 100 ether;

        // Mint savings token to Alice
        vm.prank(alice);
        tokenModule.mintSavingsToken(alice, tokenAId, mintAmount);

        // Verify minting
        uint256 aliceBalance = tokenModule.balanceOf(alice, tokenAId);
        assertEq(aliceBalance, mintAmount, "Alice should have correct balance");

        uint256 totalSupply = tokenModule.totalSupply(tokenAId);
        assertEq(totalSupply, mintAmount, "Total supply should be correct");

        console.log("Minted");
        console.log(mintAmount);
        console.log("of token ID");
        console.log(tokenAId);
        console.log("to Alice");
        console.log("SUCCESS: Mint savings token working");
    }

    function testTokenModule_BurnSavingsToken() public {
        console.log("\n=== P6 TOKEN: Testing Burn Savings Token ===");

        uint256 mintAmount = 100 ether;
        uint256 burnAmount = 50 ether;

        // First mint tokens (fresh for this test)
        vm.prank(alice);
        tokenModule.mintSavingsToken(alice, tokenAId, mintAmount);

        // Get initial balance (may include tokens from previous tests)
        uint256 initialBalance = tokenModule.balanceOf(alice, tokenAId);
        uint256 initialTotalSupply = tokenModule.totalSupply(tokenAId);

        // Burn tokens
        vm.prank(alice);
        tokenModule.burnSavingsToken(alice, tokenAId, burnAmount);

        // Verify burning reduced balance correctly
        uint256 finalBalance = tokenModule.balanceOf(alice, tokenAId);
        assertEq(finalBalance, initialBalance - burnAmount, "Final balance should be reduced by burn amount");

        uint256 totalSupply = tokenModule.totalSupply(tokenAId);
        assertEq(totalSupply, initialTotalSupply - burnAmount, "Total supply should be reduced by burn amount");

        console.log("Burned");
        console.log(burnAmount);
        console.log("of token ID");
        console.log(tokenAId);
        console.log("from Alice");
        console.log("SUCCESS: Burn savings token working");
    }

    function testTokenModule_BatchMintSavingsTokens() public {
        console.log("\n=== P6 TOKEN: Testing Batch Mint Savings Tokens ===");

        // Prepare batch mint data
        uint256[] memory tokenIds = new uint256[](3);
        uint256[] memory amounts = new uint256[](3);
        tokenIds[0] = tokenAId;
        tokenIds[1] = tokenBId;
        tokenIds[2] = tokenCId;
        amounts[0] = 50 ether;
        amounts[1] = 75 ether;
        amounts[2] = 25 ether;

        // Batch mint tokens to Alice
        vm.prank(alice);
        tokenModule.batchMintSavingsTokens(alice, tokenIds, amounts);

        // Verify batch minting
        uint256 aliceABalance = tokenModule.balanceOf(alice, tokenAId);
        uint256 aliceBBalance = tokenModule.balanceOf(alice, tokenBId);
        uint256 aliceCBalance = tokenModule.balanceOf(alice, tokenCId);

        assertEq(aliceABalance, 50 ether, "Alice A balance should be correct");
        assertEq(aliceBBalance, 75 ether, "Alice B balance should be correct");
        assertEq(aliceCBalance, 25 ether, "Alice C balance should be correct");

        console.log("Batch mint successful");
        console.log("SUCCESS: Batch mint savings tokens working");
    }

    function testTokenModule_BatchBurnSavingsTokens() public {
        console.log("\n=== P6 TOKEN: Testing Batch Burn Savings Tokens ===");

        // First batch mint tokens
        uint256[] memory tokenIds = new uint256[](3);
        uint256[] memory mintAmounts = new uint256[](3);
        tokenIds[0] = tokenAId;
        tokenIds[1] = tokenBId;
        tokenIds[2] = tokenCId;
        mintAmounts[0] = 100 ether;
        mintAmounts[1] = 100 ether;
        mintAmounts[2] = 100 ether;

        vm.prank(alice);
        tokenModule.batchMintSavingsTokens(alice, tokenIds, mintAmounts);

        // Prepare batch burn data
        uint256[] memory burnAmounts = new uint256[](3);
        burnAmounts[0] = 30 ether;
        burnAmounts[1] = 40 ether;
        burnAmounts[2] = 50 ether;

        // Batch burn tokens
        vm.prank(alice);
        tokenModule.batchBurnSavingsTokens(alice, tokenIds, burnAmounts);

        // Verify batch burning
        uint256 aliceABalance = tokenModule.balanceOf(alice, tokenAId);
        uint256 aliceBBalance = tokenModule.balanceOf(alice, tokenBId);
        uint256 aliceCBalance = tokenModule.balanceOf(alice, tokenCId);

        assertEq(aliceABalance, 70 ether, "Alice A balance should be correct after burn");
        assertEq(aliceBBalance, 60 ether, "Alice B balance should be correct after burn");
        assertEq(aliceCBalance, 50 ether, "Alice C balance should be correct after burn");

        console.log("Batch burn successful");
        console.log("SUCCESS: Batch burn savings tokens working");
    }

    function testTokenModule_TransferFunctionality() public {
        console.log("\n=== P6 TOKEN: Testing Transfer Functionality ===");

        uint256 transferAmount = 25 ether;

        // First mint tokens to Alice (fresh for this test)
        vm.prank(alice);
        tokenModule.mintSavingsToken(alice, tokenAId, 100 ether);

        // Transfer from Alice to Bob
        vm.prank(alice);
        tokenModule.transfer(alice, bob, tokenAId, transferAmount);

        // Verify transfer
        uint256 aliceBalance = tokenModule.balanceOf(alice, tokenAId);
        uint256 bobBalance = tokenModule.balanceOf(bob, tokenAId);

        assertEq(aliceBalance, 75 ether, "Alice balance should be correct after transfer");
        assertEq(bobBalance, transferAmount, "Bob balance should be correct after transfer");

        console.log("Transferred");
        console.log(transferAmount);
        console.log("from Alice to Bob");
        console.log("SUCCESS: Transfer functionality working");
    }

    function testTokenModule_ApprovalFunctionality() public {
        console.log("\n=== P6 TOKEN: Testing Approval Functionality ===");

        uint256 approvalAmount = 50 ether;

        // Approve Bob to spend Alice's tokens
        vm.prank(alice);
        tokenModule.approve(bob, tokenAId, approvalAmount);

        // Verify approval
        uint256 allowance = tokenModule.allowance(alice, bob, tokenAId);
        assertEq(allowance, approvalAmount, "Allowance should be set correctly");

        console.log("Approved Bob to spend");
        console.log(approvalAmount);
        console.log("of Alice's token ID");
        console.log(tokenAId);
        console.log("SUCCESS: Approval functionality working");
    }

    function testTokenModule_TransferFromFunctionality() public {
        console.log("\n=== P6 TOKEN: Testing TransferFrom Functionality ===");

        uint256 transferAmount = 20 ether;

        // First mint tokens to Alice and set approval (fresh for this test)
        vm.prank(alice);
        tokenModule.mintSavingsToken(alice, tokenAId, 100 ether);
        vm.prank(alice);
        tokenModule.approve(bob, tokenAId, 50 ether);

        // Transfer from Alice to Charlie using Bob's approval
        vm.prank(bob);
        tokenModule.transferFrom(alice, charlie, tokenAId, transferAmount);

        // Verify transfer
        uint256 aliceBalance = tokenModule.balanceOf(alice, tokenAId);
        uint256 charlieBalance = tokenModule.balanceOf(charlie, tokenAId);
        uint256 remainingAllowance = tokenModule.allowance(alice, bob, tokenAId);

        assertEq(aliceBalance, 80 ether, "Alice balance should be correct");
        assertEq(charlieBalance, transferAmount, "Charlie balance should be correct");
        assertEq(remainingAllowance, 30 ether, "Remaining allowance should be correct");

        console.log("TransferFrom successful");
        console.log("SUCCESS: TransferFrom functionality working");
    }

    function testTokenModule_BalanceOfBatch() public {
        console.log("\n=== P6 TOKEN: Testing BalanceOfBatch Functionality ===");

        // First mint tokens to Alice
        uint256[] memory tokenIds = new uint256[](3);
        uint256[] memory amounts = new uint256[](3);
        tokenIds[0] = tokenAId;
        tokenIds[1] = tokenBId;
        tokenIds[2] = tokenCId;
        amounts[0] = 100 ether;
        amounts[1] = 200 ether;
        amounts[2] = 150 ether;

        vm.prank(alice);
        tokenModule.batchMintSavingsTokens(alice, tokenIds, amounts);

        // Test balanceOfBatch
        uint256[] memory balances = tokenModule.balanceOfBatch(alice, tokenIds);

        assertEq(balances.length, 3, "Should return correct number of balances");
        assertEq(balances[0], 100 ether, "Token A balance should be correct");
        assertEq(balances[1], 200 ether, "Token B balance should be correct");
        assertEq(balances[2], 150 ether, "Token C balance should be correct");

        console.log("BalanceOfBatch successful");
        console.log("SUCCESS: BalanceOfBatch functionality working");
    }

    function testTokenModule_ErrorHandling() public {
        console.log("\n=== P6 TOKEN: Testing Error Handling ===");

        // Test invalid token registration
        vm.expectRevert(Token.InvalidTokenAddress.selector);
        tokenModule.registerToken(address(0));

        // Test minting zero amount
        vm.expectRevert(Token.InvalidAmount.selector);
        vm.prank(alice);
        tokenModule.mintSavingsToken(alice, tokenAId, 0);

        // Test burning more than balance
        vm.prank(alice);
        tokenModule.mintSavingsToken(alice, tokenAId, 50 ether);

        vm.expectRevert();
        vm.prank(alice);
        tokenModule.burnSavingsToken(alice, tokenAId, 100 ether);

        // Test transferring to zero address
        vm.expectRevert(Token.TransferToZeroAddress.selector);
        vm.prank(alice);
        tokenModule.transfer(alice, address(0), tokenAId, 10 ether);

        console.log("SUCCESS: Error handling working correctly");
    }

    function testTokenModule_StressTest() public {
        console.log("\n=== P6 TOKEN: Token Module Stress Test ===");

        // Perform stress test with many operations
        uint256 numOperations = 50;

        // Register many tokens
        for (uint256 i = 0; i < numOperations; i++) {
            MockERC20 stressToken = new MockERC20(string(abi.encodePacked("Stress Token ", i)), string(abi.encodePacked("ST", i)), 18);
            uint256 tokenId = tokenModule.registerToken(address(stressToken));
            assertTrue(tokenId > 0, "Stress token should get valid ID");
        }

        // Batch operations stress test
        uint256[] memory stressTokenIds = new uint256[](10);
        uint256[] memory stressAmounts = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            stressTokenIds[i] = tokenAId + i;
            stressAmounts[i] = 10 ether * (i + 1);
        }

        // Batch mint
        vm.prank(alice);
        tokenModule.batchMintSavingsTokens(alice, stressTokenIds, stressAmounts);

        // Batch burn
        vm.prank(alice);
        tokenModule.batchBurnSavingsTokens(alice, stressTokenIds, stressAmounts);

        console.log("Stress test with");
        console.log(numOperations);
        console.log("operations completed successfully");
        console.log("SUCCESS: Token module stress test passed");
    }

    function testTokenModule_ComprehensiveReport() public {
        console.log("\n=== P6 TOKEN: COMPREHENSIVE LIFECYCLE REPORT ===");

        // Run all token module tests
        testTokenModule_TokenRegistration();
        testTokenModule_TokenRegistrationDuplicate();
        testTokenModule_BatchTokenRegistration();
        testTokenModule_MintSavingsToken();
        testTokenModule_BurnSavingsToken();
        testTokenModule_BatchMintSavingsTokens();
        testTokenModule_BatchBurnSavingsTokens();
        testTokenModule_TransferFunctionality();
        testTokenModule_ApprovalFunctionality();
        testTokenModule_TransferFromFunctionality();
        testTokenModule_BalanceOfBatch();
        testTokenModule_ErrorHandling();
        testTokenModule_StressTest();

        console.log("\n=== FINAL TOKEN MODULE RESULTS ===");
        console.log("PASS - Token Registration: PASS");
        console.log("PASS - Duplicate Registration: PASS");
        console.log("PASS - Batch Registration: PASS");
        console.log("PASS - Mint Savings Token: PASS");
        console.log("PASS - Burn Savings Token: PASS");
        console.log("PASS - Batch Mint: PASS");
        console.log("PASS - Batch Burn: PASS");
        console.log("PASS - Transfer: PASS");
        console.log("PASS - Approval: PASS");
        console.log("PASS - TransferFrom: PASS");
        console.log("PASS - BalanceOfBatch: PASS");
        console.log("PASS - Error Handling: PASS");
        console.log("PASS - Stress Test: PASS");

        console.log("\n=== TOKEN MODULE SUMMARY ===");
        console.log("Total token module scenarios: 13");
        console.log("Scenarios passing: 13");
        console.log("Success rate: 100%");
        console.log("SUCCESS: Complete Token module ERC6909 lifecycle verified!");
    }
}
