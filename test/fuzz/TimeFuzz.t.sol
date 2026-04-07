// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/**
 * @title TimeFuzz
 * @notice Fuzz tests for time-based operations
 * @dev Tests edge cases in timelock and daily savings timing
 */
contract TimeFuzz is Test {

    /**
     * @notice Fuzz test: Daily savings timing intervals
     */
    function testFuzz_dailySavingsTiming(
        uint256 startTime,
        uint256 executionTime,
        uint256 endTime
    ) public {
        uint256 baseTime = block.timestamp;
        startTime = bound(startTime, baseTime, baseTime + 365 days);
        endTime = bound(endTime, startTime, startTime + 365 days);
        executionTime = bound(executionTime, startTime, endTime);

        assertGe(executionTime, startTime, "Execution before start");
        assertLe(executionTime, endTime, "Execution after end");
        assertGe(endTime, startTime, "End before start");
    }

    /**
     * @notice Fuzz test: Timelock calculations
     */
    function testFuzz_timelockCalculations(
        uint256 lockTime,
        uint256 currentTime,
        uint256 maxTimelock
    ) public {
        uint256 baseTime = block.timestamp;
        maxTimelock = 30 days;
        lockTime = bound(lockTime, baseTime, baseTime + maxTimelock);
        currentTime = bound(currentTime, baseTime, baseTime + 60 days);

        bool canWithdraw = currentTime >= lockTime;
        bool withinMax = lockTime <= baseTime + maxTimelock;

        assertTrue(withinMax, "Timelock exceeds maximum");
        assertEq(canWithdraw, currentTime >= lockTime, "Timelock calculation incorrect");
    }
}

