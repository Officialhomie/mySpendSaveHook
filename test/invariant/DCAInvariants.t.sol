// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseInvariantTest} from "./BaseInvariantTest.sol";

/**
 * @title DCAInvariants
 * @notice HIGH: Ensures DCA queue logic is correct
 * @dev Tests DCA queue consistency and execution validity
 */
contract DCAInvariants is BaseInvariantTest {

    /**
     * @notice INVARIANT 27: DCA queue items have valid deadlines
     * @dev Deadlines should be in the future for pending items
     * Priority: HIGH
     * Risk: Failed DCA executions
     */
    function invariant_dca_queue_valid_deadlines() external view {
        uint256 userCount = registry.usersLength();

        for (uint256 i = 0; i < userCount; i++) {
            address user = registry.userAt(i);
            uint256 queueLength = storage_.getDcaQueueLength(user);

            for (uint256 q = 0; q < queueLength; q++) {
                (
                    address fromToken,
                    address toToken,
                    uint256 amount,
                    , // targetTick
                    uint256 deadline,
                    bool executed,
                    // slippageBps
                ) = storage_.getDcaQueueItem(user, q);

                if (!executed) {
                    // Pending items should have valid deadlines
                    assertGe(
                        deadline,
                        block.timestamp,
                        string.concat(
                            "DCA queue item ",
                            vm.toString(q),
                            " has expired deadline"
                        )
                    );
                }
            }
        }
    }

    /**
     * @notice INVARIANT 28: Executed DCA items marked correctly
     * @dev Once executed, items should remain marked as executed
     * Priority: MEDIUM
     * Risk: Double execution
     */
    function invariant_dca_executed_items_marked() external view {
        uint256 userCount = registry.usersLength();

        for (uint256 i = 0; i < userCount; i++) {
            address user = registry.userAt(i);
            uint256 queueLength = storage_.getDcaQueueLength(user);

            for (uint256 q = 0; q < queueLength; q++) {
                (
                    , , , , , bool executed,
                ) = storage_.getDcaQueueItem(user, q);

                // If item has output recorded, it should be executed
                uint256 outputAmount = registry.dcaOutputAmount(user, q);
                if (outputAmount > 0) {
                    assertTrue(
                        executed,
                        string.concat(
                            "DCA item ",
                            vm.toString(q),
                            " has output but not marked executed"
                        )
                    );
                }
            }
        }
    }

    /**
     * @notice INVARIANT 29: DCA queue doesn't grow unbounded
     * @dev Queue length should be reasonable
     * Priority: MEDIUM
     * Risk: Gas issues, DoS
     */
    function invariant_dca_queue_bounded() external view {
        uint256 userCount = registry.usersLength();
        uint256 maxQueueLength = 1000; // Reasonable maximum

        for (uint256 i = 0; i < userCount; i++) {
            address user = registry.userAt(i);
            uint256 queueLength = storage_.getDcaQueueLength(user);

            assertLe(
                queueLength,
                maxQueueLength,
                string.concat(
                    "DCA queue too long for user ",
                    vm.toString(user)
                )
            );
        }
    }

    /**
     * @notice INVARIANT 30: Target ticks within valid range
     * @dev Target ticks should be reasonable values
     * Priority: MEDIUM
     * Risk: Invalid swap execution
     */
    function invariant_dca_target_ticks_valid() external view {
        uint256 userCount = registry.usersLength();
        int24 maxTick = 887272; // Typical Uniswap V4 max tick
        int24 minTick = -887272;

        for (uint256 i = 0; i < userCount; i++) {
            address user = registry.userAt(i);
            uint256 queueLength = storage_.getDcaQueueLength(user);

            for (uint256 q = 0; q < queueLength; q++) {
                (
                    , , , int24 targetTick, , ,
                ) = storage_.getDcaQueueItem(user, q);

                // Target tick should be within valid range
                assertGe(
                    targetTick,
                    minTick,
                    string.concat(
                        "DCA target tick too low: ",
                        vm.toString(targetTick)
                    )
                );

                assertLe(
                    targetTick,
                    maxTick,
                    string.concat(
                        "DCA target tick too high: ",
                        vm.toString(targetTick)
                    )
                );
            }
        }
    }
}

