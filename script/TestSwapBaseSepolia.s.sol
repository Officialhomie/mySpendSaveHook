// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

// Uniswap V4 imports
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

/**
 * @title TestSwapBaseSepolia
 * @notice Test swap execution on Base Sepolia testnet
 * @dev Simplified version to test on existing pools WITHOUT custom hook first
 */
contract TestSwapBaseSepolia is Script {
    using CurrencyLibrary for Currency;

    // Base Sepolia addresses
    IPoolManager constant POOL_MANAGER = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);

    // Base Sepolia tokens
    address constant WETH = 0x4200000000000000000000000000000000000006; // WETH on Base Sepolia
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e; // USDC on Base Sepolia

    PoolSwapTest public swapRouter;
    address public user;

    function run() external {
        user = msg.sender;

        console.log("=== Testing Swap on Base Sepolia ===");
        console.log("User:", user);
        console.log("Pool Manager:", address(POOL_MANAGER));

        vm.startBroadcast();

        // Deploy SwapRouter
        swapRouter = new PoolSwapTest(POOL_MANAGER);
        console.log("SwapRouter deployed:", address(swapRouter));

        // Check balance
        uint256 usdcBalance = IERC20(USDC).balanceOf(user);
        console.log("Your USDC balance:", usdcBalance);

        // Approve 1 USDC
        uint256 swapAmount = 1e6; // 1 USDC
        console.log("\nApproving", swapAmount, "USDC...");
        IERC20(USDC).approve(address(swapRouter), swapAmount);
        console.log("Approved!");

        // Build pool key (WITHOUT custom hook)
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDC),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0)) // NO HOOK - test basic swap first
        });

        console.log("\nPool configuration:");
        console.log("  Currency0 (WETH):", Currency.unwrap(key.currency0));
        console.log("  Currency1 (USDC):", Currency.unwrap(key.currency1));
        console.log("  Fee: 0.3%");
        console.log("  Hook: None (testing basic swap)");

        // Build swap params
        SwapParams memory params = SwapParams({
            zeroForOne: false, // USDC → WETH
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        // Build test settings
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        console.log("\nExecuting swap: 1 USDC -> WETH...");

        try swapRouter.swap(key, params, testSettings, "") returns (BalanceDelta delta) {
            console.log("\nSWAP SUCCESSFUL!");
            console.log("Delta0:", BalanceDelta.unwrap(delta) >> 128);
            console.log("Delta1:", int128(int256(BalanceDelta.unwrap(delta))));

            // Check new balances
            uint256 newUsdcBalance = IERC20(USDC).balanceOf(user);
            uint256 wethBalance = IERC20(WETH).balanceOf(user);

            console.log("\nFinal balances:");
            console.log("  USDC:", newUsdcBalance);
            console.log("  WETH:", wethBalance);
            console.log("\nTEST PASSED! Swap executed successfully on Base Sepolia!");
        } catch Error(string memory reason) {
            console.log("\nSwap failed:", reason);
            console.log("\nPossible reasons:");
            console.log("  1. Pool doesn't exist");
            console.log("  2. Pool has no liquidity");
            console.log("  3. Need to initialize pool first");
        } catch (bytes memory lowLevelData) {
            console.log("\nSwap failed with low-level error:");
            console.logBytes(lowLevelData);
        }

        vm.stopBroadcast();

        console.log("\n=== Test Complete ===");
    }
}
