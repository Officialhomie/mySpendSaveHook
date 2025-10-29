// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {StateView} from "lib/v4-periphery/src/lens/StateView.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";

/**
 * @title AddLiquidity
 * @notice Script to add liquidity to the USDC/WETH pool with SpendSave hook
 * @dev Supports different liquidity amounts via environment variables
 */
contract AddLiquidity is Script {
    using PoolIdLibrary for PoolKey;

    // Base Sepolia infrastructure
    IPoolManager constant POOL_MANAGER = IPoolManager(0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408);
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address constant SPENDSAVE_HOOK = 0xB149651E7C60E561148AbD5a31a6ad6ba25c40cc;
    address constant STATE_VIEW = 0xF6a15a395cC62477f37ebFeFAC71dD7224296482;

    // Liquidity router (will be deployed if needed)
    PoolModifyLiquidityTest public liquidityRouter;

    // Pool configuration
    PoolKey public poolKey;

    // User address
    address public user;

    function run() external {
        console.log("========================================");
        console.log("ADD LIQUIDITY TO SPENDSAVE POOL");
        console.log("========================================");
        console.log("");

        // Get user address
        try vm.envUint("PRIVATE_KEY") returns (uint256 deployerPrivateKey) {
            user = vm.addr(deployerPrivateKey);
            console.log("Using private key deployment method");
        } catch {
            user = vm.envAddress("DEPLOYER_ADDRESS");
            console.log("Using account-based deployment method");
        }

        console.log("User:", user);
        console.log("Pool Manager:", address(POOL_MANAGER));
        console.log("SpendSave Hook:", SPENDSAVE_HOOK);
        console.log("");

        // Setup pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(SPENDSAVE_HOOK)
        });

        // Get liquidity amount from environment or use default
        int256 liquidityAmount = int256(vm.envOr("LIQUIDITY_AMOUNT", uint256(1e6)));
        uint256 ethAmount = vm.envOr("ETH_AMOUNT", uint256(0.001 ether));
        
        console.log("LIQUIDITY CONFIGURATION:");
        console.log("  Liquidity Delta:", uint256(liquidityAmount));
        console.log("  ETH to wrap:", ethAmount);
        console.log("");

        // Check current balances
        _checkBalances();

        // Display current pool state
        _displayPoolState();

        vm.startBroadcast();

        // Step 1: Deploy or get liquidity router
        _deployLiquidityRouter();

        // Step 2: Add liquidity
        _addLiquidity(liquidityAmount, ethAmount);

        vm.stopBroadcast();

        console.log("");
        console.log("========================================");
        console.log("LIQUIDITY ADDED SUCCESSFULLY!");
        console.log("========================================");
        console.log("");

        // Check final balances
        _checkBalances();

        // Display updated pool state
        _displayPoolState();
    }

    function _checkBalances() internal view {
        uint256 usdcBalance = IERC20(USDC).balanceOf(user);
        uint256 wethBalance = IERC20(WETH).balanceOf(user);
        uint256 ethBalance = user.balance;

        console.log("CURRENT BALANCES:");
        console.log("  USDC:", usdcBalance);
        console.log("  USDC (human):", usdcBalance / 1e6);
        console.log("  WETH:", wethBalance);
        console.log("  WETH (human):", wethBalance / 1e18);
        console.log("  ETH:", ethBalance);
        console.log("  ETH (human):", ethBalance / 1e18);
        console.log("");
    }

    function _displayPoolState() internal view {
        PoolId poolId = poolKey.toId();
        
        console.log("POOL STATE:");
        console.log("  Pool ID:", vm.toString(PoolId.unwrap(poolId)));
        
        try StateView(STATE_VIEW).getSlot0(poolId) returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint24 protocolFee,
            uint24 lpFee
        ) {
            console.log("  SqrtPriceX96:", sqrtPriceX96);
            console.log("  Current Tick:", uint256(int256(tick)));
            console.log("  Protocol Fee:", protocolFee);
            console.log("  LP Fee:", lpFee);
        } catch {
            console.log("  Pool state: Not initialized or unavailable");
        }
        console.log("");
    }

    function _deployLiquidityRouter() internal {
        console.log("=== STEP 1: Setup Liquidity Router ===");
        
        // Try to use existing router from environment
        try vm.envAddress("LIQUIDITY_ROUTER") returns (address existingRouter) {
            liquidityRouter = PoolModifyLiquidityTest(existingRouter);
            console.log("Using existing LiquidityRouter:", address(liquidityRouter));
        } catch {
            // Deploy new router
            liquidityRouter = new PoolModifyLiquidityTest(POOL_MANAGER);
            console.log("Deployed new LiquidityRouter:", address(liquidityRouter));
        }
        console.log("");
    }

    function _addLiquidity(int256 liquidityAmount, uint256 ethAmount) internal {
        console.log("=== STEP 2: Add Liquidity to Pool ===");

        // Wrap ETH to WETH
        console.log("Wrapping", ethAmount, "ETH to WETH...");
        (bool success,) = WETH.call{value: ethAmount}("");
        require(success, "WETH wrap failed");
        console.log("Successfully wrapped ETH to WETH");

        // Approve tokens
        console.log("Approving tokens to LiquidityRouter...");
        IERC20(WETH).approve(address(liquidityRouter), type(uint256).max);
        IERC20(USDC).approve(address(liquidityRouter), type(uint256).max);
        console.log("Tokens approved");

        // Build liquidity params
        // Full range liquidity: -887220 to 887220 (covers all prices)
        ModifyLiquidityParams memory liqParams = ModifyLiquidityParams({
            tickLower: -887220,
            tickUpper: 887220,
            liquidityDelta: liquidityAmount,
            salt: 0
        });

        // Pass user address in hookData
        bytes memory hookData = abi.encode(user);

        console.log("");
        console.log("Adding liquidity with params:");
        console.log("  Tick Lower:", int256(liqParams.tickLower));
        console.log("  Tick Upper:", int256(liqParams.tickUpper));
        console.log("  Liquidity Delta:", uint256(liquidityAmount));
        console.log("");

        try liquidityRouter.modifyLiquidity(poolKey, liqParams, hookData) returns (BalanceDelta delta) {
            console.log("LIQUIDITY ADDED SUCCESSFULLY!");
            console.log("");
            console.log("Balance Changes:");
            
            int128 delta0 = int128(int256(BalanceDelta.unwrap(delta) >> 128));
            int128 delta1 = int128(int256(BalanceDelta.unwrap(delta)));
            
            console.log("  USDC Delta (units):", int256(delta0));
            console.log("  WETH Delta (units):", int256(delta1));
            
            // Calculate human-readable amounts
            if (delta0 < 0) {
                uint256 usdcAdded = uint256(int256(-delta0));
                console.log("  USDC Added (units):", usdcAdded);
                console.log("  USDC Added (human):", usdcAdded / 1e6);
            }
            if (delta1 < 0) {
                uint256 wethAdded = uint256(int256(-delta1));
                console.log("  WETH Added (units):", wethAdded);
                console.log("  WETH Added (human):", wethAdded / 1e18);
            }
        } catch Error(string memory reason) {
            console.log("FAILED to add liquidity:", reason);
            revert(reason);
        }
    }
}

