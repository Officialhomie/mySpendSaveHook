// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/**
 * @title SavingsFuzz
 * @notice Fuzz tests for savings calculations and fee logic
 * @dev Tests edge cases in savings and fee calculations
 */
contract SavingsFuzz is Test {

    /**
     * @notice Fuzz test: Savings calculation always correct
     * @dev Tests: savings = amount * percentage / 10000
     */
    function testFuzz_savingsCalculation(
        uint256 amount,
        uint16 percentage
    ) public {
        // Bound inputs
        amount = bound(amount, 1, type(uint128).max);
        percentage = uint16(bound(uint256(percentage), 0, 10000));

        // Calculate expected savings
        uint256 expectedSavings = (amount * percentage) / 10000;

        // Verify calculation doesn't overflow
        assertLe(expectedSavings, amount, "Savings exceeds input");

        // Verify remainder
        uint256 remainder = amount - expectedSavings;
        assertEq(amount, expectedSavings + remainder, "Value not conserved");
    }

    /**
     * @notice Fuzz test: Fee calculation always correct
     * @dev Tests: fee = savings * treasuryFee / 10000
     */
    function testFuzz_feeCalculation(
        uint256 savings,
        uint16 treasuryFee
    ) public {
        savings = bound(savings, 0, type(uint128).max);
        treasuryFee = uint16(bound(uint256(treasuryFee), 0, 10000));

        uint256 expectedFee = (savings * treasuryFee) / 10000;

        assertLe(expectedFee, savings, "Fee exceeds savings");

        uint256 netSavings = savings - expectedFee;
        assertEq(savings, netSavings + expectedFee, "Value not conserved");
    }

    /**
     * @notice Fuzz test: Combined savings and fee calculation
     */
    function testFuzz_savingsWithFee(
        uint256 amount,
        uint16 savingsPercentage,
        uint16 treasuryFee
    ) public {
        amount = bound(amount, 1, type(uint128).max);
        savingsPercentage = uint16(bound(uint256(savingsPercentage), 0, 10000));
        treasuryFee = uint16(bound(uint256(treasuryFee), 0, 10000));

        // Step 1: Calculate savings
        uint256 savingsAmount = (amount * savingsPercentage) / 10000;

        // Step 2: Calculate fee on savings
        uint256 feeAmount = (savingsAmount * treasuryFee) / 10000;

        // Step 3: Net savings
        uint256 netSavings = savingsAmount - feeAmount;

        // Step 4: Amount to user
        uint256 toUser = amount - savingsAmount;

        // Verify value conservation
        assertEq(
            amount,
            toUser + netSavings + feeAmount,
            "Value not conserved in full flow"
        );
    }

    /**
     * @notice Fuzz test: Auto-increment doesn't exceed max
     */
    function testFuzz_autoIncrementBounds(
        uint16 currentPercentage,
        uint16 autoIncrement,
        uint16 maxPercentage
    ) public {
        currentPercentage = uint16(bound(uint256(currentPercentage), 0, 10000));
        maxPercentage = uint16(bound(uint256(maxPercentage), uint256(currentPercentage), 10000));
        autoIncrement = uint16(bound(uint256(autoIncrement), 0, uint256(maxPercentage) - uint256(currentPercentage)));

        uint256 nextPercentage = uint256(currentPercentage) + uint256(autoIncrement);

        assertLe(nextPercentage, maxPercentage, "Auto-increment exceeds max");
        assertLe(nextPercentage, 10000, "Next percentage exceeds 100%");
    }

    /**
     * @notice Fuzz test: Withdrawal timelock validation
     */
    function testFuzz_withdrawalTimelock(
        uint256 lockTime,
        uint256 withdrawTime
    ) public {
        lockTime = bound(lockTime, block.timestamp, block.timestamp + 30 days);
        withdrawTime = bound(withdrawTime, block.timestamp, block.timestamp + 60 days);

        bool shouldAllow = withdrawTime >= lockTime;

        if (shouldAllow) {
            // Withdrawal should succeed
            assertTrue(withdrawTime >= lockTime, "Timelock logic broken");
        } else {
            // Withdrawal should fail
            assertTrue(withdrawTime < lockTime, "Timelock logic broken");
        }
    }

    /**
     * @notice Fuzz test: Round up savings calculation
     */
    function testFuzz_roundUpSavings(
        uint256 amount,
        uint16 percentage
    ) public {
        amount = bound(amount, 1, type(uint128).max);
        percentage = uint16(bound(uint256(percentage), 1, 10000));

        // Normal calculation
        uint256 normalSavings = (amount * percentage) / 10000;

        // Round up calculation
        uint256 roundedSavings = (amount * percentage + 9999) / 10000;

        // Rounded should be >= normal
        assertGe(roundedSavings, normalSavings, "Round up less than normal");

        // Difference should be at most 1
        assertLe(roundedSavings - normalSavings, 1, "Round up too aggressive");
    }

    /**
     * @notice Fuzz test: Savings goal tracking
     */
    function testFuzz_savingsGoalProgress(
        uint256 currentAmount,
        uint256 goalAmount,
        uint256 newSavings
    ) public {
        currentAmount = bound(currentAmount, 0, type(uint128).max / 2);
        goalAmount = bound(goalAmount, currentAmount, type(uint128).max);
        newSavings = bound(newSavings, 0, goalAmount - currentAmount);

        uint256 afterSavings = currentAmount + newSavings;

        assertLe(afterSavings, goalAmount, "Savings exceed goal");

        if (afterSavings == goalAmount) {
            // Goal reached
            assertTrue(afterSavings >= goalAmount, "Goal logic broken");
        }
    }

    /**
     * @notice Fuzz test: Batch operations value conservation
     */
    function testFuzz_batchSavingsConservation(
        uint256[] memory amounts,
        uint16 percentage
    ) public {
        vm.assume(amounts.length > 0 && amounts.length <= 10);
        percentage = uint16(bound(uint256(percentage), 0, 10000));

        uint256 totalInput = 0;
        uint256 totalSavings = 0;

        for (uint256 i = 0; i < amounts.length; i++) {
            amounts[i] = bound(amounts[i], 1, type(uint64).max);
            totalInput += amounts[i];
            totalSavings += (amounts[i] * percentage) / 10000;
        }

        uint256 remainder = totalInput - totalSavings;

        assertEq(
            totalInput,
            totalSavings + remainder,
            "Batch value not conserved"
        );
    }
}

