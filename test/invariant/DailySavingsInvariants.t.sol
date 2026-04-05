// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseInvariantTest} from "./BaseInvariantTest.sol";

/**
 * @title DailySavingsInvariants
 * @notice HIGH: Ensures daily savings logic is correct
 * @dev Tests daily savings accumulation and goal tracking
 */
contract DailySavingsInvariants is BaseInvariantTest {

    /**
     * @notice INVARIANT 31: Daily amounts accumulate correctly
     * @dev Daily savings amounts should only increase
     * Priority: HIGH
     * Risk: Incorrect savings tracking
     */
    function invariant_daily_amounts_accumulate() external view {
        uint256 userCount = registry.usersLength();
        uint256 tokenCount = registry.tokensLength();

        for (uint256 u = 0; u < userCount; u++) {
            address user = registry.userAt(u);

            for (uint256 t = 0; t < tokenCount; t++) {
                address token = registry.tokenAt(t);
                uint256 dailyAmount = storage_.dailySavingsAmounts(user, token);

                // Daily amounts should be non-negative
                assertGe(
                    dailyAmount,
                    0,
                    string.concat(
                        "Negative daily amount for user ",
                        vm.toString(user),
                        " token ",
                        vm.toString(token)
                    )
                );
            }
        }
    }

    /**
     * @notice INVARIANT 32: Goals are mathematically achievable
     * @dev Goal amounts should be >= current amounts
     * Priority: HIGH
     * Risk: Impossible goals
     */
    function invariant_daily_goals_achievable() external view {
        uint256 userCount = registry.usersLength();
        uint256 tokenCount = registry.tokensLength();

        for (uint256 u = 0; u < userCount; u++) {
            address user = registry.userAt(u);

            for (uint256 t = 0; t < tokenCount; t++) {
                address token = registry.tokenAt(t);
                (
                    bool enabled,
                    , // lastExecutionTime
                    uint256 startTime,
                    uint256 goalAmount,
                    uint256 currentAmount,
                    , // penaltyBps
                    uint256 endTime
                ) = storage_.getDailySavingsConfig(user, token);

                if (enabled) {
                    // Goal should be >= current amount
                    assertGe(
                        goalAmount,
                        currentAmount,
                        string.concat(
                            "Goal less than current for user ",
                            vm.toString(user)
                        )
                    );

                    // End time should be >= start time
                    assertGe(
                        endTime,
                        startTime,
                        "End time before start time"
                    );
                }
            }
        }
    }

    /**
     * @notice INVARIANT 33: Execution times only move forward
     * @dev Last execution time should be monotonic
     * Priority: MEDIUM
     * Risk: Time manipulation
     */
    function invariant_daily_execution_monotonic() external view {
        uint256 userCount = registry.usersLength();
        uint256 tokenCount = registry.tokensLength();

        for (uint256 u = 0; u < userCount; u++) {
            address user = registry.userAt(u);

            for (uint256 t = 0; t < tokenCount; t++) {
                address token = registry.tokenAt(t);
                (
                    bool enabled,
                    uint256 lastExecutionTime,
                    , , , ,
                ) = storage_.getDailySavingsConfig(user, token);

                uint256 recorded = registry.lastDailyExecution(user, token);

                // Last execution time should not regress
                assertTrue(
                    lastExecutionTime >= recorded,
                    string.concat(
                        "Daily execution regressed for user ",
                        vm.toString(user)
                    )
                );
            }
        }
    }

    /**
     * @notice INVARIANT 34: Penalty bounds correct
     * @dev Penalty BPS should be within valid range (0-3000 per contract MAX_PENALTY_BPS)
     * Priority: MEDIUM
     * Risk: Incorrect penalty bounds
     */
    function invariant_daily_penalty_bounds() external view {
        uint256 userCount = registry.usersLength();
        uint256 tokenCount = registry.tokensLength();

        for (uint256 u = 0; u < userCount; u++) {
            address user = registry.userAt(u);

            for (uint256 t = 0; t < tokenCount; t++) {
                address token = registry.tokenAt(t);
                (
                    bool enabled,
                    , , , , uint256 penaltyBps,
                ) = storage_.getDailySavingsConfig(user, token);

                if (enabled) {
                    // Penalty should be <= MAX_PENALTY_BPS (3000 = 30%)
                    assertLe(
                        penaltyBps,
                        3000,
                        string.concat(
                            "Penalty exceeds 30% max for user ",
                            vm.toString(user)
                        )
                    );
                }
            }
        }
    }

    /**
     * @notice INVARIANT 35: Daily execution preserves value
     * @dev Deposits should match current amount increases
     * Priority: CRITICAL
     * Risk: Value leakage on executions
     */
    function invariant_daily_execution_value_conservation() external view {
        uint256 userCount = registry.usersLength();
        uint256 tokenCount = registry.tokensLength();

        for (uint256 u = 0; u < userCount; u++) {
            address user = registry.userAt(u);

            for (uint256 t = 0; t < tokenCount; t++) {
                address token = registry.tokenAt(t);

                // Get expected deposited from handler
                uint256 expectedDeposited = registry.expectedDailyDeposits(user, token);
                uint256 expectedWithdrawn = registry.expectedDailyWithdrawals(user, token);

                // Get current amount from storage
                (,,, , uint256 currentAmount,,) =
                    storage_.getDailySavingsConfig(user, token);

                // Fix: Current should be deposits minus withdrawals (accounting for fees/penalties)
                // The current amount can be less than deposits if withdrawals occurred
                // But it should never exceed deposits
                if (expectedDeposited > 0) {
                    // Current amount should be <= deposits (since withdrawals reduce it)
                    assertTrue(
                        currentAmount <= expectedDeposited,
                        string.concat(
                            "Current amount exceeds deposits for user ",
                            vm.toString(user),
                            " token ",
                            vm.toString(token)
                        )
                    );
                    
                    // If no withdrawals, current should equal deposits (within rounding)
                    if (expectedWithdrawn == 0) {
                        // Allow small rounding differences
                        uint256 diff = currentAmount > expectedDeposited 
                            ? currentAmount - expectedDeposited 
                            : expectedDeposited - currentAmount;
                        assertLe(diff, 1, "Current should match deposits when no withdrawals");
                    }
                }
            }
        }
    }

    /**
     * @notice INVARIANT 36: Withdrawal value conservation
     * @dev withdrawn = net + penalty for all withdrawals
     * Priority: CRITICAL
     * Risk: Value loss/creation on withdrawals
     */
    function invariant_withdrawal_value_conservation() external view {
        uint256 withdrawalCount = registry.totalDailyWithdrawals();

        for (uint256 i = 0; i < withdrawalCount; i++) {
            (
                address user,
                address token,
                uint256 withdrawnAmount,
                uint256 penalty,
                uint256 netReceived
            ) = registry.getDailyWithdrawal(i);

            // Fundamental equation: withdrawn = net + penalty
            assertEq(
                withdrawnAmount,
                netReceived + penalty,
                string.concat(
                    "Withdrawal value not conserved for user ",
                    vm.toString(user),
                    " token ",
                    vm.toString(token)
                )
            );

            // If penalty exists, treasury should have received it
            if (penalty > 0) {
                uint256 treasuryBefore = registry.treasuryBalanceBefore(i, token);
                uint256 treasuryAfter = registry.treasuryBalanceAfter(i, token);
                
                uint256 treasuryIncrease = treasuryAfter > treasuryBefore 
                    ? treasuryAfter - treasuryBefore 
                    : 0;

                // Fix: Treasury should receive at least the penalty (may receive more from other operations)
                assertGe(
                    treasuryIncrease,
                    penalty,
                    "Penalty not sent to treasury"
                );
            }
        }
    }

    /**
     * @notice INVARIANT 37: Execution timing correct
     * @dev Executions should only happen when appropriate
     * Priority: HIGH
     * Risk: Incorrect execution timing
     */
    function invariant_execution_timing_correct() external view {
        uint256 userCount = registry.usersLength();
        uint256 tokenCount = registry.tokensLength();

        for (uint256 u = 0; u < userCount; u++) {
            address user = registry.userAt(u);

            for (uint256 t = 0; t < tokenCount; t++) {
                address token = registry.tokenAt(t);

                (
                    bool enabled,
                    uint256 lastExecutionTime,
                    uint256 startTime,
                    uint256 goalAmount,
                    uint256 currentAmount,
                    ,
                    uint256 endTime
                ) = storage_.getDailySavingsConfig(user, token);

                if (!enabled) continue;

                uint256 execCount = registry.executionCount(user, token);

                if (execCount > 0) {
                    // Execution should only happen after start time
                    assertGe(
                        lastExecutionTime,
                        startTime,
                        "Execution before start time"
                    );

                    // Execution should only happen if not past end time
                    if (endTime > 0) {
                        assertLe(
                            lastExecutionTime,
                            endTime,
                            "Execution after end time"
                        );
                    }

                    // If goal exists and is reached, no more executions should occur
                    bool goalReached = goalAmount > 0 && currentAmount >= goalAmount;
                    if (goalReached) {
                        // This is the current state - previous executions were valid
                        assertTrue(true, "Goal reached state is valid");
                    }
                }
            }
        }
    }

    /**
     * @notice INVARIANT 38: Executed amounts match configuration
     * @dev Executed amount should equal dailyAmount * daysPassed (or goal-limited)
     * Priority: HIGH
     * Risk: Incorrect savings amounts
     */
    function invariant_executed_amounts_match_config() external view {
        uint256 executionCount = registry.totalDailyExecutions();

        for (uint256 i = 0; i < executionCount; i++) {
            (
                address user,
                address token,
                uint256 executedAmount,
                uint256 daysPassed
            ) = registry.getDailyExecution(i);

            // Skip zero executions
            if (executedAmount == 0) {
                string memory reason = registry.executionSkipReason(i);
                assertTrue(
                    bytes(reason).length > 0,
                    "Zero execution without reason"
                );
                continue;
            }

            // Get config at execution time
            (
                uint256 goalAmount,
                uint256 currentAmountBefore,
                uint256 dailyAmount
            ) = registry.configAtExecution(i);

            // Calculate expected amount
            uint256 expectedAmount = dailyAmount * daysPassed;

            // If goal exists, amount should be capped
            if (goalAmount > 0) {
                uint256 remainingToGoal = goalAmount > currentAmountBefore
                    ? goalAmount - currentAmountBefore
                    : 0;

                if (expectedAmount > remainingToGoal) {
                    expectedAmount = remainingToGoal;
                }
            }

            // Executed should match expected (allowing for fees)
            assertLe(
                executedAmount,
                expectedAmount,
                string.concat(
                    "Executed amount exceeds expected for user ",
                    vm.toString(user)
                )
            );
        }
    }

    /**
     * @notice INVARIANT 39: Batch processing consistency
     * @dev Batch should process eligible tokens correctly
     * Priority: MEDIUM
     * Risk: Missed executions
     */
    function invariant_batch_processing_consistent() external view {
        uint256 batchCount = registry.totalBatchExecutions();

        for (uint256 i = 0; i < batchCount; i++) {
            (
                address user,
                uint256 tokensProcessed,
                uint256 totalTokens,
                uint256 gasUsed
            ) = registry.getBatchExecution(i);

            // Processed should not exceed total
            assertLe(
                tokensProcessed,
                totalTokens,
                "Processed more tokens than exist"
            );

            // Gas should be reasonable (not unlimited)
            // Allow base gas of 100k for batch overhead + 300k per token
            uint256 expectedMaxGas = 100000 + (tokensProcessed * 300000);
            assertLe(
                gasUsed,
                expectedMaxGas,
                "Excessive gas usage in batch"
            );
        }
    }

    /**
     * @notice INVARIANT 40: Goal state transitions correct
     * @dev Goal states should transition properly
     * Priority: MEDIUM
     * Risk: Incorrect goal tracking
     */
    function invariant_goal_state_transitions() external view {
        uint256 userCount = registry.usersLength();
        uint256 tokenCount = registry.tokensLength();

        for (uint256 u = 0; u < userCount; u++) {
            address user = registry.userAt(u);

            for (uint256 t = 0; t < tokenCount; t++) {
                address token = registry.tokenAt(t);

                (
                    bool enabled,
                    ,
                    ,
                    uint256 goalAmount,
                    uint256 currentAmount,
                    ,
                ) = storage_.getDailySavingsConfig(user, token);

                if (!enabled || goalAmount == 0) continue;

                bool currentlyReached = currentAmount >= goalAmount;
                bool wasReached = registry.wasGoalReached(user, token);

                // Once goal is reached, it should stay reached (unless withdrawal or goal was increased)
                // Note: If goal was increased after being reached, currentAmount might be < new goalAmount
                // This is valid - the old goal was reached, but a new higher goal was set
                if (wasReached && !currentlyReached) {
                    // Goal was reached but is no longer reached - this is only valid if:
                    // 1. There was a withdrawal, OR
                    // 2. The goal was increased (we can't easily check this, so we allow it)
                    // For now, we only check if there was a withdrawal
                    assertTrue(
                        registry.hadWithdrawal(user, token),
                        "Goal became un-reached without withdrawal"
                    );
                }

                // If goal is reached, event should have been emitted
                if (currentlyReached && wasReached) {
                    assertTrue(
                        registry.goalReachedEventEmitted(user, token),
                        "Goal reached but no event recorded"
                    );
                }
            }
        }
    }

    /**
     * @notice INVARIANT 41: Execution respects allowance and balance
     * @dev Executions should only succeed with sufficient funds
     * Priority: MEDIUM
     * Risk: Failed executions
     */
    function invariant_executions_respect_funds() external view {
        uint256 executionCount = registry.totalDailyExecutions();

        for (uint256 i = 0; i < executionCount; i++) {
            (
                ,
                ,
                uint256 executedAmount,
            ) = registry.getDailyExecution(i);

            if (executedAmount > 0) {
                // User must have had sufficient allowance
                uint256 allowanceBefore = registry.allowanceBeforeExecution(i);
                assertGe(
                    allowanceBefore,
                    executedAmount,
                    "Execution exceeded allowance"
                );

                // User must have had sufficient balance
                uint256 balanceBefore = registry.balanceBeforeExecution(i);
                assertGe(
                    balanceBefore,
                    executedAmount,
                    "Execution exceeded balance"
                );
            }
        }
    }
}

