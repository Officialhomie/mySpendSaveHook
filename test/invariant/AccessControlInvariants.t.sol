// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseInvariantTest} from "./BaseInvariantTest.sol";

/**
 * @title AccessControlInvariants
 * @notice HIGH: Ensures only authorized addresses can modify state
 * @dev Tests privilege boundaries and prevents escalation attacks
 */
contract AccessControlInvariants is BaseInvariantTest {
    bytes32 private constant STRATEGY_ID = keccak256("STRATEGY");
    bytes32 private constant SAVINGS_ID = keccak256("SAVINGS");
    bytes32 private constant DCA_ID = keccak256("DCA");
    bytes32 private constant SLIPPAGE_ID = keccak256("SLIPPAGE");
    bytes32 private constant TOKEN_ID = keccak256("TOKEN");
    bytes32 private constant DAILY_ID = keccak256("DAILY");

    /**
     * @notice INVARIANT 18: Only owner can modify critical parameters
     * @dev Treasury, fees, and module registry should only be modified by owner
     * Priority: CRITICAL
     * Risk: Protocol takeover
     */
    function invariant_owner_exclusive_critical_parameters() external view {
        address currentOwner = storage_.owner();
        address currentTreasury = storage_.treasury();
        uint256 currentFee = storage_.treasuryFee();

        // Owner should never be zero (checked by other invariant)
        assertTrue(currentOwner != address(0), "Owner is zero");

        // Treasury should never be unauthorized address
        // (In handler, only owner can call setTreasury)
        assertTrue(currentTreasury != address(0), "Treasury is zero");

        // Fee should be within valid range (0-10000)
        assertLe(currentFee, 10000, "Treasury fee exceeds 100%");

        // Verify module registry only modified by owner
        // Check module IDs haven't been tampered with
        assertEq(
            storage_.moduleRegistry(STRATEGY_ID),
            address(savingStrategy),
            "Strategy module tampered"
        );
    }

    /**
     * @notice INVARIANT 19: Only authorized modules can modify storage
     * @dev State changes must come from hook or authorized modules
     * Priority: CRITICAL
     * Risk: Unauthorized state modification
     */
    function invariant_only_authorized_modules_modify_storage() external view {
        // Check that all modules that modified state are authorized
        uint256 moduleCount = registry.totalModules();

        for (uint256 i = 0; i < moduleCount; i++) {
            address module = registry.moduleAt(i);

            // If module has modified state (tracked by handler)
            if (registry.moduleModificationCount(module) > 0) {
                // Must be authorized
                assertTrue(
                    storage_.authorizedModules(module),
                    string.concat(
                        "Unauthorized module modified state: ",
                        vm.toString(module)
                    )
                );
            }
        }
    }

    /**
     * @notice INVARIANT 20: Users can only modify their own strategies
     * @dev User A cannot modify User B's savings strategy
     * Priority: HIGH
     * Risk: Strategy manipulation
     */
    function invariant_user_strategy_isolation() external view {
        uint256 userCount = registry.usersLength();

        for (uint256 i = 0; i < userCount; i++) {
            address user = registry.userAt(i);

            // Get user's strategy
            (
                uint256 percentage,
                , // roundUpSavings
                , // savingsTokenType
                // enableDCA
            ) = storage_.getPackedUserConfig(user);

            // If strategy is set (percentage > 0), check it was set by user or system
            if (percentage > 0) {
                // Handler should track who set each strategy
                address strategySetter = registry.strategySetter(user);

                assertTrue(
                    strategySetter == user ||
                    strategySetter == address(hook) ||
                    strategySetter == address(savingStrategy),
                    "Strategy modified by unauthorized party"
                );
            }
        }
    }

    /**
     * @notice INVARIANT 21: Only users can withdraw their own savings
     * @dev Withdrawal authorization must be enforced
     * Priority: CRITICAL
     * Risk: Fund theft
     */
    function invariant_withdrawal_authorization() external view {
        uint256 withdrawalCount = registry.totalWithdrawals();

        for (uint256 i = 0; i < withdrawalCount; i++) {
            (
                address user,
                address caller,
                address token,
                uint256 amount
            ) = registry.getWithdrawal(i);

            // Caller must be user, hook, or authorized operator
            assertTrue(
                caller == user ||
                caller == address(hook) ||
                caller == address(savings) ||
                tokenModule.isOperator(user, caller),
                string.concat(
                    "Unauthorized withdrawal by ",
                    vm.toString(caller),
                    " for user ",
                    vm.toString(user)
                )
            );
        }
    }

    /**
     * @notice INVARIANT 22: Hook-only functions not callable by others
     * @dev Certain storage functions should only be called by hook
     * Priority: HIGH
     * Risk: State corruption
     */
    function invariant_hook_exclusive_functions() external view {
        // Check transient storage is only modified by hook
        uint256 contextModificationCount = registry.transientContextModifications();

        for (uint256 i = 0; i < contextModificationCount; i++) {
            address modifier_ = registry.transientContextModifier(i);

            assertEq(
                modifier_,
                address(hook),
                "Non-hook address modified transient context"
            );
        }
    }

    /**
     * @notice INVARIANT 23: Module references only set during initialization
     * @dev After setup, module references should be immutable
     * Priority: MEDIUM
     * Risk: Module substitution attack
     */
    function invariant_module_references_immutable_after_init() external view {
        // Check that module registry hasn't been modified after initialization
        bool isInitialized = storage_.spendSaveHook() != address(0);

        if (isInitialized) {
            // All core modules should be registered and not changed
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

                // Check it hasn't been changed (tracked by handler)
                uint256 changeCount = registry.moduleRegistryChanges(moduleIds[i]);
                assertLe(
                    changeCount,
                    1,
                    "Module registry modified after initialization"
                );
            }
        }
    }
}

