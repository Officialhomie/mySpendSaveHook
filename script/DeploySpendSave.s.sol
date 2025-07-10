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

// Import all gas-efficient modules
import {SavingStrategy} from "../src/SavingStrategy.sol";
import {Savings} from "../src/Savings.sol";
import {DCA} from "../src/DCA.sol";
import {Token} from "../src/Token.sol";
import {SlippageControl} from "../src/SlippageControl.sol";
import {DailySavings} from "../src/DailySavings.sol";

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
    
    /// @notice Base Mainnet PoolManager address
    address constant POOL_MANAGER_BASE = 0x498581fF718922c3f8e6A244956aF099B2652b2b;
    
    /// @notice Base Sepolia Testnet PoolManager address 
    address constant POOL_MANAGER_BASE_SEPOLIA = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    
    /// @notice Supported chain IDs for deployment
    uint256 constant CHAIN_ID_BASE = 8453;
    uint256 constant CHAIN_ID_BASE_SEPOLIA = 84532;

    // ==================== MODULE REGISTRY CONSTANTS ====================
    
    /// @notice Module identifiers for storage registry
    bytes32 constant STRATEGY_MODULE_ID = keccak256("STRATEGY");
    bytes32 constant SAVINGS_MODULE_ID = keccak256("SAVINGS");
    bytes32 constant DCA_MODULE_ID = keccak256("DCA");
    bytes32 constant TOKEN_MODULE_ID = keccak256("TOKEN");
    bytes32 constant SLIPPAGE_MODULE_ID = keccak256("SLIPPAGE");
    bytes32 constant DAILY_MODULE_ID = keccak256("DAILY");

    // ==================== HOOK CONFIGURATION ====================
    
    /// @notice Required hook flags for SpendSave functionality
    /// @dev These flags enable beforeSwap, afterSwap, and delta return capabilities
    uint160 constant REQUIRED_HOOK_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | 
        Hooks.AFTER_SWAP_FLAG | 
        Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | 
        Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );

    // ==================== STATE VARIABLES ====================
    
    /// @notice Core protocol contracts
    SpendSaveHook public spendSaveHook;
    SpendSaveStorage public spendSaveStorage;
    
    /// @notice All protocol modules
    SavingStrategy public savingStrategyModule;
    Savings public savingsModule;
    DCA public dcaModule;
    Token public tokenModule;
    SlippageControl public slippageControlModule;
    DailySavings public dailySavingsModule;
    
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
    
    /// @notice Emitted when deployment completes successfully
    event DeploymentCompleted(
        address hookAddress,
        address storageAddress,
        bool gasOptimizationEnabled,
        uint256 targetAfterSwapGas
    );

    // ==================== MAIN DEPLOYMENT FUNCTION ====================
    
    /**
     * @notice Main deployment function that orchestrates the entire protocol deployment
     * @dev This function manages the complete deployment lifecycle with comprehensive
     *      validation and logging. It ensures that all contracts are deployed in the
     *      correct order and properly initialized with gas optimizations enabled.
     */
    function run() external {
        // Initialize deployment configuration
        _initializeDeploymentConfig();
        
        // Log deployment start
        console.log("=== SpendSave Protocol Deployment Starting ===");
        emit DeploymentStarted(deployer, block.chainid, poolManager);
        
        // Start broadcasting transactions
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
     */
    function _initializeDeploymentConfig() internal {
        // Determine network and pool manager
        poolManager = _getPoolManagerForNetwork();
        
        // Get deployer from private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);
        
        // Set owner (can be different from deployer)
        owner = vm.envOr("OWNER_ADDRESS", deployer);
        
        // Set treasury address
        treasury = vm.envOr("TREASURY_ADDRESS", owner);
        
        // Log configuration
        console.log("Network:", _getNetworkName());
        console.log("Pool Manager:", poolManager);
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
        
        // Step 2: Deploy all modules
        console.log("\n--- Step 2: Deploying All Modules ---");
        _deployAllModules();
        
        // Step 3: Deploy hook with proper address mining
        console.log("\n--- Step 3: Deploying SpendSaveHook ---");
        _deployHookWithAddressMining();
        
        // Step 4: Initialize storage with hook reference
        console.log("\n--- Step 4: Initializing Storage ---");
        _initializeStorage();
        
        // Step 5: Initialize all modules
        console.log("\n--- Step 5: Initializing Modules ---");
        _initializeAllModules();
        
        // Step 6: Register modules in storage registry
        console.log("\n--- Step 6: Registering Modules ---");
        _registerAllModules();
        
        // Step 7: Initialize hook with module references
        console.log("\n--- Step 7: Initializing Hook ---");
        _initializeHook();
        
        // Step 8: Set cross-module references
        console.log("\n--- Step 8: Setting Cross-Module References ---");
        _setModuleReferences();
        
        // Step 9: Verify deployment
        console.log("\n--- Step 9: Verifying Deployment ---");
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
     * @notice Deploy SpendSaveHook with proper address mining for hook flags
     * @dev Uses HookMiner to ensure the hook address has the required flags in its address
     */
    function _deployHookWithAddressMining() internal {
        console.log("Mining hook address with required flags...");
        
        // Deploy hook deployer helper contract
        hookDeployer = new HookDeployer();
        console.log("HookDeployer deployed at:", address(hookDeployer));
        
        // Prepare constructor arguments for the hook
        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManager),
            spendSaveStorage
        );
        
        // Mine for a valid hook address
        (address predictedHookAddress, bytes32 salt) = HookMiner.find(
            address(hookDeployer), // Deployer contract address
            REQUIRED_HOOK_FLAGS,    // Required flags
            type(SpendSaveHook).creationCode,
            constructorArgs
        );
        
        console.log("Found valid hook address:", predictedHookAddress);
        console.log("Salt for deployment:", vm.toString(salt));
        
        // Create complete bytecode for deployment
        bytes memory creationCode = abi.encodePacked(
            type(SpendSaveHook).creationCode,
            constructorArgs
        );
        
        // Deploy using CREATE2 with the mined salt
        address deployedHookAddress = hookDeployer.deployHook(salt, creationCode);
        
        // Verify deployment success
        require(
            deployedHookAddress == predictedHookAddress,
            "Hook deployment address mismatch"
        );
        
        // Store hook reference
        spendSaveHook = SpendSaveHook(deployedHookAddress);
        
        // Verify hook flags are correct
        uint160 actualFlags = uint160(address(spendSaveHook)) & 0xFF;
        require(
            (actualFlags & REQUIRED_HOOK_FLAGS) == REQUIRED_HOOK_FLAGS,
            "Hook flags verification failed"
        );
        
        console.log("SpendSaveHook deployed at:", address(spendSaveHook));
        console.log("Hook flags verified:", vm.toString(actualFlags));
        
        emit HookDeployed(address(spendSaveHook), salt, actualFlags);
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
            spendSaveStorage.spendSaveHook() == address(spendSaveHook),
            "Storage hook reference verification failed"
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
        // Register each module with its identifier
        spendSaveStorage.registerModule(STRATEGY_MODULE_ID, address(savingStrategyModule));
        spendSaveStorage.registerModule(SAVINGS_MODULE_ID, address(savingsModule));
        spendSaveStorage.registerModule(DCA_MODULE_ID, address(dcaModule));
        spendSaveStorage.registerModule(TOKEN_MODULE_ID, address(tokenModule));
        spendSaveStorage.registerModule(SLIPPAGE_MODULE_ID, address(slippageControlModule));
        spendSaveStorage.registerModule(DAILY_MODULE_ID, address(dailySavingsModule));
        
        console.log("All modules registered in storage registry");
        
        // Verify registrations
        require(
            spendSaveStorage.getModule(STRATEGY_MODULE_ID) == address(savingStrategyModule),
            "Strategy module registration failed"
        );
        require(
            spendSaveStorage.getModule(SAVINGS_MODULE_ID) == address(savingsModule),
            "Savings module registration failed"
        );
        require(
            spendSaveStorage.getModule(DCA_MODULE_ID) == address(dcaModule),
            "DCA module registration failed"
        );
    }
    
    /**
     * @notice Initialize hook with references to all modules
     * @dev This enables the hook to coordinate with all modules during swap execution
     */
    function _initializeHook() internal {
        spendSaveHook.initializeModules(
            address(savingStrategyModule),
            address(savingsModule),
            address(dcaModule),
            address(slippageControlModule),
            address(tokenModule),
            address(dailySavingsModule)
        );
        
        console.log("Hook initialized with all module references");
        
        // Verify hook module initialization
        require(
            spendSaveHook.checkModulesInitialized(),
            "Hook module initialization verification failed"
        );
    }
    
    /**
     * @notice Set cross-module references for advanced functionality
     * @dev Enables modules to interact with each other for complex operations
     */
    function _setModuleReferences() internal {
        // Set references for SavingStrategy module
        savingStrategyModule.setModuleReferences(address(savingsModule));
        
        // Set references for Savings module
        savingsModule.setModuleReferences(
            address(savingStrategyModule), // strategy module
            address(savingsModule),        // self reference
            address(dcaModule),            // dca module
            address(slippageControlModule), // slippage module
            address(tokenModule),          // token module
            address(dailySavingsModule)    // daily savings module
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
        
        // Verify module deployment
        require(address(savingStrategyModule) != address(0), "SavingStrategy not deployed");
        require(address(savingsModule) != address(0), "Savings not deployed");
        require(address(dcaModule) != address(0), "DCA not deployed");
        require(address(tokenModule) != address(0), "Token not deployed");
        require(address(slippageControlModule) != address(0), "SlippageControl not deployed");
        require(address(dailySavingsModule) != address(0), "DailySavings not deployed");
        
        // Verify storage initialization
        require(
            spendSaveStorage.spendSaveHook() == address(spendSaveHook),
            "Storage hook reference invalid"
        );
        
        // Verify module registrations
        require(
            spendSaveStorage.getModule(STRATEGY_MODULE_ID) == address(savingStrategyModule),
            "Strategy module not registered"
        );
        require(
            spendSaveStorage.getModule(SAVINGS_MODULE_ID) == address(savingsModule),
            "Savings module not registered"
        );
        
        // Verify hook initialization
        require(
            spendSaveHook.checkModulesInitialized(),
            "Hook modules not initialized"
        );
        
        // Verify hook flags
        uint160 actualFlags = uint160(address(spendSaveHook)) & 0xFF;
        require(
            (actualFlags & REQUIRED_HOOK_FLAGS) == REQUIRED_HOOK_FLAGS,
            "Hook flags invalid"
        );
        
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
     * @notice Get pool manager address for current network
     * @return poolManagerAddress The pool manager for the current network
     * @dev Supports Base Mainnet and Base Sepolia, easily extensible
     */
    function _getPoolManagerForNetwork() internal view returns (address poolManagerAddress) {
        uint256 chainId = block.chainid;
        
        if (chainId == CHAIN_ID_BASE) {
            return POOL_MANAGER_BASE;
        } else if (chainId == CHAIN_ID_BASE_SEPOLIA) {
            return POOL_MANAGER_BASE_SEPOLIA;
        } else {
            revert(string.concat("Unsupported network. Chain ID: ", vm.toString(chainId)));
        }
    }
    
    /**
     * @notice Get human-readable network name for logging
     * @return networkName The name of the current network
     */
    function _getNetworkName() internal view returns (string memory networkName) {
        uint256 chainId = block.chainid;
        
        if (chainId == CHAIN_ID_BASE) {
            return "Base Mainnet";
        } else if (chainId == CHAIN_ID_BASE_SEPOLIA) {
            return "Base Sepolia";
        } else {
            return string.concat("Unknown Network (", vm.toString(chainId), ")");
        }
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
        console.log("-----------------------------------------------------------");
        console.log("MODULES:");
        console.log(string.concat("SavingStrategy:   ", _addressToString(address(savingStrategyModule))));
        console.log(string.concat("Savings:          ", _addressToString(address(savingsModule))));
        console.log(string.concat("DCA:              ", _addressToString(address(dcaModule))));
        console.log(string.concat("Token:            ", _addressToString(address(tokenModule))));
        console.log(string.concat("SlippageControl:  ", _addressToString(address(slippageControlModule))));
        console.log(string.concat("DailySavings:     ", _addressToString(address(dailySavingsModule))));
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
        str[0] = '0';
        str[1] = 'x';
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
            if iszero(extcodesize(deployedAddress)) {
                revert(0, 0)
            }
        }
        
        emit HookDeployed(deployedAddress, salt);
        return deployedAddress;
    }
}