// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "lib/v4-periphery/lib/v4-core/src/test/PoolSwapTest.sol";

/**
 * @title DeploySwapRouter
 * @notice Deploys the SwapRouter (PoolSwapTest) for frontend integration
 * @dev This router implements the unlock pattern required for Uniswap V4 swaps
 */
contract DeploySwapRouter is Script {
    // Base Sepolia addresses
    address constant POOL_MANAGER_SEPOLIA = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    // Base Mainnet addresses
    address constant POOL_MANAGER_MAINNET = 0x7Da1D65F8B249183667cdE74C5CBD46dD38AA829;

    function run() external {
        // Get deployer info from msg.sender (works with --account flag)
        address deployer = msg.sender;

        console.log("=== DEPLOYING SWAP ROUTER ===");
        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);

        // Determine which network we're on
        uint256 chainId = block.chainid;
        address poolManager;

        if (chainId == 84532) {
            poolManager = POOL_MANAGER_SEPOLIA;
            console.log("Network: Base Sepolia");
        } else if (chainId == 8453) {
            poolManager = POOL_MANAGER_MAINNET;
            console.log("Network: Base Mainnet");
        } else {
            revert("Unsupported network");
        }

        console.log("PoolManager:", poolManager);

        // Start broadcasting transactions (works with --account flag)
        vm.startBroadcast();

        // Deploy SwapRouter (PoolSwapTest)
        console.log("\nDeploying SwapRouter...");
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(poolManager));
        console.log("SwapRouter deployed at:", address(swapRouter));

        vm.stopBroadcast();

        // Print summary
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("SwapRouter:", address(swapRouter));
        console.log("PoolManager:", poolManager);
        console.log("\n=== VERIFICATION COMMAND ===");
        console.log("forge verify-contract \\");
        console.log("  --chain-id", chainId, "\\");
        console.log("  --num-of-optimizations 200 \\");
        console.log("  --constructor-args $(cast abi-encode \"constructor(address)\" ", poolManager, ") \\");
        console.log("  ", address(swapRouter), "\\");
        console.log("  src/test/PoolSwapTest.sol:PoolSwapTest \\");
        console.log("  --etherscan-api-key $BASESCAN_API_KEY");

        console.log("\n=== FRONTEND INTEGRATION ===");
        console.log("Update your frontend with:");
        console.log("const SWAP_ROUTER_ADDRESS = '", address(swapRouter), "';");
    }
}
