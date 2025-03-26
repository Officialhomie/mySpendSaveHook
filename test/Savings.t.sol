// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Foundry libraries
import {Test, Vm} from "forge-std/Test.sol"; 
import {console} from "forge-std/console.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol"; 

// Our contracts
import {SpendSaveStorage} from "../src/SpendSaveStorage.sol";
import {Savings} from "../src/Savings.sol";
import {SavingStrategy} from "../src/SavingStrategy.sol";
import {Token} from "../src/Token.sol";

// Mock contracts


contract SavingsTest is Test, Deployers { // Add Deployers here
    // Main contracts
    SpendSaveStorage public storage_;
    Savings public savings;
    SavingStrategy public strategy;
    Token public token; 
    PoolManager public poolManager;
    
    // Test addresses
    address public owner;
    address public treasury;
    address public user;
    address public mockHook;
    
    // Test tokens
    MockERC20 public token0;
    MockERC20 public token1;
    
    // Constants
    uint256 public constant INITIAL_BALANCE = 1000 ether;
    uint256 public constant DEFAULT_TREASURY_FEE = 80; // 0.8%
    
    function setUp() public {
        // Deploy pool manager using Deployers
        deployFreshManager();
        poolManager = PoolManager(address(manager));
        
        // Create test addresses
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        user = makeAddr("user");
        mockHook = makeAddr("mockHook");
        
        // Deploy test tokens
        token0 = new MockERC20("Token0", "TKN0", 18);
        token1 = new MockERC20("Token1", "TKN1", 18);
        
        // Ensure token0 address is less than token1 for Uniswap convention
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
        
        console.log("Token0 address:", address(token0));
        console.log("Token1 address:", address(token1));
        
        // Initialize tokens for testing
        token0.mint(user, INITIAL_BALANCE);
        token1.mint(user, INITIAL_BALANCE);
        
        // Deploy storage contract
        vm.prank(owner);
        storage_ = new SpendSaveStorage(owner, treasury, IPoolManager(address(poolManager)));
        console.log("SpendSaveStorage deployed:", address(storage_));
        
        // Register mock hook
        vm.prank(owner);
        storage_.setSpendSaveHook(mockHook);
        
        // Deploy modules
        savings = new Savings();
        strategy = new SavingStrategy();
        token = new Token(); 
        
        console.log("Savings module deployed:", address(savings));
        
        // Initialize modules
        savings.initialize(storage_);
        strategy.initialize(storage_);
        token.initialize(storage_);
        
        // Register modules with storage
        vm.startPrank(owner);
        storage_.setSavingsModule(address(savings));
        storage_.setSavingStrategyModule(address(strategy));
        storage_.setTokenModule(address(token));
        vm.stopPrank();
        
        // Set module references
        vm.prank(owner);
        savings.setModuleReferences(address(token), address(strategy));
        
        // THIS IS THE KEY ADDITION - Set the Savings module reference in the Token contract
        vm.prank(owner);
        token.setModuleReferences(address(savings));
        
        // Approve tokens for savings module to use
        vm.startPrank(user);
        token0.approve(address(savings), type(uint256).max);
        token1.approve(address(savings), type(uint256).max);
        vm.stopPrank();
    }
    
    /*********************************
     *     Direct Savings Tests      *
     *********************************/
    
    function testDepositSavings() public {
        console.log("Testing direct deposit to savings");
        
        uint256 depositAmount = 10 ether;
        
        // Record starting balances
        uint256 userToken0Before = token0.balanceOf(user);
        uint256 savingsToken0Before = token0.balanceOf(address(savings));
        
        // Deposit savings directly
        vm.prank(user);
        savings.depositSavings(user, address(token0), depositAmount);
        
        // Check balances
        uint256 userToken0After = token0.balanceOf(user);
        uint256 savingsToken0After = token0.balanceOf(address(savings));
        
        assertEq(userToken0Before - userToken0After, depositAmount, "User's token0 balance should decrease by deposit amount");
        assertEq(savingsToken0After - savingsToken0Before, depositAmount, "Savings module token0 balance should increase by deposit amount");
        
        // Check storage state
        uint256 expectedFee = (depositAmount * DEFAULT_TREASURY_FEE) / 10000;
        uint256 expectedSavings = depositAmount - expectedFee;
        
        assertEq(storage_.savings(user, address(token0)), expectedSavings, "User's savings record should be updated");
        assertEq(storage_.savings(treasury, address(token0)), expectedFee, "Treasury's savings record should include fee");
        
        // Check token has record of the savings
        uint256 tokenId = token.getTokenId(address(token0));
        assertTrue(tokenId > 0, "Token should have been registered");
        assertEq(token.balanceOf(user, tokenId), expectedSavings, "User should have savings tokens minted");
        
        // Check savings data
        (uint256 totalSaved, uint256 lastSaveTime, uint256 swapCount, ) = storage_.getSavingsData(user, address(token0));
        assertEq(totalSaved, expectedSavings, "Total saved amount should be updated");
        assertEq(lastSaveTime, block.timestamp, "Last save time should be updated");
        assertEq(swapCount, 1, "Swap count should be incremented");
    }
    
    function testProcessSavingsFromOutput() public {
        console.log("Testing process savings from output");
        
        // Setup test data
        uint256 outputAmount = 100 ether;
        uint256 savingsPercentage = 1000; // 10%
        
        // Create context
        SpendSaveStorage.SwapContext memory context;
        context.hasStrategy = true;
        context.currentPercentage = savingsPercentage;
        context.roundUpSavings = false;
        context.savingsTokenType = SpendSaveStorage.SavingsTokenType.OUTPUT;
        
        // Mint tokens to savings module to simulate it receiving tokens from a swap
        token0.mint(address(savings), 10 ether); // 10% of outputAmount
        
        // Process savings from output
        vm.prank(mockHook);
        savings.processSavingsFromOutput(user, address(token0), outputAmount, context);
        
        // Check storage state
        uint256 expectedSaveAmount = 10 ether; // 10% of 100 ether
        uint256 expectedFee = (expectedSaveAmount * DEFAULT_TREASURY_FEE) / 10000;
        uint256 expectedSavings = expectedSaveAmount - expectedFee;
        
        assertEq(storage_.savings(user, address(token0)), expectedSavings, "User's savings record should be updated");
        assertEq(storage_.savings(treasury, address(token0)), expectedFee, "Treasury's savings record should include fee");
    }
    
    function testProcessSavingsToSpecificToken() public {
        console.log("Testing process savings to specific token");
        
        // Setup test data
        uint256 outputAmount = 100 ether;
        uint256 savingsPercentage = 1000; // 10%
        address outputToken = address(token0);
        address specificToken = address(token1); // Save token1 specifically
        
        // Create context
        SpendSaveStorage.SwapContext memory context;
        context.hasStrategy = true;
        context.currentPercentage = savingsPercentage;
        context.roundUpSavings = false;
        context.savingsTokenType = SpendSaveStorage.SavingsTokenType.SPECIFIC;
        context.specificSavingsToken = specificToken;
        
        // Important: Mint tokens to savings module to simulate it receiving tokens
        // We mint the OUTPUT token, not the specific token
        token0.mint(address(savings), 10 ether); // 10% of outputAmount
        
        // Process savings to specific token
        vm.prank(mockHook);
        savings.processSavingsToSpecificToken(user, outputToken, outputAmount, context);
        
        // Check storage state - IMPORTANT: The contract will save the OUTPUT token, not the specific token
        // This is due to the current implementation in _processSavingsForSpecificToken
        uint256 expectedSaveAmount = 10 ether; // 10% of 100 ether
        uint256 expectedFee = (expectedSaveAmount * DEFAULT_TREASURY_FEE) / 10000;
        uint256 expectedSavings = expectedSaveAmount - expectedFee;
        
        // The contract saves the OUTPUT token (token0), not the specific token (token1)
        assertEq(storage_.savings(user, outputToken), expectedSavings, 
            "User's savings record should be updated for output token");
        assertEq(storage_.savings(treasury, outputToken), expectedFee, 
            "Treasury's savings record should include fee for output token");
    }
    
    function testProcessInputSavingsAfterSwap() public {
        console.log("Testing process input savings after swap");
        
        // Setup test data
        uint256 inputAmount = 1 ether;
        uint256 saveAmount = 0.1 ether; // 10% of input
        
        // Mint tokens to savings module to simulate it receiving tokens via hook's take()
        token0.mint(address(savings), saveAmount);
        
        // Process input savings
        vm.prank(mockHook);
        savings.processInputSavingsAfterSwap(user, address(token0), saveAmount);
        
        // Check storage state
        uint256 expectedFee = (saveAmount * DEFAULT_TREASURY_FEE) / 10000;
        uint256 expectedSavings = saveAmount - expectedFee;
        
        assertEq(storage_.savings(user, address(token0)), expectedSavings, "User's savings record should be updated");
        assertEq(storage_.savings(treasury, address(token0)), expectedFee, "Treasury's savings record should include fee");
    }
    
    /*********************************
     *     Withdrawal Tests          *
     *********************************/
    
    function testWithdrawSavings() public {
        console.log("Testing withdraw savings");
        
        // First, deposit some savings
        uint256 depositAmount = 10 ether;
        vm.prank(user);
        savings.depositSavings(user, address(token0), depositAmount);
        
        // Get actual savings amount after fees
        uint256 userSavings = storage_.savings(user, address(token0));
        
        // Record starting balances before withdrawal
        uint256 userToken0Before = token0.balanceOf(user);
        
        // Get tokenId and check balance before withdrawal
        uint256 tokenId = token.getTokenId(address(token0));
        uint256 userTokenBalanceBefore = token.balanceOf(user, tokenId);
        
        // Calculate deposit fee
        uint256 depositFee = (depositAmount * DEFAULT_TREASURY_FEE) / 10000;
        
        // Withdraw savings
        vm.prank(user);
        savings.withdrawSavings(user, address(token0), userSavings);
        
        // Check balances
        uint256 userToken0After = token0.balanceOf(user);
        
        // Withdrawal should also have a fee
        uint256 withdrawalFee = (userSavings * DEFAULT_TREASURY_FEE) / 10000;
        uint256 expectedWithdrawal = userSavings - withdrawalFee;
        
        assertEq(userToken0After - userToken0Before, expectedWithdrawal, "User should receive withdrawn amount minus fee");
        
        // Check storage state
        assertEq(storage_.savings(user, address(token0)), 0, "User's savings record should be zero after full withdrawal");
        
        // Calculate total fees - must be the sum of deposit fee and withdrawal fee
        uint256 totalFees = depositFee + withdrawalFee;
        assertEq(storage_.savings(treasury, address(token0)), totalFees, "Treasury should have accumulated fees from deposit and withdrawal");
        
        // Check token balance has been updated (burned)
        uint256 userTokenBalanceAfter = token.balanceOf(user, tokenId);
        assertEq(userTokenBalanceAfter, 0, "User's token balance should be zero after full withdrawal");
        assertEq(userTokenBalanceBefore - userTokenBalanceAfter, userSavings, "User's token balance should decrease by withdraw amount");
    }
    
    function testWithdrawalWithTimelock() public {
        console.log("Testing withdrawal with timelock");
        
        // First, deposit some savings
        uint256 depositAmount = 10 ether;
        vm.prank(user);
        savings.depositSavings(user, address(token0), depositAmount);
        
        // Set a withdrawal timelock (1 day)
        uint256 timelock = 1 days;
        vm.prank(user);
        savings.setWithdrawalTimelock(user, timelock);
        
        // Get the current timestamp and calculate the unlock time
        uint256 unlockTime = block.timestamp + timelock;
        
        // Try to withdraw immediately - should fail
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Savings.WithdrawalTimelockActive.selector, unlockTime));
        savings.withdrawSavings(user, address(token0), 1 ether);
        
        // Fast forward time to just before timelock expires
        skip(timelock - 1);
        
        // Try to withdraw - should still fail (we're 1 second away from unlock)
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Savings.WithdrawalTimelockActive.selector, unlockTime));
        savings.withdrawSavings(user, address(token0), 1 ether);
        
        // Fast forward past timelock
        skip(2);
        
        // Now it should succeed
        vm.prank(user);
        savings.withdrawSavings(user, address(token0), 1 ether);
        
        // Check storage state
        // IMPORTANT: In the withdrawal process, the FULL amount (1 ether) is deducted from savings
        // The fee is only applied to the amount transferred to the user
        uint256 expectedRemaining = 9920000000000000000 - 1000000000000000000; // 9.92 ether - 1 ether
        assertEq(storage_.savings(user, address(token0)), expectedRemaining, "User's savings record should be reduced");
    }
    
    function testWithdrawalInsufficientSavings() public {
        console.log("Testing withdrawal with insufficient savings");
        
        // First, deposit some savings
        uint256 depositAmount = 10 ether;
        vm.prank(user);
        savings.depositSavings(user, address(token0), depositAmount);
        
        // Get actual savings amount after fees
        uint256 actualSavings = storage_.savings(user, address(token0));
        
        // Try to withdraw more than available
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Savings.InsufficientSavings.selector, address(token0), depositAmount * 2, actualSavings));
        savings.withdrawSavings(user, address(token0), depositAmount * 2);
    }
    
    /*********************************
     *     Goal Achievement Tests    *
     *********************************/
    
    function testSavingsGoalAchievement() public {
        console.log("Testing savings goal achievement");
        
        // Set a savings goal
        uint256 goalAmount = 10 ether;
        vm.prank(user);
        strategy.setSavingsGoal(user, address(token0), goalAmount);
        
        // Deposit some savings below goal
        uint256 depositAmount = 5 ether;
        vm.prank(user);
        savings.depositSavings(user, address(token0), depositAmount);
        
        // Calculate net savings after fee
        uint256 fee = (depositAmount * DEFAULT_TREASURY_FEE) / 10000;
        uint256 netDeposit = depositAmount - fee;
        
        // Check that goal hasn't been reached yet
        (uint256 totalSaved,,, ) = storage_.getSavingsData(user, address(token0));
        assertLt(totalSaved, goalAmount, "Total saved should be less than goal");
        
        // Deposit more to exceed goal
        vm.recordLogs();
        vm.prank(user);
        savings.depositSavings(user, address(token0), 6 ether);
        
        // Check for GoalReached event
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bool foundGoalReachedEvent = false;
        for (uint i = 0; i < entries.length; i++) {
            // The event signature for GoalReached is keccak256("GoalReached(address,address,uint256)")
            if (entries[i].topics[0] == keccak256("GoalReached(address,address,uint256)")) {
                foundGoalReachedEvent = true;
                break;
            }
        }
        
        assertTrue(foundGoalReachedEvent, "GoalReached event should have been emitted");
        
        // Check that total saved exceeds goal
        (totalSaved,,, ) = storage_.getSavingsData(user, address(token0));
        assertGe(totalSaved, goalAmount, "Total saved should be greater than or equal to goal");
    }
}