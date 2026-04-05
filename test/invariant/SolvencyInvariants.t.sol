// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BaseInvariantTest} from "./BaseInvariantTest.sol";

/**
 * @title SolvencyInvariants
 * @notice CRITICAL: Tests that protocol maintains sufficient balances to honor all claims
 * @dev These invariants protect against the most severe risk: protocol insolvency
 */
contract SolvencyInvariants is BaseInvariantTest {

    /**
     * @notice INVARIANT 1: Total user savings never exceed actual token balance
     * @dev If violated: Protocol is insolvent, cannot honor withdrawals
     * Priority: CRITICAL
     * Risk: Users lose funds permanently
     */
    function invariant_protocol_total_solvency() external view {
        uint256 tokenCount = registry.tokensLength();

        for (uint256 i = 0; i < tokenCount; i++) {
            address token = registry.tokenAt(i);

            // Calculate total savings claimed by all users
            uint256 totalUserSavings = 0;
            uint256 userCount = registry.usersLength();

            for (uint256 u = 0; u < userCount; u++) {
                address user = registry.userAt(u);
                totalUserSavings += storage_._savings(user, token);
            }

            // Get actual token balance held by protocol
            uint256 actualBalance = IERC20(token).balanceOf(address(storage_));

            // CRITICAL: Total claims must never exceed actual balance
            assertGe(
                actualBalance,
                totalUserSavings,
                string.concat(
                    "INSOLVENCY DETECTED: Token ",
                    vm.toString(token),
                    " - Claims: ",
                    vm.toString(totalUserSavings),
                    " > Balance: ",
                    vm.toString(actualBalance)
                )
            );
        }
    }

    /**
     * @notice INVARIANT 2: Individual user savings never exceed token balance
     * @dev If violated: Single user could drain protocol
     * Priority: CRITICAL
     * Risk: Protocol exploited by single user
     */
    function invariant_individual_user_solvency() external view {
        uint256 tokenCount = registry.tokensLength();
        uint256 userCount = registry.usersLength();

        for (uint256 t = 0; t < tokenCount; t++) {
            address token = registry.tokenAt(t);
            uint256 actualBalance = IERC20(token).balanceOf(address(storage_));

            for (uint256 u = 0; u < userCount; u++) {
                address user = registry.userAt(u);
                uint256 userSavings = storage_._savings(user, token);

                // Each user's savings must be coverable
                assertLe(
                    userSavings,
                    actualBalance,
                    string.concat(
                        "User ",
                        vm.toString(user),
                        " savings exceed total balance for token ",
                        vm.toString(token)
                    )
                );
            }
        }
    }

    /**
     * @notice INVARIANT 3: DCA queue amounts are backed by savings
     * @dev If violated: DCA execution will fail or drain unexpected funds
     * Priority: HIGH
     * Risk: Failed DCA executions, locked funds
     */
    function invariant_dca_queue_backed_by_savings() external view {
        uint256 userCount = registry.usersLength();

        for (uint256 i = 0; i < userCount; i++) {
            address user = registry.userAt(i);
            uint256 queueLength = storage_.getDcaQueueLength(user);

            for (uint256 q = 0; q < queueLength; q++) {
                (
                    address fromToken,
                    , // toToken
                    uint256 amount,
                    , // targetTick
                    , // deadline
                    bool executed,
                    // slippageBps
                ) = storage_.getDcaQueueItem(user, q);

                if (!executed) {
                    uint256 userSavings = storage_._savings(user, fromToken);

                    // Pending DCA amounts must be backed by actual savings
                    assertGe(
                        userSavings,
                        amount,
                        string.concat(
                            "DCA queue item ",
                            vm.toString(q),
                            " for user ",
                            vm.toString(user),
                            " not backed by savings"
                        )
                    );
                }
            }
        }
    }

    /**
     * @notice INVARIANT 4: Treasury accumulated fees are correct
     * @dev If violated: Treasury over/under paid, accounting broken
     * Priority: HIGH
     * Risk: Incorrect fee distribution
     */
    function invariant_treasury_fee_accumulation_correct() external view {
        uint256 tokenCount = registry.tokensLength();

        for (uint256 i = 0; i < tokenCount; i++) {
            address token = registry.tokenAt(i);

            // Get expected treasury fees from handler tracking
            uint256 expectedTreasuryFees = registry.expectedTreasuryFees(token);

            // Get actual treasury balance
            uint256 actualTreasuryBalance = storage_._savings(storage_.treasury(), token);

            assertEq(
                actualTreasuryBalance,
                expectedTreasuryFees,
                string.concat(
                    "Treasury fee mismatch for token ",
                    vm.toString(token),
                    " - Expected: ",
                    vm.toString(expectedTreasuryFees),
                    " Got: ",
                    vm.toString(actualTreasuryBalance)
                )
            );
        }
    }

    /**
     * @notice INVARIANT 5: Savings + Treasury = Total deposits (minus withdrawals)
     * @dev If violated: Value created or destroyed in the system
     * Priority: CRITICAL
     * Risk: Economic model broken
     */
    function invariant_total_value_conservation() external view {
        uint256 tokenCount = registry.tokensLength();

        for (uint256 i = 0; i < tokenCount; i++) {
            address token = registry.tokenAt(i);

            // Sum all user savings (excluding treasury)
            uint256 totalUserSavings = 0;
            uint256 userCount = registry.usersLength();

            for (uint256 u = 0; u < userCount; u++) {
                address user = registry.userAt(u);
                if (user != storage_.treasury()) {
                    totalUserSavings += storage_._savings(user, token);
                }
            }

            // Get treasury balance
            uint256 treasuryBalance = storage_._savings(storage_.treasury(), token);

            // Get expected values from handler
            uint256 expectedTotal = registry.expectedTotalDeposits(token);
            uint256 expectedFees = registry.expectedTreasuryFees(token);
            uint256 expectedWithdrawals = registry.expectedTotalWithdrawals(token);

            // Total recorded value should match expected (deposits - withdrawals)
            uint256 totalRecorded = totalUserSavings + treasuryBalance;
            uint256 expectedRecorded = expectedTotal - expectedWithdrawals;

            // Allow small rounding differences
            uint256 diff = totalRecorded > expectedRecorded
                ? totalRecorded - expectedRecorded
                : expectedRecorded - totalRecorded;

            assertLe(
                diff,
                userCount, // Allow 1 wei per user for rounding
                string.concat(
                    "Value conservation violated for token ",
                    vm.toString(token),
                    " - Recorded: ",
                    vm.toString(totalRecorded),
                    " Expected: ",
                    vm.toString(expectedRecorded)
                )
            );
        }
    }
}

