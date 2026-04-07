// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";

/**
 * @title InitializePoolSimple
 * @notice Simple script to initialize pool WITH hook and add liquidity
 * @dev Uses ONLY msg.sender (works with --account flag)
 */
contract InitializePoolSimple is Script {
    // Base Sepolia addresses
    IPoolManager constant POOL_MANAGER = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant HOOK = 0x158A7F998F14930fCB3e3f9Cb57Cf99bDf0940Cc;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        console.log("=== Initialize Pool WITH SpendSave Hook ===");
        console.log("Deployer:", msg.sender);
        console.log("Hook:", HOOK);

        // Build pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(HOOK)
        });

        // Calculate Pool ID
        PoolId poolId = PoolId.wrap(keccak256(abi.encode(poolKey)));
        console.log("Pool ID:", uint256(PoolId.unwrap(poolId)));

        vm.startBroadcast(); // Uses msg.sender when --account is provided

        // Step 1: Initialize pool
        console.log("\nStep 1: Initializing pool...");
        try POOL_MANAGER.initialize(poolKey, SQRT_PRICE_1_1) returns (int24 tick) {
            console.log("SUCCESS: Pool initialized!");
            console.log("  Initial tick:", tick);
        } catch {
            console.log("Pool already initialized or initialization failed");
        }

        // Step 2: Deploy liquidity router
        console.log("\nStep 2: Deploying liquidity router...");
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(POOL_MANAGER);
        console.log("Liquidity router:", address(liquidityRouter));

        // Step 3: Wrap ETH to WETH
        console.log("\nStep 3: Wrapping ETH to WETH...");
        (bool wrapSuccess,) = WETH.call{value: 0.001 ether}("");
        require(wrapSuccess, "WETH wrap failed");
        console.log("Wrapped 0.001 ETH to WETH");

        // Step 4: Approve tokens
        console.log("\nStep 4: Approving tokens...");
        IERC20(USDC).approve(address(liquidityRouter), type(uint256).max);
        IERC20(WETH).approve(address(liquidityRouter), type(uint256).max);
        console.log("Tokens approved");

        // Step 5: Add liquidity
        console.log("\nStep 5: Adding liquidity...");
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 1e6, // Minimal liquidity
            salt: bytes32(0)
        });

        try liquidityRouter.modifyLiquidity(poolKey, params, "") {
            console.log("SUCCESS: Liquidity added!");
        } catch Error(string memory reason) {
            console.log("Liquidity failed:", reason);
        }

        // Check balances
        uint256 usdcBal = IERC20(USDC).balanceOf(msg.sender);
        uint256 wethBal = IERC20(WETH).balanceOf(msg.sender);
        console.log("\nFinal balances:");
        console.log("  USDC:", usdcBal);
        console.log("  WETH:", wethBal);

        vm.stopBroadcast();

        console.log("\n=== COMPLETE ===");
        console.log("Pool WITH hook ready for frontend!");
        console.log("Use hook:", HOOK);
    }
}
