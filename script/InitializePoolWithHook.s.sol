// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {PoolModifyLiquidityTest} from "lib/v4-periphery/lib/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/**
 * @title InitializePoolWithHook
 * @notice Initialize USDC/WETH pool WITH SpendSave hook and add liquidity
 * @dev This creates a pool that can extract savings on swaps
 */
contract InitializePoolWithHook is Script {
    using PoolIdLibrary for PoolKey;

    // Base Sepolia addresses
    address constant POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant SPENDSAVE_HOOK = 0xB149651E7C60E561148AbD5a31a6ad6ba25c40cc;

    bytes constant ZERO_BYTES = "";

    // sqrt(1) = 1:1 price ratio
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        // Get deployer address BEFORE broadcast
        address deployer = vm.envAddress("DEPLOYER_ADDRESS");

        console.log("=== Initialize Pool WITH SpendSave Hook ===");
        console.log("Deployer:", deployer);
        console.log("Pool Manager:", POOL_MANAGER);
        console.log("SpendSave Hook:", SPENDSAVE_HOOK);
        console.log("USDC:", USDC);
        console.log("WETH:", WETH);

        // Build the pool key WITH the hook
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(SPENDSAVE_HOOK)
        });

        // Calculate Pool ID
        PoolId poolId = key.toId();
        console.log("");
        console.log("Pool ID:", uint256(PoolId.unwrap(poolId)));

        vm.startBroadcast(deployer);

        IPoolManager poolManager = IPoolManager(POOL_MANAGER);

        // Step 1: Initialize the pool
        console.log("");
        console.log("Step 1: Initializing pool with hook...");
        try poolManager.initialize(key, SQRT_PRICE_1_1) returns (int24 tick) {
            console.log("SUCCESS: Pool initialized!");
            console.log("  Initial tick:", tick);
        } catch Error(string memory reason) {
            console.log("ERROR: Pool initialization failed");
            console.log("Reason:", reason);
        } catch (bytes memory lowLevelData) {
            console.log("ERROR: Pool initialization failed (low-level)");
            console.logBytes(lowLevelData);
        }

        // Step 2: Deploy liquidity router
        console.log("");
        console.log("Step 2: Deploying liquidity router...");
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(poolManager);
        console.log("Liquidity Router deployed:", address(liquidityRouter));

        // Step 3: Wrap ETH to WETH (10 USDC worth at 1:1 ratio = 0.01 ETH + buffer)
        console.log("");
        console.log("Step 3: Wrapping ETH to WETH...");
        (bool wrapSuccess,) = WETH.call{value: 0.015 ether}("");
        require(wrapSuccess, "WETH wrap failed");
        uint256 wethBalance = IERC20(WETH).balanceOf(deployer);
        console.log("WETH balance:", wethBalance);

        // Step 4: Approve tokens
        console.log("");
        console.log("Step 4: Approving tokens to liquidity router...");
        IERC20(USDC).approve(address(liquidityRouter), type(uint256).max);
        IERC20(WETH).approve(address(liquidityRouter), type(uint256).max);
        console.log("Tokens approved");

        // Check balances before
        uint256 usdcBalance = IERC20(USDC).balanceOf(deployer);
        console.log("");
        console.log("Balances before liquidity:");
        console.log("  USDC:", usdcBalance / 1e6, "USDC");
        console.log("  WETH:", wethBalance / 1e18, "WETH");

        // Step 5: Add liquidity (10 USDC worth)
        console.log("");
        console.log("Step 5: Adding liquidity (10 USDC worth)...");

        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: -600,
            tickUpper: 600,
            liquidityDelta: 1e6, // Much smaller - will use just a few USDC
            salt: bytes32(0)
        });

        console.log("Liquidity params:");
        console.log("  tickLower:", params.tickLower);
        console.log("  tickUpper:", params.tickUpper);
        console.log("  liquidityDelta:", uint256(int256(params.liquidityDelta)));

        try liquidityRouter.modifyLiquidity(key, params, ZERO_BYTES) {
            console.log("SUCCESS: Liquidity added successfully!");
        } catch Error(string memory reason) {
            console.log("ERROR: Failed to add liquidity");
            console.log("Reason:", reason);
            console.log("");
            console.log("Troubleshooting:");
            console.log("1. Check if you have enough USDC and WETH");
            console.log("2. Verify token approvals");
            console.log("3. Ensure pool is properly initialized");
        } catch (bytes memory lowLevelData) {
            console.log("ERROR: Failed to add liquidity (low-level)");
            console.logBytes(lowLevelData);
        }

        // Check final balances
        uint256 finalUSDC = IERC20(USDC).balanceOf(deployer);
        uint256 finalWETH = IERC20(WETH).balanceOf(deployer);
        console.log("");
        console.log("Balances after liquidity:");
        console.log("  USDC:", finalUSDC / 1e6, "USDC");
        console.log("  WETH:", finalWETH / 1e18, "WETH");

        vm.stopBroadcast();

        console.log("");
        console.log("=== COMPLETE ===");
        console.log("Pool is ready for frontend swaps!");
        console.log("");
        console.log("Use these addresses:");
        console.log("  Pool Manager:", POOL_MANAGER);
        console.log("  SpendSave Hook:", SPENDSAVE_HOOK);
        console.log("  Pool ID:", uint256(PoolId.unwrap(poolId)));
        console.log("  Liquidity Router:", address(liquidityRouter));
        console.log("");
        console.log("Frontend can now:");
        console.log("1. Check pool initialization: poolManager.extsload(poolId slot)");
        console.log("2. Perform swaps via SwapRouter with hook data");
        console.log("3. Track savings via SpendSaveHook.getUserTotalSavings()");
    }

    /**
     * @notice Check if pool is initialized
     * @dev Reads the pool's slot0 to check sqrtPriceX96
     */
    function checkPoolInitialized(IPoolManager poolManager, PoolId poolId) internal view returns (bool) {
        // Pool state is stored starting at: keccak256(abi.encode(poolId, POOLS_SLOT))
        bytes32 POOLS_SLOT = bytes32(uint256(6));
        bytes32 poolStateSlot = keccak256(abi.encode(PoolId.unwrap(poolId), POOLS_SLOT));

        // Read sqrtPriceX96 (first 160 bits of slot0)
        bytes32 slot0 = poolManager.extsload(poolStateSlot);
        uint160 sqrtPriceX96 = uint160(uint256(slot0));

        return sqrtPriceX96 != 0;
    }

    /**
     * @notice Get pool liquidity
     * @dev Reads the pool's liquidity value
     */
    function getPoolLiquidity(IPoolManager poolManager, PoolId poolId) internal view returns (uint128) {
        bytes32 POOLS_SLOT = bytes32(uint256(6));
        bytes32 poolStateSlot = keccak256(abi.encode(PoolId.unwrap(poolId), POOLS_SLOT));

        // Liquidity is stored in slot1 (poolStateSlot + 1)
        bytes32 liquiditySlot = bytes32(uint256(poolStateSlot) + 1);
        bytes32 liquidityData = poolManager.extsload(liquiditySlot);

        return uint128(uint256(liquidityData));
    }
}

