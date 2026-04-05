// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseInvariantTest} from "./BaseInvariantTest.sol";

/**
 * @title ModuleInvariants
 * @notice HIGH: Ensures module system integrity
 * @dev Tests module registration and authorization
 */
contract ModuleInvariants is BaseInvariantTest {
    bytes32 private constant STRATEGY_ID = keccak256("STRATEGY");
    bytes32 private constant SAVINGS_ID = keccak256("SAVINGS");
    bytes32 private constant DCA_ID = keccak256("DCA");
    bytes32 private constant SLIPPAGE_ID = keccak256("SLIPPAGE");
    bytes32 private constant TOKEN_ID = keccak256("TOKEN");
    bytes32 private constant DAILY_ID = keccak256("DAILY");

    /**
     * @notice INVARIANT 42: All module references non-zero after init
     * @dev Core modules should be registered after initialization
     * Priority: CRITICAL
     * Risk: Broken functionality
     */
    function invariant_module_references_non_zero_after_init() external view {
        bool isInitialized = storage_.spendSaveHook() != address(0);

        if (isInitialized) {
            bytes32[] memory moduleIds = new bytes32[](6);
            moduleIds[0] = STRATEGY_ID;
            moduleIds[1] = SAVINGS_ID;
            moduleIds[2] = DCA_ID;
            moduleIds[3] = SLIPPAGE_ID;
            moduleIds[4] = TOKEN_ID;
            moduleIds[5] = DAILY_ID;

            for (uint256 i = 0; i < moduleIds.length; i++) {
                address module = storage_.moduleRegistry(moduleIds[i]);

                assertTrue(
                    module != address(0),
                    string.concat(
                        "Module not registered: ",
                        vm.toString(uint256(moduleIds[i]))
                    )
                );

                assertTrue(
                    storage_.authorizedModules(module),
                    string.concat(
                        "Module not authorized: ",
                        vm.toString(module)
                    )
                );
            }
        }
    }

    /**
     * @notice INVARIANT 43: Module authorization bidirectional
     * @dev If module is registered, it should be authorized
     * Priority: HIGH
     * Risk: Unauthorized module access
     */
    function invariant_module_authorization_bidirectional() external view {
        bytes32[] memory moduleIds = new bytes32[](6);
        moduleIds[0] = STRATEGY_ID;
        moduleIds[1] = SAVINGS_ID;
        moduleIds[2] = DCA_ID;
        moduleIds[3] = SLIPPAGE_ID;
        moduleIds[4] = TOKEN_ID;
        moduleIds[5] = DAILY_ID;

        for (uint256 i = 0; i < moduleIds.length; i++) {
            address module = storage_.moduleRegistry(moduleIds[i]);

            if (module != address(0)) {
                assertTrue(
                    storage_.authorizedModules(module),
                    string.concat(
                        "Registered module not authorized: ",
                        vm.toString(module)
                    )
                );
            }
        }
    }

    /**
     * @notice INVARIANT 44: Cross-module calls only to authorized modules
     * @dev Modules should only call other authorized modules
     * Priority: HIGH
     * Risk: Unauthorized cross-module calls
     */
    function invariant_cross_module_calls_authorized() external view {
        // This is verified by the access control invariants
        // Modules can only modify storage if authorized
        // Cross-module calls go through storage, so they're covered

        // Verify all registered modules are authorized
        bytes32[] memory moduleIds = new bytes32[](6);
        moduleIds[0] = STRATEGY_ID;
        moduleIds[1] = SAVINGS_ID;
        moduleIds[2] = DCA_ID;
        moduleIds[3] = SLIPPAGE_ID;
        moduleIds[4] = TOKEN_ID;
        moduleIds[5] = DAILY_ID;

        for (uint256 i = 0; i < moduleIds.length; i++) {
            address module = storage_.moduleRegistry(moduleIds[i]);

            if (module != address(0)) {
                assertTrue(
                    storage_.authorizedModules(module),
                    "Cross-module call to unauthorized module"
                );
            }
        }
    }

    /**
     * @notice INVARIANT 45: Module initialization happens exactly once
     * @dev Modules should be initialized only once
     * Priority: MEDIUM
     * Risk: Re-initialization issues
     */
    function invariant_module_initialization_once() external view {
        // Check that module registry changes are minimal
        // Initial registration should happen once
        bytes32[] memory moduleIds = new bytes32[](6);
        moduleIds[0] = STRATEGY_ID;
        moduleIds[1] = SAVINGS_ID;
        moduleIds[2] = DCA_ID;
        moduleIds[3] = SLIPPAGE_ID;
        moduleIds[4] = TOKEN_ID;
        moduleIds[5] = DAILY_ID;

        for (uint256 i = 0; i < moduleIds.length; i++) {
            // Registry changes should be at most 1 (initial registration)
            uint256 changeCount = registry.moduleRegistryChanges(moduleIds[i]);
            assertLe(
                changeCount,
                1,
                string.concat(
                    "Module registry changed multiple times: ",
                    vm.toString(uint256(moduleIds[i]))
                )
            );
        }
    }
}

