// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SpendSaveStorage} from "./SpendSaveStorage.sol";

/**
 * @title SpendSaveModuleRegistry
 * @notice Upgradeable module management system
 */
contract SpendSaveModuleRegistry {
    
    SpendSaveStorage public immutable storage_;
    
    // Module versioning
    mapping(string => address) public modules;
    mapping(string => uint256) public moduleVersions;
    mapping(address => bool) public authorizedUpgraders;

    event ModuleUpgraded(string indexed moduleName, address oldModule, address newModule, uint256 version);
    event UpgraderAuthorized(address indexed upgrader, bool authorized);

    constructor(address _storage) {
        storage_ = SpendSaveStorage(_storage);
        authorizedUpgraders[msg.sender] = true;
    }

    modifier onlyAuthorized() {
        require(
            authorizedUpgraders[msg.sender] || 
            msg.sender == storage_.owner(),
            "Unauthorized"
        );
        _;
    }

    /**
     * @notice Upgrade a module to new implementation
     */
    function upgradeModule(
        string calldata moduleName,
        address newImplementation
    ) external onlyAuthorized {
        require(newImplementation != address(0), "Invalid implementation");
        
        address oldImplementation = modules[moduleName];
        modules[moduleName] = newImplementation;
        moduleVersions[moduleName]++;
        
        emit ModuleUpgraded(moduleName, oldImplementation, newImplementation, moduleVersions[moduleName]);
    }

    /**
     * @notice Get current module implementation
     */
    function getModule(string calldata moduleName) external view returns (address implementation, uint256 version) {
        implementation = modules[moduleName];
        version = moduleVersions[moduleName];
    }

    /**
     * @notice Set upgrader authorization
     */
    function setUpgraderAuthorization(address upgrader, bool authorized) external {
        require(msg.sender == storage_.owner(), "Only owner");
        authorizedUpgraders[upgrader] = authorized;
        emit UpgraderAuthorized(upgrader, authorized);
    }
}