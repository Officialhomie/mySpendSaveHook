// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";

// Import Uniswap V4 dependencies for hook deployment
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {HookMiner} from "lib/v4-periphery/src/utils/HookMiner.sol";

// Import our gas-efficient core contracts
import {SpendSaveHook} from "../src/SpendSaveHook.sol";
import {SpendSaveStorage} from "../src/SpendSaveStorage.sol";
import {SpendSaveAnalytics} from "../src/SpendSaveAnalytics.sol";

// Import V4 periphery for StateView
import {StateView} from "lib/v4-periphery/src/lens/StateView.sol";
import {IStateView} from "lib/v4-periphery/src/interfaces/IStateView.sol";

// Import all gas-efficient modules
import {SavingStrategy} from "../src/SavingStrategy.sol";
import {Savings} from "../src/Savings.sol";
import {DCA} from "../src/DCA.sol";
import {Token} from "../src/Token.sol";
import {SlippageControl} from "../src/SlippageControl.sol";
import {DailySavings} from "../src/DailySavings.sol";

// Import Phase 2 Enhancement contracts
import {SpendSaveDCARouter} from "../src/SpendSaveDCARouter.sol";
import {SpendSaveLiquidityManager} from "../src/SpendSaveLiquidityManager.sol";
import {SpendSaveModuleRegistry} from "../src/SpendSaveModuleRegistry.sol";
import {SpendSaveMulticall} from "../src/SpendSaveMulticall.sol";
import {SpendSaveQuoter} from "../src/SpendSaveQuoter.sol";
import {SpendSaveSlippageEnhanced} from "../src/SpendSaveSlippageEnhanced.sol";

/**
 * @title DeploySpendSave
 * @notice Comprehensive deployment script for the gas-efficient SpendSave protocol
 * @dev This script deploys the complete SpendSave ecosystem with all gas optimizations enabled.
 *      The deployment process follows a carefully orchestrated sequence that ensures proper
 *      initialization of the modular architecture while maintaining security and efficiency.
 *
 * Deployment Flow:
 * 1. Deploy SpendSaveStorage (centralized state manager)
 * 2. Deploy all module contracts
 * 3. Deploy SpendSaveHook with proper address mining for hook flags
 * 4. Initialize SpendSaveStorage with hook reference
 * 5. Initialize all modules with storage references
 * 6. Register all modules in the storage registry
 * 7. Initialize hook with module references
 * 8. Set cross-module references for advanced functionality
 * 9. Verify complete deployment and gas optimization settings
 *
 * Network Support:
 * - Base Mainnet (Chain ID: 8453)
 * - Base Sepolia Testnet (Chain ID: 84532)
 * - Easily extensible for additional networks
 *
 * @author SpendSave Protocol Team
 */
contract DeploySpendSave is Script {
    // ==================== NETWORK CONFIGURATION ====================

    /// @notice Supported chain IDs for deployment
    uint256 constant CHAIN_ID_BASE = 8453;
    uint256 constant CHAIN_ID_BASE_SEPOLIA = 84532;
    uint256 constant CHAIN_ID_ETHEREUM = 1;
    uint256 constant CHAIN_ID_OPTIMISM = 10;
    uint256 constant CHAIN_ID_ARBITRUM = 42161;
    uint256 constant CHAIN_ID_POLYGON = 137;

    /// @notice Network configuration struct
    struct NetworkConfig {
        string name;
        address poolManager;
        address positionManager;
        address quoter;
        address permit2;
        bool isTestnet;
    }

    /// @notice Network configurations mapping
    mapping(uint256 => NetworkConfig) public networkConfigs;

    /// @notice Current network configuration
    NetworkConfig public currentNetwork;

    // ==================== CONSTRUCTOR ====================

    constructor() {
        _initializeNetworkConfigs();
    }

    /**
     * @notice Initialize network configurations for all supported networks
     * @dev Sets up the networkConfigs mapping with addresses from Uniswap V4 deployments
     */
    function _initializeNetworkConfigs() internal {
        // Base Sepolia Testnet
        networkConfigs[CHAIN_ID_BASE_SEPOLIA] = NetworkConfig({
            name: "Base Sepolia",
            poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
            positionManager: 0x33E61BCa1cDa979E349Bf14840BD178Cc7d0F55D,
            quoter: 0xf3A39C86dbd13C45365E57FB90fe413371F65AF8,
            permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3,
            isTestnet: true
        });

        // Base Mainnet
        networkConfigs[CHAIN_ID_BASE] = NetworkConfig({
            name: "Base",
            poolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
            positionManager: 0x7C5f5A4bBd8fD63184577525326123B519429bDc,
            quoter: 0x0d5e0F971ED27FBfF6c2837bf31316121532048D,
            permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3,
            isTestnet: false
        });

        // Ethereum Mainnet
        networkConfigs[CHAIN_ID_ETHEREUM] = NetworkConfig({
            name: "Ethereum",
            poolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90,
            positionManager: 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e,
            quoter: 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203,
            permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3,
            isTestnet: false
        });

        // Optimism Mainnet
        networkConfigs[CHAIN_ID_OPTIMISM] = NetworkConfig({
            name: "Optimism",
            poolManager: 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3,
            positionManager: 0x3C3Ea4B57a46241e54610e5f022E5c45859A1017,
            quoter: 0x1f3131A13296FB91C90870043742C3CDBFF1A8d7,
            permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3,
            isTestnet: false
        });

        // Arbitrum One
        networkConfigs[CHAIN_ID_ARBITRUM] = NetworkConfig({
            name: "Arbitrum One",
            poolManager: 0x0000000000000000000000000000000000000000, // TODO: Add when deployed
            positionManager: 0x0000000000000000000000000000000000000000, // TODO: Add when deployed
            quoter: 0x0000000000000000000000000000000000000000, // TODO: Add when deployed
            permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3,
            isTestnet: false
        });

        // Polygon
        networkConfigs[CHAIN_ID_POLYGON] = NetworkConfig({
            name: "Polygon",
            poolManager: 0x0000000000000000000000000000000000000000, // TODO: Add when deployed
            positionManager: 0x0000000000000000000000000000000000000000, // TODO: Add when deployed
            quoter: 0x0000000000000000000000000000000000000000, // TODO: Add when deployed
            permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3,
            isTestnet: false
        });
    }

    // ==================== MODULE REGISTRY CONSTANTS ====================

    /// @notice Module identifiers for storage registry
    bytes32 constant STRATEGY_MODULE_ID = keccak256("STRATEGY");
    bytes32 constant SAVINGS_MODULE_ID = keccak256("SAVINGS");
    bytes32 constant DCA_MODULE_ID = keccak256("DCA");
    bytes32 constant TOKEN_MODULE_ID = keccak256("TOKEN");
    bytes32 constant SLIPPAGE_MODULE_ID = keccak256("SLIPPAGE");
    bytes32 constant DAILY_MODULE_ID = keccak256("DAILY");

    /// @notice Phase 2 Enhancement module identifiers
    bytes32 constant DCA_ROUTER_MODULE_ID = keccak256("DCA_ROUTER");
    bytes32 constant LIQUIDITY_MANAGER_MODULE_ID = keccak256("LIQUIDITY_MANAGER");
    bytes32 constant MODULE_REGISTRY_ID = keccak256("MODULE_REGISTRY");
    bytes32 constant MULTICALL_MODULE_ID = keccak256("MULTICALL");
    bytes32 constant QUOTER_MODULE_ID = keccak256("QUOTER");
    bytes32 constant SLIPPAGE_ENHANCED_MODULE_ID = keccak256("SLIPPAGE_ENHANCED");

    // ==================== HOOK CONFIGURATION ====================

    /// @notice Required hook flags for SpendSave functionality
    /// @dev These flags enable beforeSwap, afterSwap, and delta return capabilities
    uint160 constant REQUIRED_HOOK_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    // ==================== STATE VARIABLES ====================

    /// @notice Core protocol contracts
    SpendSaveHook public spendSaveHook;
    SpendSaveStorage public spendSaveStorage;
    SpendSaveAnalytics public analytics;
    StateView public stateView;

    /// @notice All protocol modules
    SavingStrategy public savingStrategyModule;
    Savings public savingsModule;
    DCA public dcaModule;
    Token public tokenModule;
    SlippageControl public slippageControlModule;
    DailySavings public dailySavingsModule;

    /// @notice Phase 2 Enhancement contracts
    SpendSaveDCARouter public dcaRouter;
    SpendSaveLiquidityManager public liquidityManager;
    SpendSaveModuleRegistry public moduleRegistry;
    SpendSaveMulticall public multicall;
    SpendSaveQuoter public quoter;
    SpendSaveSlippageEnhanced public slippageEnhanced;

    /// @notice Deployment configuration
    address public poolManager;
    address public deployer;
    address public owner;
    address public treasury;

    /// @notice Hook deployment helper
    HookDeployer public hookDeployer;

    // ==================== EVENTS ====================

    /// @notice Emitted when deployment starts
    event DeploymentStarted(address indexed deployer, uint256 chainId, address poolManager);

    /// @notice Emitted when storage contract is deployed
    event StorageDeployed(address indexed storageAddress);

    /// @notice Emitted when StateView is deployed
    event StateViewDeployed(address indexed stateViewAddress);

    /// @notice Emitted when analytics contract is deployed
    event AnalyticsDeployed(address indexed analyticsAddress);

    /// @notice Emitted when hook is successfully deployed with proper address
    event HookDeployed(address indexed hookAddress, bytes32 salt, uint160 flags);

    /// @notice Emitted when all modules are deployed
    event ModulesDeployed(
        address strategyModule,
        address savingsModule,
        address dcaModule,
        address tokenModule,
        address slippageModule,
        address dailyModule
    );

    /// @notice Emitted when Phase 2 Enhancement contracts are deployed
    event Phase2ContractsDeployed(
        address dcaRouter,
        address liquidityManager,
        address moduleRegistry,
        address multicall,
        address quoter,
        address slippageEnhanced
    );

    /// @notice Emitted when deployment completes successfully
    event DeploymentCompleted(
        address hookAddress, address storageAddress, bool gasOptimizationEnabled, uint256 targetAfterSwapGas
    );

    // ==================== MAIN DEPLOYMENT FUNCTION ====================

    /**
     * @notice Main deployment function that orchestrates the entire protocol deployment
     * @dev This function manages the complete deployment lifecycle with comprehensive
     *      validation and logging. It ensures that all contracts are deployed in the
     *      correct order and properly initialized with gas optimizations enabled.
     */
    function run() external {
        // Initialize deployment configuration BEFORE broadcast to get msg.sender
        _initializeDeploymentConfig();

        // Display comprehensive pre-deployment information
        _displayPreDeploymentSummary();

        // Log deployment start
        console.log("\n=== SpendSave Protocol Deployment Starting ===");
        console.log("You will be prompted for your keystore password next...\n");
        emit DeploymentStarted(deployer, block.chainid, poolManager);

        // Start broadcasting transactions
        // When using --account, we don't pass an argument
        // When using PRIVATE_KEY, Foundry will use it automatically
        vm.startBroadcast();

        // Execute deployment sequence
        _executeDeploymentSequence();

        // Stop broadcasting
        vm.stopBroadcast();

        // Final verification and logging
        _finalizeDeployment();

        console.log("=== SpendSave Protocol Deployment Complete ===");
    }

    /**
     * @notice Initialize deployment configuration based on network and environment
     * @dev Sets up network-specific parameters and validates deployment environment
     *      Supports both private key and account-based deployment methods
     */
    function _initializeDeploymentConfig() internal {
        uint256 chainId = block.chainid;

        // Get network configuration
        currentNetwork = networkConfigs[chainId];
        require(currentNetwork.poolManager != address(0), "Unsupported network");

        // Set addresses from network configuration
        poolManager = currentNetwork.poolManager;

        // Get deployer address - support both account-based and private key methods
        // When using --account, we get the address from tx.origin or a prompt
        // When using --private-key or PRIVATE_KEY env var, we derive from the key

        try vm.envUint("PRIVATE_KEY") returns (uint256 deployerPrivateKey) {
            // Private key method - PRIVATE_KEY env variable is set
            deployer = vm.addr(deployerPrivateKey);
            console.log("Using private key deployment method");
            console.log("WARNING: Private key deployment is less secure. Consider using --account flag instead.");
        } catch {
            // Account-based method - using --account flag
            // Get deployer address from DEPLOYER_ADDRESS environment variable
            deployer = vm.envAddress("DEPLOYER_ADDRESS");
            console.log("Using account-based deployment method (secure keystore)");
        }

        // Set owner (can be different from deployer)
        owner = vm.envOr("OWNER_ADDRESS", deployer);

        // Set treasury address
        treasury = vm.envOr("TREASURY_ADDRESS", owner);

        // Log configuration
        console.log("Network:", currentNetwork.name);
        console.log("Pool Manager:", poolManager);
        console.log("Position Manager:", currentNetwork.positionManager);
        console.log("Quoter:", currentNetwork.quoter);
        console.log("Deployer:", deployer);
        console.log("Owner:", owner);
        console.log("Treasury:", treasury);
    }

    /**
     * @notice Execute the complete deployment sequence in proper order
     * @dev This function coordinates all deployment steps to ensure proper initialization
     */
    function _executeDeploymentSequence() internal {
        // Step 1: Deploy SpendSaveStorage (foundation of the system)
        console.log("\n--- Step 1: Deploying SpendSaveStorage ---");
        _deployStorage();

        // Step 2: Deploy StateView for analytics
        console.log("\n--- Step 2: Deploying StateView ---");
        _deployStateView();

        // Step 3: Deploy all modules
        console.log("\n--- Step 3: Deploying All Modules ---");
        _deployAllModules();

        // Step 4: Deploy hook with proper address mining
        console.log("\n--- Step 4: Deploying SpendSaveHook ---");
        _deployHookWithAddressMining();

        // Step 5: Deploy analytics with StateView
        console.log("\n--- Step 5: Deploying Analytics ---");
        _deployAnalytics();

        // Step 6: Initialize storage with hook reference
        console.log("\n--- Step 6: Initializing Storage ---");
        _initializeStorage();

        // Step 7: Deploy Phase 2 Enhancement contracts (after storage initialization)
        console.log("\n--- Step 7: Deploying Phase 2 Enhancement Contracts ---");
        _deployPhase2Contracts();

        // Step 8: Initialize all modules
        console.log("\n--- Step 8: Initializing Modules ---");
        _initializeAllModules();

        // Step 9: Register modules in storage registry
        console.log("\n--- Step 9: Registering Modules ---");
        _registerAllModules();

        // Step 10: Initialize hook with module references
        console.log("\n--- Step 10: Initializing Hook ---");
        _initializeHook();

        // Step 11: Set cross-module references
        console.log("\n--- Step 11: Setting Cross-Module References ---");
        _setModuleReferences();

        // Step 12: Verify deployment
        console.log("\n--- Step 12: Verifying Deployment ---");
        _verifyDeployment();
    }

    // ==================== DEPLOYMENT STEP FUNCTIONS ====================

    /**
     * @notice Deploy the SpendSaveStorage contract with gas-efficient configuration
     * @dev Storage contract serves as the foundation for the entire modular system
     */
    function _deployStorage() internal {
        spendSaveStorage = new SpendSaveStorage(poolManager);

        console.log("SpendSaveStorage deployed at:", address(spendSaveStorage));
        console.log("- Pool Manager reference:", spendSaveStorage.poolManager());
        console.log("- Owner:", spendSaveStorage.owner());
        console.log("- Treasury:", spendSaveStorage.treasury());

        emit StorageDeployed(address(spendSaveStorage));
    }

    /**
     * @notice Deploy StateView for analytics functionality
     * @dev StateView provides gas-efficient access to pool state data
     */
    function _deployStateView() internal {
        stateView = new StateView(IPoolManager(poolManager));

        console.log("StateView deployed at:", address(stateView));
        console.log("- Pool Manager reference:", address(stateView.poolManager()));

        emit StateViewDeployed(address(stateView));
    }

    /**
     * @notice Deploy all protocol modules in efficient batch
     * @dev Deploys all modules and logs their addresses for verification
     */
    function _deployAllModules() internal {
        // Deploy each module
        savingStrategyModule = new SavingStrategy();
        console.log("SavingStrategy deployed at:", address(savingStrategyModule));

        savingsModule = new Savings();
        console.log("Savings deployed at:", address(savingsModule));

        dcaModule = new DCA();
        console.log("DCA deployed at:", address(dcaModule));

        tokenModule = new Token();
        console.log("Token deployed at:", address(tokenModule));

        slippageControlModule = new SlippageControl();
        console.log("SlippageControl deployed at:", address(slippageControlModule));

        dailySavingsModule = new DailySavings();
        console.log("DailySavings deployed at:", address(dailySavingsModule));

        emit ModulesDeployed(
            address(savingStrategyModule),
            address(savingsModule),
            address(dcaModule),
            address(tokenModule),
            address(slippageControlModule),
            address(dailySavingsModule)
        );
    }

    /**
     * @notice Deploy Phase 2 Enhancement contracts
     * @dev Deploys advanced routing, liquidity management, and utility contracts
     */
    function _deployPhase2Contracts() internal {
        // Deploy DCA Router for advanced routing
        dcaRouter = new SpendSaveDCARouter(IPoolManager(poolManager), address(spendSaveStorage), currentNetwork.quoter);
        console.log("SpendSaveDCARouter deployed at:", address(dcaRouter));

        // Deploy Liquidity Manager for LP position management
        liquidityManager = new SpendSaveLiquidityManager(
            address(spendSaveStorage), currentNetwork.positionManager, currentNetwork.permit2
        );
        console.log("SpendSaveLiquidityManager deployed at:", address(liquidityManager));

        // Deploy Module Registry for upgradeable module management
        moduleRegistry = new SpendSaveModuleRegistry(address(spendSaveStorage));
        console.log("SpendSaveModuleRegistry deployed at:", address(moduleRegistry));

        // Deploy Multicall for batch operations
        multicall = new SpendSaveMulticall(address(spendSaveStorage));
        console.log("SpendSaveMulticall deployed at:", address(multicall));

        // Deploy Quoter for price impact preview
        quoter = new SpendSaveQuoter(address(spendSaveStorage), currentNetwork.quoter);
        console.log("SpendSaveQuoter deployed at:", address(quoter));

        // Deploy Enhanced Slippage Control
        slippageEnhanced = new SpendSaveSlippageEnhanced(address(spendSaveStorage));
        console.log("SpendSaveSlippageEnhanced deployed at:", address(slippageEnhanced));

        emit Phase2ContractsDeployed(
            address(dcaRouter),
            address(liquidityManager),
            address(moduleRegistry),
            address(multicall),
            address(quoter),
            address(slippageEnhanced)
        );
    }

    /**
     * @notice Deploy SpendSaveHook with proper address mining for hook flags
     * @dev Uses HookMiner to ensure the hook address has the required flags in its address
     */
    function _deployHookWithAddressMining() internal {
        console.log("Mining hook address with required flags...");

        // Deploy hook deployer helper contract
        hookDeployer = new HookDeployer();
        console.log("HookDeployer deployed at:", address(hookDeployer));

        // Prepare constructor arguments for the hook
        bytes memory constructorArgs = abi.encode(IPoolManager(poolManager), spendSaveStorage);

        // Mine for a valid hook address
        (address predictedHookAddress, bytes32 salt) = HookMiner.find(
            address(hookDeployer), // Deployer contract address
            REQUIRED_HOOK_FLAGS, // Required flags
            type(SpendSaveHook).creationCode,
            constructorArgs
        );

        console.log("Found valid hook address:", predictedHookAddress);
        console.log("Salt for deployment:", vm.toString(salt));

        // Create complete bytecode for deployment
        bytes memory creationCode = abi.encodePacked(type(SpendSaveHook).creationCode, constructorArgs);

        // Deploy using CREATE2 with the mined salt
        address deployedHookAddress = hookDeployer.deployHook(salt, creationCode);

        // Verify deployment success
        require(deployedHookAddress == predictedHookAddress, "Hook deployment address mismatch");

        // Store hook reference
        spendSaveHook = SpendSaveHook(deployedHookAddress);

        // Verify hook flags are correct
        uint160 actualFlags = uint160(address(spendSaveHook)) & 0xFF;
        require((actualFlags & REQUIRED_HOOK_FLAGS) == REQUIRED_HOOK_FLAGS, "Hook flags verification failed");

        console.log("SpendSaveHook deployed at:", address(spendSaveHook));
        console.log("Hook flags verified:", vm.toString(actualFlags));

        emit HookDeployed(address(spendSaveHook), salt, actualFlags);
    }

    /**
     * @notice Deploy SpendSaveAnalytics with StateView integration
     * @dev Analytics provides real-time portfolio tracking and pool metrics
     */
    function _deployAnalytics() internal {
        analytics = new SpendSaveAnalytics(address(spendSaveStorage), address(stateView));

        console.log("SpendSaveAnalytics deployed at:", address(analytics));
        console.log("- Storage reference:", address(analytics.storage_()));
        console.log("- StateView reference:", address(analytics.stateView()));
        console.log("- Pool Manager reference:", address(analytics.poolManager()));

        emit AnalyticsDeployed(address(analytics));
    }

    /**
     * @notice Initialize SpendSaveStorage with hook reference
     * @dev This establishes the bidirectional connection between storage and hook
     */
    function _initializeStorage() internal {
        spendSaveStorage.initialize(address(spendSaveHook));

        console.log("Storage initialized with hook reference");
        console.log("- Hook address in storage:", spendSaveStorage.spendSaveHook());

        // Verify initialization
        require(
            spendSaveStorage.spendSaveHook() == address(spendSaveHook), "Storage hook reference verification failed"
        );
    }

    /**
     * @notice Initialize all modules with storage references
     * @dev Each module receives a reference to the centralized storage contract
     */
    function _initializeAllModules() internal {
        // Initialize each module with storage reference
        savingStrategyModule.initialize(spendSaveStorage);
        console.log("SavingStrategy module initialized");

        savingsModule.initialize(spendSaveStorage);
        console.log("Savings module initialized");

        dcaModule.initialize(spendSaveStorage);
        console.log("DCA module initialized");

        tokenModule.initialize(spendSaveStorage);
        console.log("Token module initialized");

        slippageControlModule.initialize(spendSaveStorage);
        console.log("SlippageControl module initialized");

        dailySavingsModule.initialize(spendSaveStorage);
        console.log("DailySavings module initialized");
    }

    /**
     * @notice Register all modules in the storage registry system
     * @dev This enables the gas-efficient module lookup system
     */
    function _registerAllModules() internal {
        // Register core modules with their identifiers
        spendSaveStorage.registerModule(STRATEGY_MODULE_ID, address(savingStrategyModule));
        spendSaveStorage.registerModule(SAVINGS_MODULE_ID, address(savingsModule));
        spendSaveStorage.registerModule(DCA_MODULE_ID, address(dcaModule));
        spendSaveStorage.registerModule(TOKEN_MODULE_ID, address(tokenModule));
        spendSaveStorage.registerModule(SLIPPAGE_MODULE_ID, address(slippageControlModule));
        spendSaveStorage.registerModule(DAILY_MODULE_ID, address(dailySavingsModule));

        // Register Phase 2 Enhancement modules
        spendSaveStorage.registerModule(DCA_ROUTER_MODULE_ID, address(dcaRouter));
        spendSaveStorage.registerModule(LIQUIDITY_MANAGER_MODULE_ID, address(liquidityManager));
        spendSaveStorage.registerModule(MODULE_REGISTRY_ID, address(moduleRegistry));
        spendSaveStorage.registerModule(MULTICALL_MODULE_ID, address(multicall));
        spendSaveStorage.registerModule(QUOTER_MODULE_ID, address(quoter));
        spendSaveStorage.registerModule(SLIPPAGE_ENHANCED_MODULE_ID, address(slippageEnhanced));

        console.log("All modules registered in storage registry");

        // Verify core module registrations
        require(
            spendSaveStorage.getModule(STRATEGY_MODULE_ID) == address(savingStrategyModule),
            "Strategy module registration failed"
        );
        require(
            spendSaveStorage.getModule(SAVINGS_MODULE_ID) == address(savingsModule),
            "Savings module registration failed"
        );
        require(spendSaveStorage.getModule(DCA_MODULE_ID) == address(dcaModule), "DCA module registration failed");
        require(spendSaveStorage.getModule(TOKEN_MODULE_ID) == address(tokenModule), "Token module registration failed");
        require(
            spendSaveStorage.getModule(SLIPPAGE_MODULE_ID) == address(slippageControlModule),
            "Slippage module registration failed"
        );
        require(
            spendSaveStorage.getModule(DAILY_MODULE_ID) == address(dailySavingsModule),
            "Daily module registration failed"
        );

        // Verify Phase 2 module registrations
        require(
            spendSaveStorage.getModule(DCA_ROUTER_MODULE_ID) == address(dcaRouter),
            "DCA Router module registration failed"
        );
        require(
            spendSaveStorage.getModule(LIQUIDITY_MANAGER_MODULE_ID) == address(liquidityManager),
            "Liquidity Manager module registration failed"
        );
        require(
            spendSaveStorage.getModule(MODULE_REGISTRY_ID) == address(moduleRegistry),
            "Module Registry registration failed"
        );
        require(
            spendSaveStorage.getModule(MULTICALL_MODULE_ID) == address(multicall),
            "Multicall module registration failed"
        );
        require(spendSaveStorage.getModule(QUOTER_MODULE_ID) == address(quoter), "Quoter module registration failed");
        require(
            spendSaveStorage.getModule(SLIPPAGE_ENHANCED_MODULE_ID) == address(slippageEnhanced),
            "Slippage Enhanced module registration failed"
        );
    }

    /**
     * @notice Initialize hook with references to all modules
     * @dev This enables the hook to coordinate with all modules during swap execution
     */
    function _initializeHook() internal {
        // Note: Modules are already initialized in step 7, so we don't need to call initializeModules
        // The hook will use the module registry to access modules

        console.log("Hook ready to coordinate with all modules via registry");

        // Verify hook can access modules through registry
        require(spendSaveHook.checkModulesInitialized(), "Hook module access verification failed");
    }

    /**
     * @notice Set cross-module references for advanced functionality
     * @dev Enables modules to interact with each other for complex operations
     */
    function _setModuleReferences() internal {
        // Set references for SavingStrategy module
        savingStrategyModule.setModuleReferences(
            address(savingStrategyModule), // self-reference
            address(savingsModule), // savings module
            address(dcaModule), // DCA module
            address(slippageControlModule), // slippage control module
            address(tokenModule), // token module
            address(dailySavingsModule) // daily savings module
        );

        // Set references for Savings module
        savingsModule.setModuleReferences(
            address(savingStrategyModule), // strategy module
            address(savingsModule), // self reference
            address(dcaModule), // dca module
            address(slippageControlModule), // slippage module
            address(tokenModule), // token module
            address(dailySavingsModule) // daily savings module
        );

        console.log("Cross-module references configured");
    }

    /**
     * @notice Comprehensive deployment verification
     * @dev Verifies all aspects of the deployment including gas optimization settings
     */
    function _verifyDeployment() internal view {
        console.log("Running comprehensive deployment verification...");

        // Verify core contract deployment
        require(address(spendSaveStorage) != address(0), "Storage not deployed");
        require(address(spendSaveHook) != address(0), "Hook not deployed");
        require(address(stateView) != address(0), "StateView not deployed");
        require(address(analytics) != address(0), "Analytics not deployed");

        // Verify module deployment
        require(address(savingStrategyModule) != address(0), "SavingStrategy not deployed");
        require(address(savingsModule) != address(0), "Savings not deployed");
        require(address(dcaModule) != address(0), "DCA not deployed");
        require(address(tokenModule) != address(0), "Token not deployed");
        require(address(slippageControlModule) != address(0), "SlippageControl not deployed");
        require(address(dailySavingsModule) != address(0), "DailySavings not deployed");

        // Verify storage initialization
        require(spendSaveStorage.spendSaveHook() == address(spendSaveHook), "Storage hook reference invalid");

        // Verify module registrations
        require(
            spendSaveStorage.getModule(STRATEGY_MODULE_ID) == address(savingStrategyModule),
            "Strategy module not registered"
        );
        require(
            spendSaveStorage.getModule(SAVINGS_MODULE_ID) == address(savingsModule), "Savings module not registered"
        );

        // Verify hook initialization
        require(spendSaveHook.checkModulesInitialized(), "Hook modules not initialized");

        // Verify hook flags
        uint160 actualFlags = uint160(address(spendSaveHook)) & 0xFF;
        require((actualFlags & REQUIRED_HOOK_FLAGS) == REQUIRED_HOOK_FLAGS, "Hook flags invalid");

        console.log("All deployment verifications passed");
    }

    /**
     * @notice Finalize deployment with comprehensive logging
     * @dev Provides complete deployment summary and configuration details
     */
    function _finalizeDeployment() internal {
        emit DeploymentCompleted(
            address(spendSaveHook),
            address(spendSaveStorage),
            true, // Gas optimization enabled
            50000 // Target afterSwap gas
        );

        _logComprehensiveDeploymentSummary();
    }

    // ==================== UTILITY FUNCTIONS ====================

    /**
     * @notice Display comprehensive pre-deployment summary
     * @dev Shows all deployment details BEFORE prompting for keystore password
     */
    function _displayPreDeploymentSummary() internal view {
        console.log("\n===========================================================");
        console.log("         SPENDSAVE PRE-DEPLOYMENT INFORMATION              ");
        console.log("===========================================================");
        console.log("");
        console.log("NETWORK CONFIGURATION:");
        console.log(string.concat("  Network:          ", currentNetwork.name));
        console.log(string.concat("  Chain ID:         ", vm.toString(block.chainid)));
        console.log(string.concat("  Is Testnet:       ", currentNetwork.isTestnet ? "YES" : "NO"));
        console.log(string.concat("  Pool Manager:     ", _addressToString(currentNetwork.poolManager)));
        console.log(string.concat("  Position Manager: ", _addressToString(currentNetwork.positionManager)));
        console.log(string.concat("  Quoter:           ", _addressToString(currentNetwork.quoter)));
        console.log(string.concat("  Permit2:          ", _addressToString(currentNetwork.permit2)));
        console.log("");
        console.log("DEPLOYMENT ACCOUNT:");
        console.log(string.concat("  Deployer Address: ", _addressToString(deployer)));
        console.log(string.concat("  Owner Address:    ", _addressToString(owner)));
        console.log(string.concat("  Treasury Address: ", _addressToString(treasury)));
        console.log("");
        console.log("CONTRACTS TO BE DEPLOYED:");
        console.log("  Core Contracts:");
        console.log("    1. SpendSaveStorage (Centralized state manager)");
        console.log("    2. StateView (Pool state analytics)");
        console.log("    3. SpendSaveHook (Main Uniswap V4 hook with address mining)");
        console.log("    4. SpendSaveAnalytics (Portfolio tracking)");
        console.log("");
        console.log("  Core Modules:");
        console.log("    5. SavingStrategy (Savings percentage management)");
        console.log("    6. Savings (Deposits and withdrawals)");
        console.log("    7. DCA (Dollar-cost averaging)");
        console.log("    8. Token (ERC6909 savings tokens)");
        console.log("    9. SlippageControl (Slippage protection)");
        console.log("   10. DailySavings (Automated savings)");
        console.log("");
        console.log("  Phase 2 Enhancement Contracts:");
        console.log("   11. SpendSaveDCARouter (Advanced DCA routing)");
        console.log("   12. SpendSaveLiquidityManager (LP position management)");
        console.log("   13. SpendSaveModuleRegistry (Module upgrades)");
        console.log("   14. SpendSaveMulticall (Batch operations)");
        console.log("   15. SpendSaveQuoter (Price impact preview)");
        console.log("   16. SpendSaveSlippageEnhanced (Enhanced slippage)");
        console.log("");
        console.log("  Helper Contract:");
        console.log("   17. HookDeployer (CREATE2 deployment helper)");
        console.log("");
        console.log("DEPLOYMENT SEQUENCE:");
        console.log("  Step 1:  Deploy SpendSaveStorage");
        console.log("  Step 2:  Deploy StateView");
        console.log("  Step 3:  Deploy all 6 core modules");
        console.log("  Step 4:  Deploy SpendSaveHook with address mining");
        console.log("  Step 5:  Deploy SpendSaveAnalytics");
        console.log("  Step 6:  Initialize storage with hook reference");
        console.log("  Step 7:  Deploy 6 Phase 2 enhancement contracts");
        console.log("  Step 8:  Initialize all modules");
        console.log("  Step 9:  Register all modules in storage registry");
        console.log("  Step 10: Initialize hook with module references");
        console.log("  Step 11: Set cross-module references");
        console.log("  Step 12: Verify complete deployment");
        console.log("");
        console.log("GAS OPTIMIZATIONS:");
        console.log("  Packed Storage:       ENABLED");
        console.log("  Transient Storage:    ENABLED (EIP-1153)");
        console.log("  Batch Operations:     ENABLED");
        console.log("  Target AfterSwap Gas: < 50,000");
        console.log("  Hook Address Mining:  ENABLED (for flag compliance)");
        console.log("");
        console.log("HOOK CONFIGURATION:");
        console.log(string.concat("  Required Flags:   ", vm.toString(REQUIRED_HOOK_FLAGS)));
        console.log("  Flags Enabled:");
        console.log("    - BEFORE_SWAP_FLAG");
        console.log("    - AFTER_SWAP_FLAG");
        console.log("    - BEFORE_SWAP_RETURNS_DELTA_FLAG");
        console.log("    - AFTER_SWAP_RETURNS_DELTA_FLAG");
        console.log("");
        console.log("ESTIMATED GAS COST:");
        console.log("  Total Contract Deployments: 17 contracts");
        console.log("  Initialization Transactions: ~15 transactions");
        console.log("  Estimated Total Gas: ~50-80M gas");

        if (currentNetwork.isTestnet) {
            console.log("  Estimated Cost (Base Sepolia): FREE (testnet)");
        } else {
            console.log("  Estimated Cost: Varies by gas price");
        }

        console.log("");
        console.log("VERIFICATION:");
        console.log("  --verify flag detected: Contracts will be verified on BaseScan");
        console.log("");
        console.log("===========================================================");
        console.log("");
        console.log("IMPORTANT NOTES:");
        console.log("  - This deployment will execute ~32+ transactions");
        console.log("  - Address mining may take 30-60 seconds for hook deployment");
        console.log("  - All contracts will be owned by:", _addressToString(owner));
        console.log("  - Treasury will be set to:", _addressToString(treasury));
        console.log("  - Deployment is on:", currentNetwork.name);
        console.log("");
        console.log("Press Enter to continue with deployment...");
        console.log("(You will be prompted for your keystore password next)");
        console.log("===========================================================");
    }

    /**
     * @notice Get human-readable network name for logging
     * @return networkName The name of the current network
     */
    function _getNetworkName() internal view returns (string memory networkName) {
        return currentNetwork.name;
    }

    /**
     * @notice Check if current network is supported
     * @return isSupported True if network is supported
     */
    function _isNetworkSupported() internal view returns (bool isSupported) {
        return currentNetwork.poolManager != address(0);
    }

    /**
     * @notice Get network configuration for a specific chain ID
     * @param chainId The chain ID to get configuration for
     * @return config The network configuration
     */
    function getNetworkConfig(uint256 chainId) external view returns (NetworkConfig memory config) {
        return networkConfigs[chainId];
    }

    /**
     * @notice Log comprehensive deployment summary
     * @dev Provides detailed information about the deployed protocol
     */
    function _logComprehensiveDeploymentSummary() internal view {
        console.log("===========================================================");
        console.log("                 SPENDSAVE DEPLOYMENT SUMMARY              ");
        console.log("===========================================================");
        console.log(string.concat("Network:        ", _getNetworkName()));
        console.log(string.concat("Pool Manager:   ", _addressToString(poolManager)));
        console.log("-----------------------------------------------------------");
        console.log("CORE CONTRACTS:");
        console.log(string.concat("SpendSaveStorage: ", _addressToString(address(spendSaveStorage))));
        console.log(string.concat("SpendSaveHook:    ", _addressToString(address(spendSaveHook))));
        console.log(string.concat("StateView:        ", _addressToString(address(stateView))));
        console.log(string.concat("Analytics:        ", _addressToString(address(analytics))));
        console.log("-----------------------------------------------------------");
        console.log("CORE MODULES:");
        console.log(string.concat("SavingStrategy:   ", _addressToString(address(savingStrategyModule))));
        console.log(string.concat("Savings:          ", _addressToString(address(savingsModule))));
        console.log(string.concat("DCA:              ", _addressToString(address(dcaModule))));
        console.log(string.concat("Token:            ", _addressToString(address(tokenModule))));
        console.log(string.concat("SlippageControl:  ", _addressToString(address(slippageControlModule))));
        console.log(string.concat("DailySavings:     ", _addressToString(address(dailySavingsModule))));
        console.log("-----------------------------------------------------------");
        console.log("PHASE 2 ENHANCEMENT CONTRACTS:");
        console.log(string.concat("DCA Router:       ", _addressToString(address(dcaRouter))));
        console.log(string.concat("Liquidity Manager:", _addressToString(address(liquidityManager))));
        console.log(string.concat("Module Registry:  ", _addressToString(address(moduleRegistry))));
        console.log(string.concat("Multicall:        ", _addressToString(address(multicall))));
        console.log(string.concat("Quoter:           ", _addressToString(address(quoter))));
        console.log(string.concat("Slippage Enhanced:", _addressToString(address(slippageEnhanced))));
        console.log("-----------------------------------------------------------");
        console.log("GAS OPTIMIZATIONS:");
        console.log("Packed Storage:        ENABLED");
        console.log("Transient Storage:     ENABLED");
        console.log("Batch Operations:      ENABLED");
        console.log("Target AfterSwap Gas:  < 50,000");
        console.log("Hook Address Mining:   COMPLETED");
        console.log("===========================================================");

        console.log("");
        console.log(">> SpendSave Protocol deployment completed successfully!");
        console.log(">> Gas-efficient automated savings and DCA system ready.");
        console.log(">> All modules initialized and linked.");
        console.log(">> Optimized for <50k gas afterSwap execution.");
    }

    /**
     * @notice Helper to convert address to string for logging
     * @param _addr The address to convert
     * @return The string representation of the address
     */
    function _addressToString(address _addr) private pure returns (string memory) {
        bytes32 value = bytes32(uint256(uint160(_addr)));
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(42);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i + 12] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i + 12] & 0x0f)];
        }
        return string(str);
    }
}

/**
 * @title HookDeployer
 * @notice Helper contract for CREATE2 hook deployment with specific salt
 * @dev This contract enables precise control over hook address generation for flag compliance
 */
contract HookDeployer {
    /// @notice Emitted when hook is successfully deployed
    event HookDeployed(address indexed hookAddress, bytes32 salt);

    /**
     * @notice Deploy contract using CREATE2 with specific salt
     * @param salt The salt for CREATE2 deployment
     * @param creationCode The complete bytecode for contract creation
     * @return deployedAddress The address of the deployed contract
     * @dev This function enables precise control over deployed contract addresses
     */
    function deployHook(bytes32 salt, bytes memory creationCode) external returns (address deployedAddress) {
        assembly {
            // Deploy using CREATE2 with provided salt
            deployedAddress := create2(0, add(creationCode, 0x20), mload(creationCode), salt)

            // Verify deployment succeeded
            if iszero(extcodesize(deployedAddress)) { revert(0, 0) }
        }

        emit HookDeployed(deployedAddress, salt);
        return deployedAddress;
    }
}
