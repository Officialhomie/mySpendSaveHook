// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Import Uniswap V4 dependencies
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";

// Import core protocol contracts
import {SpendSaveHook} from "../src/SpendSaveHook.sol";
import {SpendSaveStorage} from "../src/SpendSaveStorage.sol";

// Import module contracts
import {SavingStrategy} from "../src/SavingStrategy.sol";
import {Savings} from "../src/Savings.sol";
import {DCA} from "../src/DCA.sol";
import {SlippageControl} from "../src/SlippageControl.sol";
import {Token} from "../src/Token.sol";
import {DailySavings} from "../src/DailySavings.sol";

// Mock YieldModule for deployment (replace with real implementation if available)
contract YieldModule {
    SpendSaveStorage public storage_;
    
    function initialize(SpendSaveStorage _storage) external {
        storage_ = _storage;
    }
    
    function applyYieldStrategy(address user, address token) external {
        // Implementation would go here
    }
}

// Add this contract to your script
contract HookDeployer {
    event HookDeployed(address hookAddress);
    
    function deployHook(bytes32 salt, bytes memory creationCode) external returns (address) {
        address deployedAddress;
        assembly {
            deployedAddress := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
            if iszero(extcodesize(deployedAddress)) {
                revert(0, 0)
            }
        }
        emit HookDeployed(deployedAddress);
        return deployedAddress;
    }
}

contract DeploySpendSave is Script {
    // Deployment addresses
    address public owner;
    address public treasury;
    
    // Core contracts
    PoolManager public poolManager;
    SpendSaveStorage public spendSaveStorage;
    SpendSaveHook public spendSaveHook;
    
    // Module contracts
    SavingStrategy public savingStrategyModule;
    Savings public savingsModule;
    DCA public dcaModule;
    SlippageControl public slippageControlModule;
    Token public tokenModule;
    DailySavings public dailySavingsModule;
    YieldModule public yieldModule;
    
    // Hook mining configuration
    uint160 public constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_SWAP_FLAG | 
        Hooks.AFTER_SWAP_FLAG | 
        Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | 
        Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
    );
    
    function run() public {
        // Setup accounts
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        owner = vm.addr(deployerPrivateKey);
        treasury = vm.envAddress("TREASURY_ADDRESS");
        
        console.log("Deployer/Owner address:", owner);
        console.log("Treasury address:", treasury);
        
        // Start the deployment
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy Uniswap V4 PoolManager if needed
        // Uncomment the next line to deploy a new PoolManager
        // poolManager = new PoolManager(500000);
        
        // Or use an existing PoolManager address
        poolManager = PoolManager(vm.envAddress("POOL_MANAGER_ADDRESS"));
        console.log("PoolManager address:", address(poolManager));
        
        // Deploy SpendSaveStorage
        spendSaveStorage = new SpendSaveStorage(owner, treasury, IPoolManager(address(poolManager)));
        console.log("SpendSaveStorage deployed at:", address(spendSaveStorage));
        
        // Deploy all modules
        deployModules();
        
        // Deploy SpendSaveHook with HookMiner for correct address
        deployHook();
        
        // Initialize modules
        initializeModules();
        
        // Set module references
        setModuleReferences();
        
        // Register modules with storage
        // This is needed because the hook needs to access modules via storage
        initializeHook();
        
        // After deployment, we need the OWNER to call initializeModules on the hook
        console.log("\nIMPORTANT: After deployment, the owner must call this function:");
        console.log("spendSaveHook.initializeModules(");
        console.log("    ", address(savingStrategyModule), ",");
        console.log("    ", address(savingsModule), ",");
        console.log("    ", address(dcaModule), ",");
        console.log("    ", address(slippageControlModule), ",");
        console.log("    ", address(tokenModule), ",");
        console.log("    ", address(dailySavingsModule));
        console.log(")");
        
        vm.stopBroadcast();
        
        console.log("SpendSave protocol deployment complete!");
        logDeployedAddresses();
    }
    
    function deployModules() internal {
        console.log("Deploying modules...");
        
        // Deploy all module contracts
        savingStrategyModule = new SavingStrategy();
        console.log("SavingStrategy deployed at:", address(savingStrategyModule));
        
        savingsModule = new Savings();
        console.log("Savings deployed at:", address(savingsModule));
        
        dcaModule = new DCA();
        console.log("DCA deployed at:", address(dcaModule));
        
        slippageControlModule = new SlippageControl();
        console.log("SlippageControl deployed at:", address(slippageControlModule));
        
        tokenModule = new Token();
        console.log("Token deployed at:", address(tokenModule));
        
        dailySavingsModule = new DailySavings();
        console.log("DailySavings deployed at:", address(dailySavingsModule));
        
        yieldModule = new YieldModule();
        console.log("YieldModule deployed at:", address(yieldModule));
    }
    

    function deployHook() internal {
        console.log("Mining hook address with correct flags...");
        
        // Deploy the hook deployer first
        HookDeployer hookDeployer = new HookDeployer();
        console.log("Hook deployer deployed at:", address(hookDeployer));
        
        // Define the flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.AFTER_SWAP_FLAG | 
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | 
            Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        
        // Store constructor args
        bytes memory constructorArgs = abi.encode(
            IPoolManager(address(poolManager)), 
            spendSaveStorage
        );
        
        // Calculate hook address with the DEPLOYER address
        (address predictedAddress, bytes32 salt) = HookMiner.find(
            address(hookDeployer), // Use the deployer contract address
            flags,
            type(SpendSaveHook).creationCode,
            constructorArgs
        );
        
        console.log("Found valid hook address:", predictedAddress);
        console.log("Using salt:", vm.toString(salt));
        
        // Create the bytecode
        bytes memory creationCode = abi.encodePacked(
            type(SpendSaveHook).creationCode,
            constructorArgs
        );
        
        // Use the deployer to deploy with CREATE2
        address deployedAddress = hookDeployer.deployHook(salt, creationCode);
        
        console.log("SpendSaveHook deployed at:", deployedAddress);
        
        // Verify the deploy worked as expected
        require(deployedAddress == predictedAddress, 
            "Deployed address does not match predicted address");
        
        // Continue with the hook setup
        spendSaveHook = SpendSaveHook(deployedAddress);
        
        // Verify flags
        uint160 actualFlags = uint160(address(spendSaveHook)) & 0xFF;
        console.log("Actual hook flags (decimal):", uint256(actualFlags));
        require((actualFlags & flags) == flags, 
            "Hook flags do not match expected flags");
        
        // Register with storage
        spendSaveStorage.setSpendSaveHook(address(spendSaveHook));
    }
    
    function initializeModules() internal {
        console.log("Initializing modules...");
        
        // Initialize all modules with storage reference
        savingStrategyModule.initialize(spendSaveStorage);
        savingsModule.initialize(spendSaveStorage);
        dcaModule.initialize(spendSaveStorage);
        slippageControlModule.initialize(spendSaveStorage);
        tokenModule.initialize(spendSaveStorage);
        dailySavingsModule.initialize(spendSaveStorage);
        yieldModule.initialize(spendSaveStorage);
    }
    
    function setModuleReferences() internal {
        console.log("Setting module references...");
        
        // Set references between modules
        savingStrategyModule.setModuleReferences(address(savingsModule));
        
        savingsModule.setModuleReferences(
            address(tokenModule), 
            address(savingStrategyModule), 
            address(dcaModule)
        );
        
        dcaModule.setModuleReferences(
            address(tokenModule), 
            address(slippageControlModule), 
            address(savingsModule)
        );
        
        tokenModule.setModuleReferences(address(savingsModule));
        
        dailySavingsModule.setModuleReferences(
            address(tokenModule), 
            address(yieldModule)
        );
    }
    
    function initializeHook() internal {
        console.log("Initializing hook with modules...");
        
        // For the SpendSaveHook contract, we need to set modules directly through storage
        // since the hook's initializeModules method requires owner as caller
        
        // First register modules with storage
        spendSaveStorage.setSavingStrategyModule(address(savingStrategyModule));
        spendSaveStorage.setSavingsModule(address(savingsModule));
        spendSaveStorage.setDCAModule(address(dcaModule));
        spendSaveStorage.setSlippageControlModule(address(slippageControlModule));
        spendSaveStorage.setTokenModule(address(tokenModule));
        spendSaveStorage.setDailySavingsModule(address(dailySavingsModule));
        spendSaveStorage.setYieldModule(address(yieldModule));
        
        // Now the hook can load its references from storage through appropriate methods
        // or will do so automatically when functions are called
        
        console.log("All module references registered with storage");
    }
    
    function logDeployedAddresses() internal view {
        console.log("\n--- Deployed Contract Addresses ---");
        console.log("PoolManager:          ", address(poolManager));
        console.log("SpendSaveStorage:     ", address(spendSaveStorage));
        console.log("SpendSaveHook:        ", address(spendSaveHook));
        console.log("SavingStrategy:       ", address(savingStrategyModule));
        console.log("Savings:              ", address(savingsModule));
        console.log("DCA:                  ", address(dcaModule));
        console.log("SlippageControl:      ", address(slippageControlModule));
        console.log("Token:                ", address(tokenModule));
        console.log("DailySavings:         ", address(dailySavingsModule));
        console.log("YieldModule:          ", address(yieldModule));
    }
}