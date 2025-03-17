// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";

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
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the storage contract first
        SpendSaveStorage storage_ = new SpendSaveStorage(
            msg.sender, // Owner
            msg.sender, // Treasury (initially set to deployer)
            IPoolManager(POOL_MANAGER)
        );
        
        // Deploy the main hook contract
        SpendSaveHook hook = new SpendSaveHook(
            IPoolManager(POOL_MANAGER),
            storage_
        );
        
        // Deploy all modules - use the actual contract names from your source files
        SavingStrategy strategyModule = new SavingStrategy();
        Savings savingsModule = new Savings();
        Token tokenModule = new Token();
        DCA dcaModule = new DCA();
        SlippageControl slippageModule = new SlippageControl();
        DailySavings dailySavingsModule = new DailySavings();

        // Initialize modules with storage reference
        strategyModule.initialize(storage_);
        savingsModule.initialize(storage_);
        tokenModule.initialize(storage_);
        dcaModule.initialize(storage_);
        slippageModule.initialize(storage_);
        dailySavingsModule.initialize(storage_);

        // Set module references for cross-module calls
        strategyModule.setModuleReferences(address(savingsModule));
        savingsModule.setModuleReferences(address(tokenModule), address(strategyModule));
        dcaModule.setModuleReferences(address(tokenModule), address(slippageModule));
        dailySavingsModule.setModuleReferences(address(tokenModule), address(strategyModule));

        // Initialize the hook with all modules
        hook.initializeModules(
            address(strategyModule),
            address(savingsModule),
            address(dcaModule),
            address(slippageModule),
            address(tokenModule),
            address(dailySavingsModule)
        );
        
        console.log("SpendSave system deployed:");
        console.log("Storage:", address(storage_));
        console.log("Hook:", address(hook));
        console.log("Strategy Module:", address(strategyModule));
        console.log("Savings Module:", address(savingsModule));
        console.log("Token Module:", address(tokenModule));
        console.log("DCA Module:", address(dcaModule));
        console.log("Slippage Module:", address(slippageModule));
        
        vm.stopBroadcast();
    }
}