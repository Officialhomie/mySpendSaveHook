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
import {Savings} from "../src/Savings.sol";
import {SavingStrategy} from "../src/SavingStrategy.sol";
import {Token} from "../src/Token.sol";
import {DCA} from "../src/DCA.sol";
import {DailySavings} from "../src/DailySavings.sol";
import {SlippageControl} from "../src/SlippageControl.sol";

/**
 * @title Basic Swap Test
 * @notice Simple test to verify the SpendSave protocol's swap functionality integration
 * @dev Focus on testing hook integration and savings mechanism
 */
contract BasicSwapTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    // Test Infrastructure
    SpendSaveHook public hook;
    SpendSaveStorage public storageContract;
    
    // Modules
    Savings public savingsModule;
    SavingStrategy public strategyModule;
    Token public tokenModule;
    DCA public dcaModule;
    DailySavings public dailySavingsModule;
    SlippageControl public slippageModule;
    
    // Test Tokens
    MockERC20 public token0;
    MockERC20 public token1;
    
    // Test Users
    address public owner;
    address public treasury;
    address public alice;
    
    // Pool Configuration
    PoolKey public poolKey;
    uint24 public constant POOL_FEE = 3000;
    int24 public constant TICK_SPACING = 60;
    uint160 public constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    function setUp() public {
        // Setup test accounts
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        alice = makeAddr("alice");
        
        // Start as owner for contract deployment
        vm.startPrank(owner);
        
        // Deploy Uniswap V4 infrastructure using Deployers
        deployFreshManager();
        
        // Deploy test tokens
        token0 = new MockERC20("Token A", "TKNA", 18);
        token1 = new MockERC20("Token B", "TKNB", 18);
        
        // Ensure token0 < token1 for proper ordering
        if (address(token1) < address(token0)) {
            (token0, token1) = (token1, token0);
        }
        
        // Deploy SpendSave protocol
        _deploySpendSaveProtocol();
        
        // Initialize pool
        _initializePool();
        
        // Setup test balances
        _setupTestBalances();
        
        vm.stopPrank();
    }
    
    function _deploySpendSaveProtocol() internal {
        // Deploy storage contract
        storageContract = new SpendSaveStorage(address(manager));
        
        // Deploy modules
        savingsModule = new Savings();
        strategyModule = new SavingStrategy();
        tokenModule = new Token();
        dcaModule = new DCA();
        dailySavingsModule = new DailySavings();
        slippageModule = new SlippageControl();
        
        // Deploy hook with proper address mining
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        (address hookAddress, bytes32 salt) = HookMiner.find(
            owner, // Use owner as deployer since we're pranking as owner
            flags,
            type(SpendSaveHook).creationCode,
            abi.encode(IPoolManager(address(manager)), storageContract)
        );
        hook = new SpendSaveHook{salt: salt}(IPoolManager(address(manager)), storageContract);
        
        require(address(hook) == hookAddress, "Hook deployed at wrong address");
        
        // Initialize contracts
        storageContract.initialize(address(hook));
        savingsModule.initialize(storageContract);
        strategyModule.initialize(storageContract);
        tokenModule.initialize(storageContract);
        dcaModule.initialize(storageContract);
        dailySavingsModule.initialize(storageContract);
        slippageModule.initialize(storageContract);
        
        // Register modules
        _registerModules();
    }
    
    function _registerModules() internal {
        storageContract.registerModule(keccak256("SAVINGS"), address(savingsModule));
        storageContract.registerModule(keccak256("STRATEGY"), address(strategyModule));
        storageContract.registerModule(keccak256("TOKEN"), address(tokenModule));
        storageContract.registerModule(keccak256("DCA"), address(dcaModule));
        storageContract.registerModule(keccak256("DAILY_SAVINGS"), address(dailySavingsModule));
        storageContract.registerModule(keccak256("SLIPPAGE"), address(slippageModule));
    }
    
    function _initializePool() internal {
        // Create pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });
        
        // Initialize pool with 1:1 price
        manager.initialize(poolKey, SQRT_RATIO_1_1);
    }
    
    function _setupTestBalances() internal {
        // Mint 10,000 of each token to Alice
        token0.mint(alice, 10_000 ether);
        token1.mint(alice, 10_000 ether);
        
        vm.startPrank(alice);
        // Approve various contracts for token transfers
        token0.approve(address(hook), type(uint256).max);
        token1.approve(address(hook), type(uint256).max);
        token0.approve(address(manager), type(uint256).max);
        token1.approve(address(manager), type(uint256).max);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           BASIC FUNCTIONALITY TESTS
    //////////////////////////////////////////////////////////////*/

    function testProtocolDeployment() public {
        // Test that all contracts deployed successfully
        assertTrue(address(hook) != address(0), "Hook should be deployed");
        assertTrue(address(storageContract) != address(0), "Storage should be deployed");
        assertTrue(address(savingsModule) != address(0), "Savings module should be deployed");
        assertTrue(address(strategyModule) != address(0), "Strategy module should be deployed");
        
        // Test that hook has correct permissions
        assertTrue(hook.getHookPermissions().beforeSwap, "Should have beforeSwap permission");
        assertTrue(hook.getHookPermissions().afterSwap, "Should have afterSwap permission");
        
        // Test that modules are properly registered
        assertTrue(storageContract.isAuthorizedModule(address(savingsModule)), "Savings module should be registered");
        assertTrue(storageContract.isAuthorizedModule(address(strategyModule)), "Strategy module should be registered");
    }
    
    function testSavingsStrategyConfiguration() public {
        vm.startPrank(alice);
        
        // Test setting savings strategy
        strategyModule.setSavingStrategy(
            alice,
            1000, // 10%
            0,    // autoIncrement
            10000, // maxPercentage (100%)
            false, // no round up
            SpendSaveStorage.SavingsTokenType.INPUT, // INPUT token type
            address(0) // no specific token
        );
        
        // Verify strategy was set
        (uint256 percentage, bool roundUpSavings, uint8 savingsTokenType, bool enableDCA) = 
            storageContract.getPackedUserConfig(alice);
            
        assertEq(percentage, 1000, "Should have 10% savings percentage");
        assertEq(roundUpSavings, false, "Should not have round up");
        assertEq(savingsTokenType, 0, "Should be INPUT token type");
        assertEq(enableDCA, false, "Should not have DCA enabled");
        
        vm.stopPrank();
    }
    
    function testDirectSavingsOperation() public {
        // Test direct savings operations bypassing swap
        uint256 amount = 100 ether;
        
        vm.startPrank(address(savingsModule));
        
        // Test increaseSavings
        storageContract.increaseSavings(alice, address(token0), amount);
        
        // Verify savings balance (accounting for treasury fee)
        uint256 treasuryFee = storageContract.treasuryFee();
        uint256 netAmount = amount - (amount * treasuryFee) / 10000;
        
        assertEq(storageContract.savings(alice, address(token0)), netAmount, "Should have correct savings balance");
        
        // Verify token tracking
        address[] memory userTokens = storageContract.getUserSavingsTokens(alice);
        assertEq(userTokens.length, 1, "Should have 1 savings token");
        assertEq(userTokens[0], address(token0), "Should track correct token");
        
        vm.stopPrank();
    }
    
    function testHookInitialization() public {
        // Test that hook properly integrates with the pool
        assertTrue(address(poolKey.hooks) == address(hook), "Pool should use our hook");
        
        // Test hook storage integration
        assertEq(address(hook.storage_()), address(storageContract), "Hook should reference correct storage");
        
        // Test hook permissions
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeSwap, "Should have beforeSwap permission");
        assertTrue(permissions.afterSwap, "Should have afterSwap permission");
        
    }
    
    function testTreasuryFeeCalculation() public {
        uint256 amount = 1000 ether;
        uint256 savingsPercentage = 1000; // 10%
        
        vm.startPrank(alice);
        
        // Configure savings
        strategyModule.setSavingStrategy(
            alice, 
            savingsPercentage, 
            0,    // autoIncrement
            10000, // maxPercentage
            false, // roundUp
            SpendSaveStorage.SavingsTokenType.INPUT,
            address(0)
        );
        
        vm.stopPrank();
        vm.startPrank(address(savingsModule));
        
        // Process savings
        storageContract.increaseSavings(alice, address(token0), amount);
        
        // Calculate expected values
        uint256 treasuryFee = storageContract.treasuryFee(); // Default 10 basis points (0.1%)
        uint256 feeAmount = (amount * treasuryFee) / 10000;
        uint256 netUserSavings = amount - feeAmount;
        
        // Verify correct distribution
        assertEq(storageContract.savings(alice, address(token0)), netUserSavings, "User should have net savings");
        assertEq(storageContract.savings(storageContract.treasury(), address(token0)), feeAmount, "Treasury should have fee");
        
        vm.stopPrank();
    }
    
    function testModuleInteraction() public {
        // Test cross-module interaction through storage
        vm.startPrank(alice);
        
        // Set up savings strategy
        strategyModule.setSavingStrategy(
            alice, 
            1000, 
            0,     // autoIncrement
            10000, // maxPercentage
            false, // roundUp
            SpendSaveStorage.SavingsTokenType.INPUT,
            address(0)
        );
        
        vm.stopPrank();
        vm.startPrank(address(savingsModule));
        
        // Create savings
        storageContract.increaseSavings(alice, address(token0), 100 ether);
        
        vm.stopPrank();
        vm.startPrank(address(tokenModule));
        
        // Set token ID mapping
        storageContract.setTokenToId(address(token0), 1);
        storageContract.setIdToToken(1, address(token0));
        
        // Create token balance
        storageContract.setBalance(alice, 1, 100 ether);
        
        // Verify cross-module data consistency
        assertEq(storageContract.tokenToId(address(token0)), 1, "Should have correct token ID");
        assertEq(storageContract.idToToken(1), address(token0), "Should have correct token address");
        assertEq(storageContract.getBalance(alice, 1), 100 ether, "Should have correct token balance");
        
        vm.stopPrank();
    }
    
    function testGasEfficiencyTargets() public {
        uint256 amount = 100 ether;
        
        vm.startPrank(alice);
        
        // Configure savings strategy
        strategyModule.setSavingStrategy(
            alice, 
            1000, 
            0,     // autoIncrement
            10000, // maxPercentage
            false, // roundUp
            SpendSaveStorage.SavingsTokenType.INPUT,
            address(0)
        );
        
        vm.stopPrank();
        vm.startPrank(address(savingsModule));
        
        // Test gas usage for key operations
        uint256 gasBefore = gasleft();
        storageContract.increaseSavings(alice, address(token0), amount);
        uint256 gasUsed = gasBefore - gasleft();
        
        assertTrue(gasUsed < 110000, "increaseSavings should be gas efficient");
        
        // Test packed storage read efficiency
        gasBefore = gasleft();
        storageContract.getPackedUserConfig(alice);
        gasUsed = gasBefore - gasleft();
        
        assertTrue(gasUsed < 5000, "Packed storage read should be very efficient");
        
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                           HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    function _logProtocolState() internal view {
        // Could be used for debugging protocol state if needed
    }
}