// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

/**
 * @title SimpleSwapTest
 * @notice Quick swap test on existing pool
 */
contract SimpleSwapTest is Script {
    
    // Base Sepolia
    IPoolManager constant POOL_MANAGER = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    
    function run() external {
        console.log("=== Simple Swap Test ===");
        
        vm.startBroadcast();
        
        // Deploy swap router
        PoolSwapTest swapRouter = new PoolSwapTest(POOL_MANAGER);
        console.log("SwapRouter:", address(swapRouter));
        
        // Add minimal liquidity first
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(POOL_MANAGER);
        
        // Wrap 0.001 ETH
        (bool success,) = WETH.call{value: 0.001 ether}("");
        require(success, "Wrap failed");
        console.log("Wrapped 0.001 ETH");
        
        // Approve
        IERC20(WETH).approve(address(liquidityRouter), type(uint256).max);
        IERC20(USDC).approve(address(liquidityRouter), type(uint256).max);
        IERC20(USDC).approve(address(swapRouter), type(uint256).max);
        
        // Pool key
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(0xc4ABf9A7bf8300086BBad164b4c47B1Afbbf00Cc) // NEW SpendSave Hook
        });
        
        // Add tiny liquidity (you only have 10 USDC!)
        console.log("Adding liquidity...");
        ModifyLiquidityParams memory liqParams = ModifyLiquidityParams({
            tickLower: -887220,    // Maximum range
            tickUpper: 887220,
            liquidityDelta: 1e6,  // Absolutely minimal liquidity
            salt: 0
        });
        
        liquidityRouter.modifyLiquidity(key, liqParams, "");
        console.log("Liquidity added!");
        
        // Swap 0.01 USDC
        console.log("Swapping 0.01 USDC...");
        SwapParams memory swapParams = SwapParams({
            zeroForOne: true,
            amountSpecified: -1e4,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        
        BalanceDelta delta = swapRouter.swap(key, swapParams, settings, "");
        console.log("SWAP SUCCESS!");
        console.log("Delta:", BalanceDelta.unwrap(delta));
        
        vm.stopBroadcast();
    }
}

