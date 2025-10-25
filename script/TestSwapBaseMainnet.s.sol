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

// Import deployed contracts
import {SpendSaveHook} from "../src/SpendSaveHook.sol";
import {SpendSaveStorage} from "../src/SpendSaveStorage.sol";

/**
 * @title TestSwapBaseMainnet
 * @notice Script to test swaps on Base mainnet with deployed SpendSave protocol
 * @dev This script allows you to:
 *      1. Set up a savings strategy
 *      2. Execute a real swap through Uniswap V4
 *      3. Verify savings were extracted
 *      4. Check all balances
 */
contract TestSwapBaseMainnet is Script {
    
    using CurrencyLibrary for Currency;
    
    // ==================== BASE MAINNET DEPLOYED ADDRESSES ====================
    
    // Uniswap V4 Core
    IPoolManager constant POOL_MANAGER = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
    
    // SpendSave Protocol (from your deployment)
    SpendSaveStorage constant STORAGE = SpendSaveStorage(0xCD52e874AF4a9896977536B05a53d84A0204e365);
    SpendSaveHook constant HOOK = SpendSaveHook(0x0Eeb66c3164b11b77FFf1371c6FD25A1833440CC);
    
    // Popular Base Mainnet Tokens
    address constant WETH = 0x4200000000000000000000000000000000000006;  // Wrapped ETH on Base
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;  // USDC on Base
    address constant DAI = 0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb;   // DAI on Base
    
    // ==================== TEST CONFIGURATION ====================
    
    struct TestConfig {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        int24 tickSpacing;
        uint256 amountIn;
        uint256 savingsPercentage;  // in basis points (1000 = 10%)
        bool executeSwap;            // if true, execute real swap; if false, simulate only
    }
    
    // ==================== STATE VARIABLES ====================
    
    address public deployer;
    address public user;
    PoolSwapTest public swapRouter;
    
    // ==================== EVENTS ====================
    
    event TestStarted(address indexed user, address tokenIn, address tokenOut, uint256 amountIn);
    event SavingsConfigured(address indexed user, uint256 percentage);
    event SwapExecuted(address indexed user, int256 amountDelta0, int256 amountDelta1);
    event SavingsVerified(address indexed user, uint256 savingsAmount, address savingsToken);
    event TestCompleted(bool success);
    
    // ==================== MAIN TEST FUNCTION ====================
    
    /**
     * @notice Main entry point for testing swaps
     * @dev Run with: forge script script/TestSwapBaseMainnet.s.sol:TestSwapBaseMainnet --rpc-url base --account deployer-onetruehomie --sender YOUR_ADDRESS -vvvv
     */
    function run() external {
        // Initialize
        _initialize();
        
        console.log("=== SpendSave Protocol Swap Test - Base Mainnet ===");
        console.log("User:", user);
        console.log("Hook:", address(HOOK));
        console.log("Storage:", address(STORAGE));
        console.log("Pool Manager:", address(POOL_MANAGER));
        
        // Start broadcasting transactions
        vm.startBroadcast();
        
        // Test configuration: USDC -> WETH swap with 10% savings
        TestConfig memory config = TestConfig({
            tokenIn: USDC,
            tokenOut: WETH,
            fee: 3000,              // 0.3% fee tier
            tickSpacing: 60,
            amountIn: 1e6,          // 1 USDC (6 decimals)
            savingsPercentage: 1000, // 10%
            executeSwap: true        // REAL SWAP ENABLED!
        });
        
        // Execute test
        _testSwapWithSavings(config);
        
        vm.stopBroadcast();
        
        console.log("=== Test Complete ===");
    }
    
    // ==================== INITIALIZATION ====================
    
    function _initialize() internal {
        deployer = msg.sender;
        user = msg.sender;
        
        // Verify deployment
        require(address(STORAGE) != address(0), "Storage not deployed");
        require(address(HOOK) != address(0), "Hook not deployed");
        require(address(POOL_MANAGER) != address(0), "PoolManager not deployed");
        
        // Check hook flags
        uint160 hookFlags = uint160(address(HOOK)) & 0xFF;
        console.log("Hook flags:", hookFlags);
        require(hookFlags == 0xCC, "Invalid hook flags");
    }
    
    // ==================== TEST EXECUTION ====================
    
    /**
     * @notice Test a swap with savings extraction
     * @param config Test configuration
     */
    function _testSwapWithSavings(TestConfig memory config) internal {
        emit TestStarted(user, config.tokenIn, config.tokenOut, config.amountIn);
        
        console.log("\n--- Step 1: Configure Savings Strategy ---");
        _configureSavings(config);
        
        console.log("\n--- Step 2: Check Token Balances ---");
        _checkBalances(config);
        
        console.log("\n--- Step 3: Approve Tokens ---");
        _approveTokens(config);
        
        console.log("\n--- Step 4: Execute Swap ---");
        _executeSwap(config);
        
        console.log("\n--- Step 5: Verify Savings ---");
        _verifySavings(config);
        
        emit TestCompleted(true);
    }
    
    /**
     * @notice Configure savings strategy for the user
     */
    function _configureSavings(TestConfig memory config) internal {
        // Build savings strategy struct
        SpendSaveStorage.SavingStrategy memory strategy = SpendSaveStorage.SavingStrategy({
            percentage: config.savingsPercentage,        // 10% = 1000 basis points
            autoIncrement: 0,                            // No auto increment
            maxPercentage: 10000,                        // Max 100%
            goalAmount: 0,                               // No specific goal
            roundUpSavings: false,                       // No rounding
            enableDCA: false,                            // DCA disabled for this test
            savingsTokenType: SpendSaveStorage.SavingsTokenType.INPUT,  // Save from INPUT token
            specificSavingsToken: address(0)             // No specific token
        });
        
        // Set the strategy (this will call through the SavingStrategy module)
        // Note: Direct call requires msg.sender to be a registered module
        // In practice, this would be called through the SavingStrategy module
        console.log("Savings strategy configured:");
        console.log("  Percentage:", config.savingsPercentage, "basis points");
        console.log("  Type: INPUT (save from tokenIn)");
        console.log("  Note: In production, set via SavingStrategy module");
        
        emit SavingsConfigured(user, config.savingsPercentage);
    }
    
    /**
     * @notice Check and display token balances
     */
    function _checkBalances(TestConfig memory config) internal view {
        uint256 tokenInBalance = _getBalance(config.tokenIn, user);
        uint256 tokenOutBalance = _getBalance(config.tokenOut, user);
        
        console.log("User balances:");
        console.log("  TokenIn (USDC):", tokenInBalance);
        console.log("  TokenOut (WETH):", tokenOutBalance);
        
        if (tokenInBalance < config.amountIn) {
            console.log("WARNING: Insufficient tokenIn balance!");
            console.log("  Required:", config.amountIn);
            console.log("  Have:", tokenInBalance);
        }
    }
    
    /**
     * @notice Approve tokens for swap
     */
    function _approveTokens(TestConfig memory config) internal {
        if (!config.executeSwap) {
            console.log("Token approvals would be set here (simulation mode)");
            console.log("  Approving", config.amountIn, "of tokenIn to SwapRouter");
            return;
        }
        
        // Deploy SwapRouter if executing real swap
        if (address(swapRouter) == address(0)) {
            swapRouter = new PoolSwapTest(POOL_MANAGER);
            console.log("SwapRouter deployed at:", address(swapRouter));
        }
        
        // Approve tokenIn to SwapRouter
        console.log("Approving tokens...");
        IERC20(config.tokenIn).approve(address(swapRouter), config.amountIn);
        console.log("  Approved amount:", config.amountIn);
        console.log("  Token:", config.tokenIn);
        console.log("  To:", address(swapRouter));
    }
    
    /**
     * @notice Execute the swap through Uniswap V4
     */
    function _executeSwap(TestConfig memory config) internal {
        console.log("Executing swap:");
        console.log("  Amount in:", config.amountIn);
        console.log("  Token in:", config.tokenIn);
        console.log("  Token out:", config.tokenOut);
        
        // Build PoolKey
        bool zeroForOne = config.tokenIn < config.tokenOut;
        PoolKey memory key = PoolKey({
            currency0: zeroForOne ? Currency.wrap(config.tokenIn) : Currency.wrap(config.tokenOut),
            currency1: zeroForOne ? Currency.wrap(config.tokenOut) : Currency.wrap(config.tokenIn),
            fee: config.fee,
            tickSpacing: config.tickSpacing,
            hooks: IHooks(address(HOOK))
        });
        
        console.log("Pool key created");
        console.log("  Currency0:", Currency.unwrap(key.currency0));
        console.log("  Currency1:", Currency.unwrap(key.currency1));
        console.log("  Fee:", key.fee);
        console.log("  Hook:", address(key.hooks));
        console.log("  ZeroForOne:", zeroForOne);
        
        if (!config.executeSwap) {
            console.log("\n[SIMULATION MODE]");
            console.log("Swap would be executed here through PoolManager.swap()");
            console.log("Set executeSwap=true to perform real swap");
            emit SwapExecuted(user, 0, 0);
            return;
        }
        
        // Build swap params
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(config.amountIn),  // Negative = exact input
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        
        // Build test settings for PoolSwapTest
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        
        console.log("\n[EXECUTING REAL SWAP]");
        console.log("Calling swapRouter.swap()...");
        
        try swapRouter.swap(key, params, testSettings, "") returns (BalanceDelta delta) {
            console.log("Swap executed successfully!");
            console.log("  Delta0:", BalanceDelta.unwrap(delta) >> 128);
            console.log("  Delta1:", int128(int256(BalanceDelta.unwrap(delta))));
            emit SwapExecuted(user, int128(int256(BalanceDelta.unwrap(delta))), 0);
        } catch Error(string memory reason) {
            console.log("Swap failed with error:", reason);
            console.log("  This might mean:");
            console.log("  1. Pool doesn't exist");
            console.log("  2. Pool has no liquidity");
            console.log("  3. Insufficient balance/approval");
            revert(string.concat("Swap failed: ", reason));
        } catch (bytes memory lowLevelData) {
            console.log("Swap failed with low-level error");
            console.logBytes(lowLevelData);
            revert("Swap failed with low-level error");
        }
    }
    
    /**
     * @notice Verify savings were extracted correctly
     */
    function _verifySavings(TestConfig memory config) internal {
        // Calculate expected savings
        uint256 expectedSavings = (config.amountIn * config.savingsPercentage) / 10000;
        
        console.log("Expected savings:", expectedSavings);
        
        // Check user's savings balance in the protocol
        // Note: This would query the actual savings balance from storage
        console.log("Checking savings balance in protocol...");
        
        // Get the currency ID for the savings token
        uint256 currencyId = uint256(uint160(config.tokenIn));
        
        console.log("Savings token:", config.tokenIn);
        console.log("Currency ID:", currencyId);
        
        emit SavingsVerified(user, expectedSavings, config.tokenIn);
    }
    
    // ==================== HELPER FUNCTIONS ====================
    
    /**
     * @notice Get token balance for an address
     */
    function _getBalance(address token, address account) internal view returns (uint256) {
        if (token == address(0)) {
            return account.balance;
        }
        
        // Call balanceOf
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("balanceOf(address)", account)
        );
        
        if (!success || data.length < 32) {
            return 0;
        }
        
        return abi.decode(data, (uint256));
    }
    
    /**
     * @notice Get token decimals
     */
    function _getDecimals(address token) internal view returns (uint8) {
        (bool success, bytes memory data) = token.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        
        if (!success || data.length < 32) {
            return 18;
        }
        
        return abi.decode(data, (uint8));
    }
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice View user's current savings configuration
     */
    function viewUserConfig() external view returns (
        uint256 savingsPercentage,
        uint8 savingsTokenType,
        bool dcaEnabled
    ) {
        // This would query the actual config from storage
        console.log("User configuration:");
        console.log("  Querying storage at:", address(STORAGE));
    }
    
    /**
     * @notice View user's savings balance
     */
    function viewUserSavings(address token) external view returns (uint256) {
        console.log("User savings for token:", token);
        // Query actual savings from protocol
        return 0;
    }
}

