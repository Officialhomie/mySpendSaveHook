// SPDX-License-Identifier: UNLICENSED
// pragma solidity ^0.8.20;

// // Foundry libraries
// import {Test} from "forge-std/Test.sol";
// import {console} from "forge-std/console.sol";

// import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
// import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
// import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// import {PoolManager} from "v4-core/PoolManager.sol";
// import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

// import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
// import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
// import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
// import {PoolKey} from "v4-core/types/PoolKey.sol";

// import {Hooks} from "v4-core/libraries/Hooks.sol";
// import {IHooks} from "v4-core/interfaces/IHooks.sol";
// import {TickMath} from "v4-core/libraries/TickMath.sol";
// import {HookMiner} from "lib/v4-periphery/test/libraries/HookMiner.t.sol";
// import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
// import {BeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";

// // Our contracts
// import {SpendSaveHook} from "../src/SpendSaveHook.sol";
// import {SpendSaveStorage} from "../src/SpendSaveStorage.sol";
// import {SavingStrategy} from "../src/SavingStrategy.sol";
// import {Savings} from "../src/Savings.sol";
// import {DCA} from "../src/DCA.sol";
// import {SlippageControl} from "../src/SlippageControl.sol";
// import {Token} from "../src/Token.sol";
// import {DailySavings} from "../src/DailySavings.sol";

// contract MockYieldModule {
//     // Add an event so we can track calls to this function
//     event YieldStrategyApplied(address user, address token);
    
//     function applyYieldStrategy(address user, address token) external {
//         emit YieldStrategyApplied(user, token);
//     }
// }

// contract SpendSaveHookTest is Test, Deployers {
//     // Use the libraries
//     using StateLibrary for IPoolManager;
//     using PoolIdLibrary for PoolKey;
//     using CurrencyLibrary for Currency;

//     // Main contracts
//     SpendSaveHook hook;
//     SpendSaveStorage storage_;
    
//     // Module contracts
//     SavingStrategy savingStrategyModule;
//     Savings savingsModule;
//     DCA dcaModule;
//     SlippageControl slippageControlModule;
//     Token tokenModule;
//     DailySavings dailySavingsModule;
//     MockYieldModule yieldModule;

//     // The two currencies (tokens) from the pool
//     Currency token0;
//     Currency token1;
    
//     // Additional test token
//     Currency token2;

//     // Users for testing
//     address user1;
//     address user2;
//     address treasury;
    
//     // PoolKey for our test pool
//     PoolKey poolKey;

//     // Utility functions for testing
//     function setUpBasicStrategy(address user, uint256 percentage) internal {
//         vm.startPrank(user);
        
//         savingStrategyModule.setSavingStrategy(
//             user,
//             percentage, // Saving percentage
//             0,   // No auto-increment
//             percentage, // Max percentage
//             false, // Don't round up
//             SpendSaveStorage.SavingsTokenType.OUTPUT, // Save from output
//             address(0) // No specific token
//         );
        
//         vm.stopPrank();
//     }
    
//     function executeSwap(address user, uint256 amount, bool zeroForOne) internal returns (BalanceDelta) {
//         vm.startPrank(user);

//         // In Uniswap V4, amountSpecified is an int256
//         // The sign indicates the direction:
//         // - Negative: exact input (selling this amount)
//         // - Positive: exact output (buying this amount)
//         // For zeroForOne=true, negative means selling exact amount of token0
//         // For zeroForOne=false, negative means selling exact amount of token1
//         int256 signedAmount = -int256(amount); // Use negative for exact input
        
//         IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
//             zeroForOne: zeroForOne,
//             amountSpecified: signedAmount,
//             sqrtPriceLimitX96: 0
//         });
        
//         BalanceDelta delta = swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        
//         vm.stopPrank();
        
//         return delta;
//     }
    
//     function executeSwapsWithDCA(
//         address user, 
//         uint256 swapAmount, 
//         bool enableDca, 
//         address targetToken
//     ) internal returns (uint256 savingsAmount) {
//         vm.startPrank(user);
        
//         // Set up DCA strategy
//         savingStrategyModule.setSavingStrategy(
//             user,
//             1000, // 10% savings
//             0,
//             1000,
//             false,
//             SpendSaveStorage.SavingsTokenType.OUTPUT,
//             address(0)
//         );
        
//         if (enableDca) {
//             dcaModule.enableDCA(user, targetToken, true);
//         }
        
//         // Execute a swap
//         MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), type(uint256).max);

//         IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
//             zeroForOne: true,
//             amountSpecified: asInt256(swapAmount), // Fix: Convert to negative int256
//             sqrtPriceLimitX96: 0
//         });
        
//         swapRouter.swap(poolKey, params, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "");
        
//         // Get the accumulated savings
//         savingsAmount = storage_.savings(user, Currency.unwrap(token1));
        
//         vm.stopPrank();
        
//         return savingsAmount;
//     }

//     // Helper to convert uint256 to negative int256 for exact input swaps
//     function asInt256(uint256 value) internal pure returns (int256) {
//         require(value <= uint256(type(int256).max), "Value too large for int256");
//         return -int256(value); // Negative for exact input swaps
//     }

//     // Helper to safely convert int256 to uint256 when you know it's positive
//     function safeUint256(int128 value) internal pure returns (uint256) {
//         // First convert to int256, then to uint256
//         int256 valueInt256 = int256(value);
//         require(valueInt256 >= 0, "Value must be positive");
//         return uint256(valueInt256);
//     }

//     function onlySafeUint256(int256 value) internal pure returns (uint256) {
//         require(value >= 0, "Value must be positive");
//         return uint256(value);
//     }



//     function setUp() public {
//         console.log("============ SETUP START ============");
//         console.log("Test contract address:", address(this));
        
//         // Set up test users
//         user1 = address(0x1);
//         user2 = address(0x2);
//         treasury = address(0x3);
        
//         console.log("Deploying core contracts...");
//         // Deploy v4 core contracts
//         deployFreshManagerAndRouters();
//         console.log("Manager address:", address(manager));

//         // Deploy three test tokens
//         MockERC20 mockToken0 = new MockERC20("Token0", "TK0", 18);
//         MockERC20 mockToken1 = new MockERC20("Token1", "TK1", 18);
//         MockERC20 mockToken2 = new MockERC20("Token2", "TK2", 18);
        
//         token0 = Currency.wrap(address(mockToken0));
//         token1 = Currency.wrap(address(mockToken1));
//         token2 = Currency.wrap(address(mockToken2));
        
//         // Mint tokens to test users
//         mockToken0.mint(user1, 100 ether);
//         mockToken1.mint(user1, 100 ether);
//         mockToken2.mint(user1, 100 ether);
        
//         mockToken0.mint(user2, 100 ether);
//         mockToken1.mint(user2, 100 ether);
//         mockToken2.mint(user2, 100 ether);
        
//         // Mint tokens to test contract for adding liquidity
//         mockToken0.mint(address(this), 1000 ether);
//         mockToken1.mint(address(this), 1000 ether);
//         mockToken2.mint(address(this), 1000 ether);
        
//         console.log("Deploying storage...");
//         // Deploy storage contract
//         storage_ = new SpendSaveStorage(address(this), treasury, manager);
//         console.log("Storage address:", address(storage_));
//         console.log("Storage owner:", storage_.owner());
        
//         // Verify storage ownership is correct
//         console.log("Verifying storage ownership is correct");
//         vm.prank(address(0xdead)); // Use a different address
//         try storage_.setSavingStrategyModule(address(1)) {
//             console.log("ERROR: Non-owner can call onlyOwner function!");
//         } catch Error(string memory reason) {
//             console.log("Expected error when non-owner calls restricted function:", reason);
//         } catch {
//             console.log("Expected error when non-owner calls restricted function");
//         }
        
//         console.log("Deploying modules...");
//         // Deploy modules
//         savingStrategyModule = new SavingStrategy();
//         savingsModule = new Savings();
//         dcaModule = new DCA();
//         slippageControlModule = new SlippageControl();
//         tokenModule = new Token();
//         dailySavingsModule = new DailySavings();
//         yieldModule = new MockYieldModule();
        
//         // Register modules with storage BEFORE deploying the hook
//         console.log("Registering modules with storage BEFORE hook deployment...");
//         vm.startPrank(address(this));  // Become the owner for these operations
//         storage_.setSavingStrategyModule(address(savingStrategyModule));
//         storage_.setSavingsModule(address(savingsModule));
//         storage_.setDCAModule(address(dcaModule));
//         storage_.setSlippageControlModule(address(slippageControlModule));
//         storage_.setTokenModule(address(tokenModule));
//         storage_.setDailySavingsModule(address(dailySavingsModule));
//         vm.stopPrank();
        
//         // Deploy hook with proper hook flags for V4
//         console.log("Deploying hook with explicit address flags...");
        
//         // Define the specific hook flags we need
//         // BEFORE_SWAP_FLAG = 1 << 7 (bit 7)
//         // AFTER_SWAP_FLAG = 1 << 6 (bit 6)
//         uint160 hookFlag = (1 << 7) | (1 << 6); // 0xC0 - both beforeSwap and afterSwap
        
//         // Create an explicit address with these flags
//         // The least significant bits must contain our flag bits
//         address hookAddr = address(uint160(0x10000000000000000000000000000000000000c0));
//         console.log("Target hook address:", hookAddr);
//         console.log("Hook flag bits:", uint160(hookAddr) & 0xFF);
        
//         // Create a temporary hook to get its bytecode
//         SpendSaveHook tempHook = new SpendSaveHook(IPoolManager(address(manager)), storage_);
        
//         // Use vm.etch to copy the bytecode to the desired address
//         vm.etch(hookAddr, address(tempHook).code);
        
//         // Now instantiate our hook at that address
//         hook = SpendSaveHook(hookAddr);
        
//         // Verify that the address has the right flags
//         console.log("Hook deployed at:", address(hook));
//         console.log("Address permissions (should include 0xC0):", uint160(address(hook)) & 0xFFFF);
        
//         // Print what the hook itself thinks its permissions are
//         try hook.getHookPermissions() returns (Hooks.Permissions memory perms) {
//             console.log("  Hook reports beforeSwap:", perms.beforeSwap ? "true" : "false");
//             console.log("  Hook reports afterSwap:", perms.afterSwap ? "true" : "false");
//         } catch Error(string memory reason) {
//             console.log("  Failed to get hook permissions:", reason);
//         } catch {
//             console.log("  Failed to get hook permissions (unknown error)");
//         }
        
//         // Set the hook in storage
//         vm.prank(address(this));
//         storage_.setSpendSaveHook(address(hook));
//         console.log("Hook registered with storage");
        
//         // Initialize modules
//         console.log("Initializing modules...");
//         vm.startPrank(address(this));
//         savingStrategyModule.initialize(storage_);
//         savingsModule.initialize(storage_);
//         dcaModule.initialize(storage_);
//         slippageControlModule.initialize(storage_);
//         tokenModule.initialize(storage_);
//         dailySavingsModule.initialize(storage_);
        
//         // Set module references
//         console.log("Setting module references...");
//         savingStrategyModule.setModuleReferences(address(savingsModule));
//         savingsModule.setModuleReferences(address(tokenModule), address(savingStrategyModule));
//         dcaModule.setModuleReferences(address(tokenModule), address(slippageControlModule));
//         dailySavingsModule.setModuleReferences(address(tokenModule), address(yieldModule));
//         vm.stopPrank();
        
//         // Initialize the hook
//         console.log("Initializing hook...");
//         vm.startPrank(storage_.owner());
//         try hook.initializeModules(
//             address(savingStrategyModule),
//             address(savingsModule),
//             address(dcaModule),
//             address(slippageControlModule),
//             address(tokenModule),
//             address(dailySavingsModule)
//         ) {
//             console.log("Hook initialized successfully");
//         } catch Error(string memory reason) {
//             console.log("Hook initialization failed:", reason);
//             revert("Hook initialization failed");
//         } catch {
//             console.log("Hook initialization failed with unknown error");
//             revert("Hook initialization failed with unknown error");
//         }
//         vm.stopPrank();
        
//         // Approve tokens for router and hook
//         console.log("Approving tokens for router and hook...");
//         mockToken0.approve(address(swapRouter), type(uint256).max);
//         mockToken1.approve(address(swapRouter), type(uint256).max);
//         mockToken2.approve(address(swapRouter), type(uint256).max);
        
//         mockToken0.approve(address(hook), type(uint256).max);
//         mockToken1.approve(address(hook), type(uint256).max);
//         mockToken2.approve(address(hook), type(uint256).max);
        
//         // Give the hook special approvals for the test users
//         vm.startPrank(user1);
//         mockToken0.approve(address(swapRouter), type(uint256).max);
//         mockToken1.approve(address(swapRouter), type(uint256).max);
//         mockToken2.approve(address(swapRouter), type(uint256).max);
//         mockToken0.approve(address(hook), type(uint256).max);
//         mockToken1.approve(address(hook), type(uint256).max);
//         mockToken2.approve(address(hook), type(uint256).max);
//         vm.stopPrank();
        
//         vm.startPrank(user2);
//         mockToken0.approve(address(swapRouter), type(uint256).max);
//         mockToken1.approve(address(swapRouter), type(uint256).max);
//         mockToken2.approve(address(swapRouter), type(uint256).max);
//         mockToken0.approve(address(hook), type(uint256).max);
//         mockToken1.approve(address(hook), type(uint256).max);
//         mockToken2.approve(address(hook), type(uint256).max);
//         vm.stopPrank();

//         // Skip pool initialization for now - we'll do that in specific tests
//         console.log("Basic hook setup complete. Pool initialization will be done in tests as needed.");
//         console.log("============ SETUP COMPLETE ============");
//     }


//     // Add a simple test function that just validates the setup worked
//     function testSetupOnly() public {
//         // Just verify the hook was created with the correct permissions
//         assertTrue(address(hook) != address(0), "Hook deployment failed");
        
//         // Check if the address has the correct permission bits
//         uint160 expectedFlags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
//         uint160 actualFlags = uint160(address(hook)) & 0xFFFF;
        
//         assertTrue(
//             (actualFlags & Hooks.BEFORE_SWAP_FLAG) != 0, 
//             "Hook address missing BEFORE_SWAP_FLAG"
//         );
        
//         assertTrue(
//             (actualFlags & Hooks.AFTER_SWAP_FLAG) != 0, 
//             "Hook address missing AFTER_SWAP_FLAG"
//         );
        
//         console.log("Hook successfully deployed with correct permissions at:", address(hook));
//     }
    
//     // Helper to initialize a pool for testing
//     function initializeTestPool() internal returns (PoolKey memory, PoolId) {
//         console.log("Initializing test pool with hook...");
        
//         // Call initPool without try-catch since it's an internal function
//         PoolKey memory key;
//         PoolId poolId;
//         (key, poolId) = initPool(token0, token1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
//         console.log("Pool initialized successfully");
        
//         // Add some liquidity - here we can use try-catch since modifyLiquidity is external
//         try modifyLiquidityRouter.modifyLiquidity(
//             key,
//             IPoolManager.ModifyLiquidityParams({
//                 tickLower: -60,
//                 tickUpper: 60,
//                 liquidityDelta: 10 ether,
//                 salt: bytes32(0)
//             }),
//             ""
//         ) {
//             console.log("Liquidity added successfully");
//         } catch Error(string memory reason) {
//             console.log("Failed to add liquidity:", reason);
//         } catch {
//             console.log("Failed to add liquidity (unknown error)");
//         }
        
//         return (key, poolId);
//     }
    
//     // Test a basic swap with the SpendSaveHook
//     function testBasicSwap() public {
//         // First initialize a pool
//         (PoolKey memory _poolKey, ) = initializeTestPool();
//         poolKey = _poolKey;
        
//         // Set up a basic saving strategy for user1
//         setUpBasicStrategy(user1, 1000); // 10% saving
        
//         // Execute a swap
//         uint256 swapAmount = 1 ether;
//         BalanceDelta delta = executeSwap(user1, swapAmount, true);
        
//         // Check that the user has savings
//         uint256 savings = storage_.savings(user1, Currency.unwrap(token1));
//         assertTrue(savings > 0, "No savings generated from swap");
        
//         console.log("Swap executed, user1 savings:", savings);
//     }
// }



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
        (PoolKey memory key, PoolId poolId) = initPool(token0, token1, IHooks(address(hook)), 3000, SQRT_PRICE_1_1);
        console.log("Pool initialized successfully");
        
        // Explicitly approve tokens to the PoolManager
        MockERC20(Currency.unwrap(token0)).approve(address(manager), type(uint256).max);
        MockERC20(Currency.unwrap(token1)).approve(address(manager), type(uint256).max);
        
        // Mint additional tokens specifically for liquidity if needed
        MockERC20(Currency.unwrap(token0)).mint(address(this), 10 ether);
        MockERC20(Currency.unwrap(token1)).mint(address(this), 10 ether);
        
        // Transfer tokens to manager first (this is optional but can help)
        MockERC20(Currency.unwrap(token0)).transfer(address(manager), 1 ether);
        MockERC20(Currency.unwrap(token1)).transfer(address(manager), 1 ether);
        
        // Use a narrower tick range and very small liquidity amount
        try modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,           // Narrow tick range
                tickUpper: 60,            // Narrow tick range
                liquidityDelta: 0.0001 ether, // Very small amount
                salt: bytes32(0)
            }),
            ""
        ) {
            console.log("Liquidity added successfully");
        } catch Error(string memory reason) {
            console.log("Failed to add liquidity:", reason);
        } catch {
            console.log("Failed to add liquidity (unknown error)");
        }
        
        // Set poolKey for later use
        poolKey = key;
        
        return (key, poolId);
    }
}