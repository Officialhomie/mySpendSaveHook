// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "lib/v4-periphery/lib/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "lib/v4-periphery/test/libraries/HookMiner.t.sol";

import "../src/SpendSaveStorage.sol";
import "../src/SpendSaveHook.sol";
import "../src/SavingStrategy.sol";
import "../src/Savings.sol";
import "../src/Token.sol";
import "../src/DCA.sol";
import "../src/SlippageControl.sol";
import "../src/DailySavings.sol";

/**
 * @title DeploySpendSave
 * @dev Deployment script for SpendSave modular system
 */
contract DeploySpendSave is Script {
    // Adjust these addresses for the target network
    address constant POOL_MANAGER = address(0x0); // Set to actual PoolManager address

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the storage contract first
        SpendSaveStorage storage_ = new SpendSaveStorage(
            deployer, // Owner
            deployer, // Treasury (initially set to deployer)
            IPoolManager(POOL_MANAGER)
        );
        console.log("Storage deployed at:", address(storage_));
        
        // Deploy modules first
        SavingStrategy strategyModule = new SavingStrategy();
        console.log("SavingStrategy deployed at:", address(strategyModule));
        
        Savings savingsModule = new Savings();
        console.log("Savings deployed at:", address(savingsModule));
        
        DCA dcaModule = new DCA();
        console.log("DCA deployed at:", address(dcaModule));
        
        SlippageControl slippageModule = new SlippageControl();
        console.log("SlippageControl deployed at:", address(slippageModule));
        
        Token tokenModule = new Token();
        console.log("Token deployed at:", address(tokenModule));
        
        DailySavings dailySavingsModule = new DailySavings();
        console.log("DailySavings deployed at:", address(dailySavingsModule));
        
        // Register modules with storage
        storage_.setSavingStrategyModule(address(strategyModule));
        storage_.setSavingsModule(address(savingsModule));
        storage_.setDCAModule(address(dcaModule));
        storage_.setSlippageControlModule(address(slippageModule));
        storage_.setTokenModule(address(tokenModule));
        storage_.setDailySavingsModule(address(dailySavingsModule));
        console.log("All modules registered with storage");

        // Calculate the hook address with appropriate flags
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        
        // Use HookMiner to find a salt that will produce a hook address with the needed flags
        (address hookAddress, bytes32 salt) = HookMiner.find(
            deployer,
            flags, 
            type(SpendSaveHook).creationCode,
            abi.encode(IPoolManager(POOL_MANAGER), storage_)
        );
        
        console.log("Computed hook address:", hookAddress);
        console.log("Using salt:", vm.toString(salt));
        
        // Deploy the hook to the computed address using CREATE2
        SpendSaveHook hook = new SpendSaveHook{salt: salt}(
            IPoolManager(POOL_MANAGER),
            storage_
        );
        
        console.log("Hook deployed at:", address(hook));
        console.log("Hook flags (should include 0xC0 for before/after swap):", uint160(address(hook)) & 0xFF);
        
        // Register the hook with storage
        storage_.setSpendSaveHook(address(hook));
        console.log("Hook registered with storage");
        
        // Initialize modules with storage reference
        strategyModule.initialize(storage_);
        savingsModule.initialize(storage_);
        tokenModule.initialize(storage_);
        dcaModule.initialize(storage_);
        slippageModule.initialize(storage_);
        dailySavingsModule.initialize(storage_);
        console.log("All modules initialized with storage reference");

        // Set module references for cross-module calls
        strategyModule.setModuleReferences(address(savingsModule));
        savingsModule.setModuleReferences(address(tokenModule), address(strategyModule));
        dcaModule.setModuleReferences(address(tokenModule), address(slippageModule));
        
        // Create and add a mock yield module for DailySavings
        // In a real deployment, you would deploy a proper yield module
        address mockYieldModule = deployer; // Using deployer as mock, replace with actual module
        dailySavingsModule.setModuleReferences(address(tokenModule), mockYieldModule);
        
        console.log("Module references set");

        // Initialize the hook with all modules
        hook.initializeModules(
            address(strategyModule),
            address(savingsModule),
            address(dcaModule),
            address(slippageModule),
            address(tokenModule),
            address(dailySavingsModule)
        );
        console.log("Hook initialized with all modules");
        
        console.log("\nSpendSave system deployment complete!");
        console.log("Storage:", address(storage_));
        console.log("Hook:", address(hook));
        console.log("Strategy Module:", address(strategyModule));
        console.log("Savings Module:", address(savingsModule));
        console.log("Token Module:", address(tokenModule));
        console.log("DCA Module:", address(dcaModule));
        console.log("Slippage Module:", address(slippageModule));
        console.log("DailySavings Module:", address(dailySavingsModule));
        
        vm.stopBroadcast();
    }
}