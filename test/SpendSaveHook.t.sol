// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// Foundry libraries
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {HookMiner} from "lib/v4-periphery/test/libraries/HookMiner.t.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

// Our contracts
import {SpendSaveHook} from "../src/SpendSaveHook.sol";
import {SpendSaveStorage} from "../src/SpendSaveStorage.sol";
import {SavingStrategy} from "../src/SavingStrategy.sol";
import {Savings} from "../src/Savings.sol";
import {DCA} from "../src/DCA.sol";
import {SlippageControl} from "../src/SlippageControl.sol";
import {Token} from "../src/Token.sol";
import {DailySavings} from "../src/DailySavings.sol";

contract MockYieldModule {
    // Add an event so we can track calls to this function
    event YieldStrategyApplied(address user, address token);
    
    function applyYieldStrategy(address user, address token) external {
        emit YieldStrategyApplied(user, token);
    }
}

contract TestSpendSaveHook is SpendSaveHook {
    constructor(IPoolManager _poolManager, SpendSaveStorage _storage) 
        SpendSaveHook(_poolManager, _storage) {
        // Do nothing else - don't try to register with storage
    }
    
    // Override the hook permission validation to prevent errors during testing
    function validateHookPermissionsTest() external pure returns (Hooks.Permissions memory) {
        return getHookPermissions();
    }
    
    // Override initializeModules to skip _registerModulesWithStorage
    // Since we're already setting the modules in the test
    function initializeModules(
        address _strategyModule,
        address _savingsModule,
        address _dcaModule,
        address _slippageModule,
        address _tokenModule,
        address _dailySavingsModule
    ) external override {
        require(msg.sender == storage_.owner(), "Only owner can initialize modules");
        
        // Just store module references, don't try to register them with storage
        _storeModuleReferences(
            _strategyModule, 
            _savingsModule, 
            _dcaModule, 
            _slippageModule, 
            _tokenModule, 
            _dailySavingsModule
        );
        
        // Skip _registerModulesWithStorage since we already registered them in the test
        
        emit ModulesInitialized(_strategyModule, _savingsModule, _dcaModule, _slippageModule, _tokenModule, _dailySavingsModule);
    }
}

contract SpendSaveHookTest is Test, Deployers {
    // Use the libraries
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Main contracts
    SpendSaveHook hook;
    SpendSaveStorage storage_;
    
    // Module contracts
    SavingStrategy savingStrategyModule;
    Savings savingsModule;
    DCA dcaModule;
    SlippageControl slippageControlModule;
    Token tokenModule;
    DailySavings dailySavingsModule;
    MockYieldModule yieldModule;

    // The two currencies (tokens) from the pool
    Currency token0;
    Currency token1;
    
    // Additional test token
    Currency token2;

    // Users for testing
    address user1;
    address user2;
    address treasury;
    
    // PoolKey for our test pool
    PoolKey poolKey;


    function setUp() public {
        console.log("============ SETUP START ============");
        
        // Set up test users
        user1 = address(0x1);
        user2 = address(0x2);
        treasury = address(0x3);
        
        console.log("Deploying core contracts...");
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();
        
        // Deploy three test tokens
        MockERC20 mockToken0 = new MockERC20("Token0", "TK0", 18);
        MockERC20 mockToken1 = new MockERC20("Token1", "TK1", 18);
        MockERC20 mockToken2 = new MockERC20("Token2", "TK2", 18);
        
        token0 = Currency.wrap(address(mockToken0));
        token1 = Currency.wrap(address(mockToken1));
        token2 = Currency.wrap(address(mockToken2));
        
        // Mint tokens to test users
        mockToken0.mint(user1, 100 ether);
        mockToken1.mint(user1, 100 ether);
        mockToken2.mint(user1, 100 ether);
        
        mockToken0.mint(user2, 100 ether);
        mockToken1.mint(user2, 100 ether);
        mockToken2.mint(user2, 100 ether);
        
        // Mint tokens to test contract for adding liquidity
        mockToken0.mint(address(this), 1000 ether);
        mockToken1.mint(address(this), 1000 ether);
        mockToken2.mint(address(this), 1000 ether);
        
        console.log("Deploying storage...");
        // Deploy storage contract
        storage_ = new SpendSaveStorage(address(this), treasury, manager);
        
        console.log("Deploying modules...");
        // Deploy modules
        savingStrategyModule = new SavingStrategy();
        savingsModule = new Savings();
        dcaModule = new DCA();
        slippageControlModule = new SlippageControl();
        tokenModule = new Token();
        dailySavingsModule = new DailySavings();
        yieldModule = new MockYieldModule();
        
        // Register modules with storage
        vm.startPrank(address(this));
        storage_.setSavingStrategyModule(address(savingStrategyModule));
        storage_.setSavingsModule(address(savingsModule));
        storage_.setDCAModule(address(dcaModule));
        storage_.setSlippageControlModule(address(slippageControlModule));
        storage_.setTokenModule(address(tokenModule));
        storage_.setDailySavingsModule(address(dailySavingsModule));
        vm.stopPrank();
        
        console.log("Deploying hook using HookMiner...");
        // Calculate the hook address with the correct flags
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        
        // Use HookMiner to compute the proper hook address
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(TestSpendSaveHook).creationCode, // Use our test hook
            abi.encode(IPoolManager(address(manager)), storage_)
        );
        
        console.log("Hook address will be:", hookAddress);
        console.log("Flags:", uint160(hookAddress) & 0xFF);
        
        // Deploy the hook with the proper salt
        hook = new TestSpendSaveHook{salt: salt}(IPoolManager(address(manager)), storage_);
        
        console.log("Hook deployed at:", address(hook));
        console.log("Hook flags:", uint160(address(hook)) & 0xFF);
        
        // Explicitly set the hook in storage as the owner
        vm.startPrank(address(this));
        storage_.setSpendSaveHook(address(hook));
        vm.stopPrank();
        
        // Initialize modules
        vm.startPrank(address(this));
        savingStrategyModule.initialize(storage_);
        savingsModule.initialize(storage_);
        dcaModule.initialize(storage_);
        slippageControlModule.initialize(storage_);
        tokenModule.initialize(storage_);
        dailySavingsModule.initialize(storage_);
        
        // Set module references
        savingStrategyModule.setModuleReferences(address(savingsModule));
        savingsModule.setModuleReferences(address(tokenModule), address(savingStrategyModule));
        dcaModule.setModuleReferences(address(tokenModule), address(slippageControlModule));
        dailySavingsModule.setModuleReferences(address(tokenModule), address(yieldModule));
        vm.stopPrank();
        
        // Initialize the hook
        vm.startPrank(address(this));
        hook.initializeModules(
            address(savingStrategyModule),
            address(savingsModule),
            address(dcaModule),
            address(slippageControlModule),
            address(tokenModule),
            address(dailySavingsModule)
        );
        vm.stopPrank();
        
        // Approve tokens for router and hook
        mockToken0.approve(address(swapRouter), type(uint256).max);
        mockToken1.approve(address(swapRouter), type(uint256).max);
        mockToken2.approve(address(swapRouter), type(uint256).max);
        
        mockToken0.approve(address(hook), type(uint256).max);
        mockToken1.approve(address(hook), type(uint256).max);
        mockToken2.approve(address(hook), type(uint256).max);
        
        // User approvals
        vm.startPrank(user1);
        mockToken0.approve(address(swapRouter), type(uint256).max);
        mockToken1.approve(address(swapRouter), type(uint256).max);
        mockToken2.approve(address(swapRouter), type(uint256).max);
        mockToken0.approve(address(hook), type(uint256).max);
        mockToken1.approve(address(hook), type(uint256).max);
        mockToken2.approve(address(hook), type(uint256).max);
        vm.stopPrank();
        
        vm.startPrank(user2);
        mockToken0.approve(address(swapRouter), type(uint256).max);
        mockToken1.approve(address(swapRouter), type(uint256).max);
        mockToken2.approve(address(swapRouter), type(uint256).max);
        mockToken0.approve(address(hook), type(uint256).max);
        mockToken1.approve(address(hook), type(uint256).max);
        mockToken2.approve(address(hook), type(uint256).max);
        vm.stopPrank();
        
        console.log("============ SETUP COMPLETE ============");

        initializeTestPool();
    }
    
    // Test that setup worked properly
    function testSetup() public {
        assertTrue(address(hook) != address(0), "Hook not deployed");
        assertTrue(address(storage_) != address(0), "Storage not deployed");
        
        // Check hook flags
        uint160 expectedFlags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        uint160 actualFlags = uint160(address(hook)) & 0xFF;
        assertTrue((actualFlags & expectedFlags) == expectedFlags, "Hook address doesn't have required flags");
        
        console.log("Setup test passed!");
    }


    function initializeTestPool() internal returns (PoolKey memory, PoolId) {
        console.log("Initializing test pool with hook...");
        
        // Call initPool directly since it's an internal function
        (PoolKey memory key, PoolId poolId) = initPool(
            token0, 
            token1, 
            IHooks(address(hook)),
            3000,
            SQRT_PRICE_1_1
        );
        console.log("Pool initialized successfully");
        
        // Make sure tokens are approved to both manager AND modifyLiquidityRouter
        MockERC20(Currency.unwrap(token0)).approve(address(manager), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(manager), type(uint256).max);
        MockERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouter), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(modifyLiquidityRouter), type(uint256).max);
        
        // Mint additional tokens to ensure we have enough
        MockERC20(Currency.unwrap(token0)).mint(address(this), 100 ether);
        MockERC20(Currency.unwrap(token1)).mint(address(this), 100 ether);
        
        // Use the standard full tick range instead of arbitrary values
        int24 minUsableTick = TickMath.minUsableTick(60);
        int24 maxUsableTick = TickMath.maxUsableTick(60);
        
        try modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: minUsableTick,
                tickUpper: maxUsableTick,
                liquidityDelta: 10, // Very small amount
                salt: bytes32(0)
            }),
            ZERO_BYTES // Using empty bytes for hookData
        ) {
            console.log("Liquidity added successfully");
        } catch Error(string memory reason) {
            console.log("Failed to add liquidity:", reason);
        } catch {
            console.log("Failed to add liquidity (unknown error)");
        }
        
        // Store the key for later use
        poolKey = key;
        
        return (key, poolId);
    }
}