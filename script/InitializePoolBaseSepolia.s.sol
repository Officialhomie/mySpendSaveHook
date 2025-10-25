// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

// Uniswap V4 imports
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

/**
 * @title InitializePoolBaseSepolia
 * @notice Initialize USDC/WETH pool on Base Sepolia and add liquidity
 */
contract InitializePoolBaseSepolia is Script {
    
    using CurrencyLibrary for Currency;
    
    // Base Sepolia addresses
    IPoolManager constant POOL_MANAGER = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    address constant POSITION_MANAGER = 0x33E61BCa1cDa979E349Bf14840BD178Cc7d0F55D;
    
    // Tokens
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    
    // Your deployed hook (from Base Sepolia deployment)
    address constant HOOK = 0xc4ABf9A7bf8300086BBad164b4c47B1Afbbf00Cc; // NEW SpendSave Hook
    
    // Test helpers
    PoolSwapTest public swapRouter;
    PoolModifyLiquidityTest public liquidityRouter;
    
    // Constants from Uniswap tests
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // Price = 1:1
    bytes constant ZERO_BYTES = new bytes(0);
    
    address public user;
    
    function run() external {
        user = msg.sender;
        
        console.log("=== Initializing USDC/WETH Pool on Base Sepolia ===");
        console.log("User:", user);
        console.log("Pool Manager:", address(POOL_MANAGER));
        
        // Check balances
        uint256 ethBalance = user.balance;
        uint256 usdcBalance = IERC20(USDC).balanceOf(user);
        
        console.log("\nYour balances:");
        console.log("  ETH:", ethBalance);
        console.log("  USDC:", usdcBalance);
        
        require(ethBalance >= 0.001 ether, "Need at least 0.001 ETH");
        require(usdcBalance >= 2e6, "Need at least 2 USDC");
        
        vm.startBroadcast();
        
        // Build pool key - currencies must be in order (currency0 < currency1)
        // USDC (0x036C...) < WETH (0x4200...), so USDC is currency0
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(USDC),      // USDC is currency0 (lower address)
            currency1: Currency.wrap(WETH),      // WETH is currency1
            fee: 3000,                            // 0.3% fee
            tickSpacing: 60,
            hooks: IHooks(HOOK)                   // No hook for now
        });
        
        console.log("\nPool configuration:");
        console.log("  Currency0 (USDC):", Currency.unwrap(key.currency0));
        console.log("  Currency1 (WETH):", Currency.unwrap(key.currency1));
        console.log("  Fee: 0.3% (3000)");
        console.log("  Tick Spacing: 60");
        console.log("  Hook:", address(key.hooks));
        
        // Step 1: Deploy helper contracts
        console.log("\n=== Step 1: Deploying Helper Contracts ===");
        swapRouter = new PoolSwapTest(POOL_MANAGER);
        liquidityRouter = new PoolModifyLiquidityTest(POOL_MANAGER);
        console.log("SwapRouter deployed:", address(swapRouter));
        console.log("LiquidityRouter deployed:", address(liquidityRouter));
        
        // Step 2: Initialize the pool
        console.log("\n=== Step 2: Initializing Pool ===");
        console.log("Initializing with SQRT_PRICE_1_1 (1:1 ratio)");
        
        try POOL_MANAGER.initialize(key, SQRT_PRICE_1_1) returns (int24 tick) {
            console.log("Pool initialized successfully!");
            console.log("Initial tick:", tick);
        } catch {
            // Pool already initialized - this is GOOD!
            console.log("Pool already initialized - SKIPPING to liquidity!");
        }
        
        // Step 3: Add liquidity
        console.log("\n=== Step 3: Adding Liquidity ===");
        
        // Wrap ETH to WETH
        uint256 wethAmount = 0.001 ether; // Small amount for testing
        console.log("Wrapping", wethAmount, "ETH to WETH...");
        
        (bool success,) = WETH.call{value: wethAmount}("");
        require(success, "WETH wrap failed");
        console.log("WETH wrapped!");
        
        // Check WETH balance
        uint256 wethBalance = IERC20(WETH).balanceOf(user);
        console.log("WETH balance after wrap:", wethBalance);
        
        // Approve tokens to liquidity router
        uint256 usdcAmount = 3e6; // 3 USDC for liquidity
        console.log("\nApproving tokens to LiquidityRouter...");
        IERC20(WETH).approve(address(liquidityRouter), type(uint256).max);
        IERC20(USDC).approve(address(liquidityRouter), type(uint256).max);
        console.log("Tokens approved!");
        
        // Build liquidity params (very small for limited funds)
        ModifyLiquidityParams memory liquidityParams = ModifyLiquidityParams({
            tickLower: -600,      // Wider range to use less capital
            tickUpper: 600,
            liquidityDelta: 1e6, // Minimal liquidity for testing
            salt: 0
        });
        
        console.log("\nAdding liquidity...");
        console.log("  Tick range: -600 to 600");
        console.log("  Liquidity delta: 1e6");
        
        try liquidityRouter.modifyLiquidity(key, liquidityParams, ZERO_BYTES) returns (BalanceDelta delta) {
            console.log("Liquidity added successfully!");
            console.log("  Delta0 (USDC):", BalanceDelta.unwrap(delta) >> 128);
            console.log("  Delta1 (WETH):", int128(int256(BalanceDelta.unwrap(delta))));
        } catch Error(string memory reason) {
            console.log("Liquidity addition failed:", reason);
            revert(string.concat("Failed to add liquidity: ", reason));
        }
        
        // Step 4: Test a swap
        console.log("\n=== Step 4: Testing Swap ===");
        
        // Approve swap router
        console.log("Approving tokens to SwapRouter...");
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        console.log("USDC approved to SwapRouter");
        
        console.log("\nExecuting swap: 0.01 USDC -> WETH...");
        
        SwapParams memory params = SwapParams({
            zeroForOne: true,  // USDC (currency0) -> WETH (currency1)
            amountSpecified: -1e4,  // 0.01 USDC exact input (much smaller!)
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1  // Proper price limit for zeroForOne
        });
        
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        
        try swapRouter.swap(key, params, testSettings, "") returns (BalanceDelta delta) {
            console.log("\nSWAP SUCCESSFUL!");
            console.log("Delta0 (WETH gained):", BalanceDelta.unwrap(delta) >> 128);
            console.log("Delta1 (USDC spent):", int128(int256(BalanceDelta.unwrap(delta))));
            
            // Check final balances
            uint256 finalWethBalance = IERC20(WETH).balanceOf(user);
            uint256 finalUsdcBalance = IERC20(USDC).balanceOf(user);
            
            console.log("\nFinal balances:");
            console.log("  WETH:", finalWethBalance);
            console.log("  USDC:", finalUsdcBalance);
            
            console.log("\n=== SUCCESS! ===");
            console.log("Pool is initialized and working!");
            console.log("You can now:");
            console.log("  1. Add more liquidity");
            console.log("  2. Test swaps");
            console.log("  3. Enable your SpendSave hook!");
            
        } catch Error(string memory reason) {
            console.log("\nSwap failed:", reason);
            
            // Even if swap fails, pool might be initialized
            console.log("\nPool initialized but swap failed.");
            console.log("This might mean:");
            console.log("  1. Need proper Position Manager integration");
            console.log("  2. Need to add liquidity through Position Manager");
            console.log("  3. Pool exists but has no liquidity yet");
            
        } catch (bytes memory lowLevelData) {
            console.log("\nSwap failed with low-level error:");
            console.logBytes(lowLevelData);
        }
        
        vm.stopBroadcast();
        
        console.log("\n=== Script Complete ===");
    }
}

