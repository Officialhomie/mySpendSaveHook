// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

// V4 Core imports
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "lib/v4-periphery/lib/v4-core/src/PoolManager.sol";
import {Deployers} from "lib/v4-periphery/lib/v4-core/test/utils/Deployers.sol";
import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";
import {ModifyLiquidityParams} from "lib/v4-periphery/lib/v4-core/src/types/PoolOperation.sol";

// V4 Periphery imports
import {V4Quoter} from "lib/v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "lib/v4-periphery/src/interfaces/IV4Quoter.sol";
import {PathKey} from "lib/v4-periphery/src/libraries/PathKey.sol";

// SpendSave Contracts
import {SpendSaveHook} from "../src/SpendSaveHook.sol";
import {SpendSaveStorage} from "../src/SpendSaveStorage.sol";
import {SavingStrategy} from "../src/SavingStrategy.sol";
import {Savings} from "../src/Savings.sol";
import {DCA} from "../src/DCA.sol";
import {Token} from "../src/Token.sol";
import {SlippageControl} from "../src/SlippageControl.sol";
import {DailySavings} from "../src/DailySavings.sol";
import {SpendSaveQuoter} from "../src/SpendSaveQuoter.sol";

/**
 * @title SpendSaveQuoterTest
 * @notice P8 ENHANCED: Comprehensive testing of SpendSaveQuoter preview functions - savings impact and DCA quotes
 * @dev Tests savings impact preview, DCA quotes, multi-hop routing preview, and gas estimation
 */
contract SpendSaveQuoterTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    // Core contracts
    SpendSaveHook public hook;
    SpendSaveStorage public storageContract;
    SpendSaveQuoter public quoter;

    // V4 periphery contracts
    V4Quoter public v4Quoter;

    // All modules
    Savings public savingsModule;
    SavingStrategy public strategyModule;
    Token public tokenModule;
    DCA public dcaModule;
    DailySavings public dailySavingsModule;
    SlippageControl public slippageModule;

    // Test accounts
    address public owner;
    address public alice;
    address public bob;

    // Test tokens
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;

    // Pool configuration
    PoolKey public poolKeyAB;
    PoolKey public poolKeyAC;
    PoolKey public poolKeyBC;

    // Test parameters
    uint256 constant INITIAL_BALANCE = 1000 ether;
    uint256 constant SWAP_AMOUNT = 100 ether;
    uint256 constant SAVINGS_PERCENTAGE = 2000; // 20%
    uint256 constant DCA_AMOUNT = 50 ether;

    // Token IDs
    uint256 public tokenAId;
    uint256 public tokenBId;
    uint256 public tokenCId;

    function setUp() public {
        // Create test accounts
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        // Deploy V4 infrastructure
        deployFreshManagerAndRouters();

        // Deploy V4Quoter
        v4Quoter = new V4Quoter(manager);

        // Deploy tokens
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);
        tokenC = new MockERC20("Token C", "TKNC", 18);

        // Ensure proper token ordering for V4
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }
        if (address(tokenA) > address(tokenC)) {
            (tokenA, tokenC) = (tokenC, tokenA);
        }
        if (address(tokenB) > address(tokenC)) {
            (tokenB, tokenC) = (tokenC, tokenB);
        }

        // Deploy core protocol
        _deployProtocol();

        // Initialize pools for testing
        _initializePools();

        // Setup test accounts
        _setupTestAccounts();

        console.log("=== P8 ENHANCED: QUOTER TESTS SETUP COMPLETE ===");
    }

    function _deployProtocol() internal {
        // Deploy storage
        vm.prank(owner);
        storageContract = new SpendSaveStorage(address(manager));

        // Deploy all modules with fresh instances
        vm.startPrank(owner);
        savingsModule = new Savings();
        strategyModule = new SavingStrategy();
        tokenModule = new Token();
        dcaModule = new DCA();
        dailySavingsModule = new DailySavings();
        slippageModule = new SlippageControl();
        vm.stopPrank();

        // Deploy hook with proper address mining
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            owner,
            flags,
            type(SpendSaveHook).creationCode,
            abi.encode(IPoolManager(address(manager)), storageContract)
        );

        vm.prank(owner);
        hook = new SpendSaveHook{salt: salt}(
            IPoolManager(address(manager)),
            storageContract
        );

        require(address(hook) == hookAddress, "Hook deployed at wrong address");

        // Deploy SpendSaveQuoter
        vm.prank(owner);
        quoter = new SpendSaveQuoter(address(storageContract), address(v4Quoter));

        // Initialize storage
        vm.prank(owner);
        storageContract.initialize(address(hook));

        // Register modules
        vm.startPrank(owner);
        storageContract.registerModule(keccak256("SAVINGS"), address(savingsModule));
        storageContract.registerModule(keccak256("STRATEGY"), address(strategyModule));
        storageContract.registerModule(keccak256("TOKEN"), address(tokenModule));
        storageContract.registerModule(keccak256("DCA"), address(dcaModule));
        storageContract.registerModule(keccak256("DAILY"), address(dailySavingsModule));
        storageContract.registerModule(keccak256("SLIPPAGE"), address(slippageModule));
        vm.stopPrank();

        // Initialize modules with storage reference
        vm.startPrank(owner);
        savingsModule.initialize(storageContract);
        strategyModule.initialize(storageContract);
        tokenModule.initialize(storageContract);
        dcaModule.initialize(storageContract);
        dailySavingsModule.initialize(storageContract);
        slippageModule.initialize(storageContract);

        // Set cross-module references
        strategyModule.setModuleReferences(
            address(strategyModule),
            address(savingsModule),
            address(dcaModule),
            address(slippageModule),
            address(tokenModule),
            address(dailySavingsModule)
        );

        savingsModule.setModuleReferences(
            address(strategyModule),
            address(savingsModule),
            address(dcaModule),
            address(slippageModule),
            address(tokenModule),
            address(dailySavingsModule)
        );

        dcaModule.setModuleReferences(
            address(strategyModule),
            address(savingsModule),
            address(dcaModule),
            address(slippageModule),
            address(tokenModule),
            address(dailySavingsModule)
        );

        slippageModule.setModuleReferences(
            address(strategyModule),
            address(savingsModule),
            address(dcaModule),
            address(slippageModule),
            address(tokenModule),
            address(dailySavingsModule)
        );

        tokenModule.setModuleReferences(
            address(strategyModule),
            address(savingsModule),
            address(dcaModule),
            address(slippageModule),
            address(tokenModule),
            address(dailySavingsModule)
        );

        dailySavingsModule.setModuleReferences(
            address(strategyModule),
            address(savingsModule),
            address(dcaModule),
            address(slippageModule),
            address(tokenModule),
            address(dailySavingsModule)
        );

        vm.stopPrank();

        console.log("Core protocol deployed and initialized");
    }

    function _initializePools() internal {
        // Initialize multiple pools for multi-hop testing
        poolKeyAB = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolKeyAC = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenC)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        poolKeyBC = PoolKey({
            currency0: Currency.wrap(address(tokenB)),
            currency1: Currency.wrap(address(tokenC)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize pools with 1:1 price
        manager.initialize(poolKeyAB, SQRT_PRICE_1_1);
        manager.initialize(poolKeyAC, SQRT_PRICE_1_1);
        manager.initialize(poolKeyBC, SQRT_PRICE_1_1);

        // Add liquidity to pools for testing
        _addLiquidityToPools();

        console.log("Initialized pools for quoter testing");
    }

    function _addLiquidityToPools() internal {
        // Mint tokens to this test contract for liquidity
        uint256 liquidityAmount = 1000000 ether;
        tokenA.mint(address(this), liquidityAmount);
        tokenB.mint(address(this), liquidityAmount);
        tokenC.mint(address(this), liquidityAmount);

        // Approve the modify liquidity router
        tokenA.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenB.approve(address(modifyLiquidityRouter), type(uint256).max);
        tokenC.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Add substantial liquidity to all pools for testing large swaps
        // Using much larger liquidity delta to support test swaps
        ModifyLiquidityParams memory liquidityParams = ModifyLiquidityParams({
            tickLower: -887220, // Near full range
            tickUpper: 887220,  // Near full range
            liquidityDelta: int256(100000 ether), // Large liquidity
            salt: 0
        });

        modifyLiquidityRouter.modifyLiquidity(poolKeyAB, liquidityParams, ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(poolKeyAC, liquidityParams, ZERO_BYTES);
        modifyLiquidityRouter.modifyLiquidity(poolKeyBC, liquidityParams, ZERO_BYTES);

        console.log("Added liquidity to all pools");
    }

    function _setupTestAccounts() internal {
        // Fund all test accounts with tokens
        address[] memory accounts = new address[](3);
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = owner;

        for (uint256 i = 0; i < accounts.length; i++) {
            tokenA.mint(accounts[i], INITIAL_BALANCE);
            tokenB.mint(accounts[i], INITIAL_BALANCE);
            tokenC.mint(accounts[i], INITIAL_BALANCE);
        }

        // Register tokens and get their IDs
        tokenAId = tokenModule.registerToken(address(tokenA));
        tokenBId = tokenModule.registerToken(address(tokenB));
        tokenCId = tokenModule.registerToken(address(tokenC));

        // Setup savings strategy for testing
        _setupSavingsStrategy();

        console.log("Test accounts configured with tokens and strategy");
    }

    function _setupSavingsStrategy() internal {
        // Setup savings strategy for Alice
        vm.prank(alice);
        strategyModule.setSavingStrategy(
            alice,
            SAVINGS_PERCENTAGE, // 20% savings
            0,    // no auto increment
            10000, // max 100%
            false, // no round up
            SpendSaveStorage.SavingsTokenType.INPUT,
            address(0)
        );
    }

    // ==================== SAVINGS IMPACT PREVIEW TESTS ====================

    function testQuoter_PreviewSavingsImpact() public {
        console.log("\n=== P8 ENHANCED: Testing Savings Impact Preview ===");

        // Preview savings impact for swap
        (uint256 swapOutput, uint256 savedAmount, uint256 netOutput) = quoter.previewSavingsImpact(
            poolKeyAB,
            true, // zeroForOne
            uint128(SWAP_AMOUNT),
            SAVINGS_PERCENTAGE
        );

        // Verify calculations
        assertGt(swapOutput, 0, "Should get swap output");
        assertGt(savedAmount, 0, "Should calculate saved amount");

        // Expected savings: 20% of input
        uint256 expectedSavings = (SWAP_AMOUNT * SAVINGS_PERCENTAGE) / 10000;
        assertEq(savedAmount, expectedSavings, "Saved amount should be 20% of input");

        // Net output should be less than full swap output (less input = less output)
        assertLt(netOutput, swapOutput, "Net output should be less than full swap output");

        // Verify the relationship: netOutput is approximately (100%-20%) = 80% of swapOutput
        // Due to price impact in AMM, it won't be exactly linear, but should be close
        uint256 expectedNetOutputRatio = 10000 - SAVINGS_PERCENTAGE; // 8000 (80%)
        uint256 actualRatio = (netOutput * 10000) / swapOutput;

        // Allow 5% tolerance for AMM price impact
        assertApproxEqRel(actualRatio, expectedNetOutputRatio, 0.05e18, "Net output ratio should be approximately 80% of full swap");

        console.log("Savings impact preview successful");
        console.log("Swap output:", swapOutput);
        console.log("Saved amount:", savedAmount);
        console.log("Net output:", netOutput);
        console.log("SUCCESS: Savings impact preview working");
    }

    function testQuoter_PreviewSavingsImpactNoSavings() public {
        console.log("\n=== P8 ENHANCED: Testing Savings Impact Preview with No Savings ===");

        // Preview with 0% savings
        (uint256 swapOutput, uint256 savedAmount, uint256 netOutput) = quoter.previewSavingsImpact(
            poolKeyAB,
            true,
            uint128(SWAP_AMOUNT),
            0 // No savings
        );

        // Verify calculations
        assertGt(swapOutput, 0, "Should get swap output");
        assertEq(savedAmount, 0, "Saved amount should be 0");
        assertEq(netOutput, swapOutput, "Net output should equal full swap output");

        console.log("No savings impact preview working correctly");
        console.log("SUCCESS: No savings impact preview working");
    }

    function testQuoter_PreviewSavingsImpactFullSavings() public {
        console.log("\n=== P8 ENHANCED: Testing Savings Impact Preview with Full Savings ===");

        // Preview with 100% savings (edge case)
        (uint256 swapOutput, uint256 savedAmount, uint256 netOutput) = quoter.previewSavingsImpact(
            poolKeyAB,
            true,
            uint128(SWAP_AMOUNT),
            10000 // 100% savings
        );

        // Verify calculations
        assertGt(swapOutput, 0, "Should get swap output");
        assertEq(savedAmount, SWAP_AMOUNT, "Saved amount should be full input");
        assertEq(netOutput, 0, "Net output should be 0 (all saved)");

        console.log("Full savings impact preview working correctly");
        console.log("SUCCESS: Full savings impact preview working");
    }

    // ==================== DCA QUOTE TESTS ====================

    function testQuoter_GetDCAQuote() public {
        console.log("\n=== P8 ENHANCED: Testing DCA Quote ===");

        // Get DCA quote
        (uint256 amountOut, uint256 gasEstimate) = quoter.getDCAQuote(
            poolKeyAB,
            true,
            uint128(DCA_AMOUNT)
        );

        // Verify quote
        assertGt(amountOut, 0, "Should get output amount");
        assertGt(gasEstimate, 0, "Should estimate gas");

        // Gas estimate should include DCA overhead
        assertGt(gasEstimate, 50000, "Gas estimate should include DCA overhead");

        console.log("DCA quote successful");
        console.log("Amount out:", amountOut, "Gas estimate:", gasEstimate);
        console.log("SUCCESS: DCA quote working");
    }

    function testQuoter_GetDCAQuoteZeroAmount() public {
        console.log("\n=== P8 ENHANCED: Testing DCA Quote with Zero Amount ===");

        // Get DCA quote with zero amount
        (uint256 amountOut, uint256 gasEstimate) = quoter.getDCAQuote(
            poolKeyAB,
            true,
            0
        );

        // Should handle gracefully
        assertEq(amountOut, 0, "Amount out should be 0");
        assertGt(gasEstimate, 0, "Gas estimate should still be provided");

        console.log("Zero amount DCA quote handled correctly");
        console.log("SUCCESS: Zero amount DCA quote working");
    }

    // ==================== MULTI-HOP ROUTING PREVIEW TESTS ====================

    function testQuoter_PreviewMultiHopRouting() public {
        console.log("\n=== P8 ENHANCED: Testing Multi-Hop Routing Preview ===");

        // Create multi-hop path: A -> B -> C
        PathKey[] memory path = new PathKey[](2);

        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook)),
            hookData: ""
        });

        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenC)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook)),
            hookData: ""
        });

        // Preview multi-hop routing
        (uint256 amountOut, uint256 gasEstimate) = quoter.previewMultiHopRouting(
            Currency.wrap(address(tokenA)),
            path,
            uint128(SWAP_AMOUNT)
        );

        // Verify preview
        assertGt(amountOut, 0, "Should get output amount");
        assertGt(gasEstimate, 0, "Should estimate gas");

        console.log("Multi-hop routing preview successful");
        console.log("Amount out:", amountOut, "Gas estimate:", gasEstimate);
        console.log("SUCCESS: Multi-hop routing preview working");
    }

    function testQuoter_PreviewMultiHopRoutingEmptyPath() public {
        console.log("\n=== P8 ENHANCED: Testing Multi-Hop Routing with Empty Path ===");

        PathKey[] memory emptyPath = new PathKey[](0);

        // Should revert with empty path
        vm.expectRevert("Empty path");
        quoter.previewMultiHopRouting(Currency.wrap(address(tokenA)), emptyPath, uint128(SWAP_AMOUNT));

        console.log("Empty path protection working");
        console.log("SUCCESS: Empty path protection working");
    }

    function testQuoter_PreviewMultiHopRoutingZeroAmount() public {
        console.log("\n=== P8 ENHANCED: Testing Multi-Hop Routing with Zero Amount ===");

        // Create simple path
        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook)),
            hookData: ""
        });

        // Should revert with zero amount
        vm.expectRevert("Zero amount");
        quoter.previewMultiHopRouting(Currency.wrap(address(tokenA)), path, 0);

        console.log("Zero amount protection working");
        console.log("SUCCESS: Zero amount protection working");
    }

    // ==================== INTEGRATION WITH SAVINGS STRATEGY TESTS ====================

    function testQuoter_SavingsImpactWithUserStrategy() public {
        console.log("\n=== P8 ENHANCED: Testing Savings Impact with User Strategy ===");

        // Setup user's savings strategy
        (uint256 percentage,,,) = storageContract.getPackedUserConfig(alice);
        assertEq(percentage, SAVINGS_PERCENTAGE, "User strategy should be set");

        // Preview savings impact using user's strategy
        (uint256 swapOutput, uint256 savedAmount, uint256 netOutput) = quoter.previewSavingsImpact(
            poolKeyAB,
            true,
            uint128(SWAP_AMOUNT),
            percentage // Use user's actual strategy
        );

        // Verify calculations with user's strategy
        uint256 expectedSavings = (SWAP_AMOUNT * percentage) / 10000;
        assertEq(savedAmount, expectedSavings, "Should use user's savings percentage");

        console.log("Savings impact with user strategy working correctly");
        console.log("SUCCESS: Savings impact with user strategy working");
    }

    // ==================== EDGE CASES AND ERROR HANDLING TESTS ====================

    function testQuoter_PreviewSavingsImpactInvalidPool() public {
        console.log("\n=== P8 ENHANCED: Testing Savings Impact with Invalid Pool ===");

        // Create invalid pool key (non-existent pool)
        PoolKey memory invalidPoolKey = PoolKey({
            currency0: Currency.wrap(address(0x01)), // Invalid address
            currency1: Currency.wrap(address(0x02)), // Invalid address
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Should revert with PoolNotInitialized for invalid pool
        vm.expectRevert(); // Expecting PoolNotInitialized from V4 PoolManager
        quoter.previewSavingsImpact(
            invalidPoolKey,
            true,
            uint128(SWAP_AMOUNT),
            SAVINGS_PERCENTAGE
        );

        console.log("Invalid pool correctly reverts");
        console.log("SUCCESS: Invalid pool error handling working");
    }

    function testQuoter_MultiHopRoutingComplexPath() public {
        console.log("\n=== P8 ENHANCED: Testing Complex Multi-Hop Routing ===");

        // Create 3-hop path: A -> B -> C -> A (cycle)
        PathKey[] memory complexPath = new PathKey[](3);

        complexPath[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook)),
            hookData: ""
        });

        complexPath[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenC)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook)),
            hookData: ""
        });

        complexPath[2] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenA)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook)),
            hookData: ""
        });

        // Preview complex routing
        (uint256 amountOut, uint256 gasEstimate) = quoter.previewMultiHopRouting(
            Currency.wrap(address(tokenA)),
            complexPath,
            uint128(SWAP_AMOUNT)
        );

        // Verify complex routing preview
        assertGt(amountOut, 0, "Should handle complex path");
        assertGt(gasEstimate, 0, "Should estimate gas for complex path");

        console.log("Complex multi-hop routing preview successful");
        console.log("SUCCESS: Complex multi-hop routing working");
    }

    // ==================== PERFORMANCE AND GAS ESTIMATION TESTS ====================

    function testQuoter_GasEstimationAccuracy() public {
        console.log("\n=== P8 ENHANCED: Testing Gas Estimation Accuracy ===");

        // Get DCA quote with gas estimation
        (uint256 amountOut, uint256 estimatedGas) = quoter.getDCAQuote(
            poolKeyAB,
            true,
            uint128(DCA_AMOUNT)
        );

        assertGt(estimatedGas, 0, "Should provide gas estimate");

        // Gas estimate should be reasonable (not too high or low)
        assertGt(estimatedGas, 30000, "Gas estimate should be at least 30k");
        assertLt(estimatedGas, 500000, "Gas estimate should be less than 500k");

        console.log("Gas estimation accuracy verified");
        console.log("Estimated gas:", estimatedGas);
        console.log("SUCCESS: Gas estimation accuracy working");
    }

    function testQuoter_MultiHopGasEstimation() public {
        console.log("\n=== P8 ENHANCED: Testing Multi-Hop Gas Estimation ===");

        // Create 2-hop path
        PathKey[] memory path = new PathKey[](2);

        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook)),
            hookData: ""
        });

        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenC)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook)),
            hookData: ""
        });

        // Get multi-hop gas estimation
        (uint256 amountOut, uint256 estimatedGas) = quoter.previewMultiHopRouting(
            Currency.wrap(address(tokenA)),
            path,
            uint128(SWAP_AMOUNT)
        );

        // Multi-hop should have higher gas estimate than single hop
        (, uint256 singleHopGas) = quoter.getDCAQuote(poolKeyAB, true, uint128(SWAP_AMOUNT));

        assertGt(estimatedGas, singleHopGas, "Multi-hop should have higher gas estimate");

        console.log("Multi-hop gas estimation working");
        console.log("Multi-hop gas:", estimatedGas, "Single-hop gas:", singleHopGas);
        console.log("SUCCESS: Multi-hop gas estimation working");
    }

    // ==================== INTEGRATION TESTS ====================

    function testQuoter_CompleteWorkflow() public {
        console.log("\n=== P8 ENHANCED: Testing Complete Quoter Workflow ===");

        // 1. Setup user's savings strategy
        (uint256 percentage,,,) = storageContract.getPackedUserConfig(alice);
        assertEq(percentage, SAVINGS_PERCENTAGE, "User strategy should be configured");

        // 2. Preview savings impact using user's strategy
        (uint256 fullSwapOutput, uint256 savedAmount, uint256 netOutput) = quoter.previewSavingsImpact(
            poolKeyAB,
            true,
            uint128(SWAP_AMOUNT),
            percentage
        );

        assertGt(fullSwapOutput, 0, "Should get full swap output");
        assertGt(savedAmount, 0, "Should calculate savings");
        assertLt(netOutput, fullSwapOutput, "Net output should be reduced by savings");

        // 3. Get DCA quote for comparison
        (uint256 dcaAmountOut, uint256 dcaGasEstimate) = quoter.getDCAQuote(
            poolKeyAB,
            true,
            uint128(DCA_AMOUNT)
        );

        assertGt(dcaAmountOut, 0, "Should get DCA output");
        assertGt(dcaGasEstimate, 0, "Should estimate DCA gas");

        // 4. Preview multi-hop routing
        PathKey[] memory path = new PathKey[](2);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenB)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook)),
            hookData: ""
        });
        path[1] = PathKey({
            intermediateCurrency: Currency.wrap(address(tokenC)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook)),
            hookData: ""
        });

        (uint256 multiHopOutput, uint256 multiHopGas) = quoter.previewMultiHopRouting(
            Currency.wrap(address(tokenA)),
            path,
            uint128(SWAP_AMOUNT)
        );

        assertGt(multiHopOutput, 0, "Should get multi-hop output");
        assertGt(multiHopGas, 0, "Should estimate multi-hop gas");

        // 5. Compare gas estimates
        assertGt(multiHopGas, dcaGasEstimate, "Multi-hop should have higher gas estimate than single DCA");

        console.log("Complete quoter workflow successful");
        console.log("Savings impact - Full:", fullSwapOutput);
        console.log("Saved:", savedAmount);
        console.log("Net:", netOutput);
        console.log("DCA quote - Output:", dcaAmountOut);
        console.log("DCA Gas:", dcaGasEstimate);
        console.log("Multi-hop - Output:", multiHopOutput);
        console.log("Multi-hop Gas:", multiHopGas);
        console.log("SUCCESS: Complete quoter workflow verified");
    }

    function testQuoter_ComprehensiveReport() public {
        console.log("\n=== P8 ENHANCED: COMPREHENSIVE QUOTER REPORT ===");

        // Run all quoter tests
        testQuoter_PreviewSavingsImpact();
        testQuoter_PreviewSavingsImpactNoSavings();
        testQuoter_PreviewSavingsImpactFullSavings();
        testQuoter_GetDCAQuote();
        testQuoter_GetDCAQuoteZeroAmount();
        testQuoter_PreviewMultiHopRouting();
        testQuoter_PreviewMultiHopRoutingEmptyPath();
        testQuoter_PreviewMultiHopRoutingZeroAmount();
        testQuoter_SavingsImpactWithUserStrategy();
        testQuoter_PreviewSavingsImpactInvalidPool();
        testQuoter_MultiHopRoutingComplexPath();
        testQuoter_GasEstimationAccuracy();
        testQuoter_MultiHopGasEstimation();
        testQuoter_CompleteWorkflow();

        console.log("\n=== FINAL QUOTER RESULTS ===");
        console.log("PASS - Savings Impact Preview: PASS");
        console.log("PASS - No Savings Impact Preview: PASS");
        console.log("PASS - Full Savings Impact Preview: PASS");
        console.log("PASS - DCA Quote: PASS");
        console.log("PASS - Zero Amount DCA Quote: PASS");
        console.log("PASS - Multi-Hop Routing Preview: PASS");
        console.log("PASS - Empty Path Protection: PASS");
        console.log("PASS - Zero Amount Protection: PASS");
        console.log("PASS - User Strategy Integration: PASS");
        console.log("PASS - Invalid Pool Handling: PASS");
        console.log("PASS - Complex Multi-Hop Routing: PASS");
        console.log("PASS - Gas Estimation Accuracy: PASS");
        console.log("PASS - Multi-Hop Gas Estimation: PASS");
        console.log("PASS - Complete Quoter Workflow: PASS");

        console.log("\n=== QUOTER SUMMARY ===");
        console.log("Total quoter scenarios: 14");
        console.log("Scenarios passing: 14");
        console.log("Success rate: 100%");
        console.log("SUCCESS: Complete SpendSaveQuoter functionality verified!");
    }
}

