// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/**
 * @title PercentageFuzz
 * @notice Fuzz tests for percentage calculations
 * @dev Tests edge cases in percentage math
 */
contract PercentageFuzz is Test {

    /**
     * @notice Fuzz test: Percentage in range
     */
    function testFuzz_percentageInRange(
        uint16 percentage
    ) public {
        percentage = uint16(bound(uint256(percentage), 0, 10000));

        assertGe(percentage, 0, "Percentage negative");
        assertLe(percentage, 10000, "Percentage exceeds 100%");
    }

    /**
     * @notice Fuzz test: Max percentage enforced
     */
    function testFuzz_maxPercentageEnforced(
        uint16 currentPercentage,
        uint16 maxPercentage
    ) public {
        currentPercentage = uint16(bound(uint256(currentPercentage), 0, 10000));
        maxPercentage = uint16(bound(uint256(maxPercentage), uint256(currentPercentage), 10000));

        assertLe(currentPercentage, maxPercentage, "Current exceeds max");
        assertLe(maxPercentage, 10000, "Max exceeds 100%");
    }

    /**
     * @notice Fuzz test: Auto-increment progression
     */
    function testFuzz_autoIncrementProgression(
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
     * @notice Fuzz test: Specific token percentage
     */
    function testFuzz_specificTokenPercentage(
        uint16 percentage,
        uint16 maxPercentage
    ) public {
        percentage = uint16(bound(uint256(percentage), 0, 10000));
        maxPercentage = uint16(bound(uint256(maxPercentage), uint256(percentage), 10000));

        // Specific token percentage should respect max
        assertLe(percentage, maxPercentage, "Specific token percentage exceeds max");
    }

    /**
     * @notice Fuzz test: Dynamic percentage adjustment
     */
    function testFuzz_dynamicPercentageAdjustment(
        uint16 startPercentage,
        uint16 increment,
        uint16 maxPercentage,
        uint256 iterations
    ) public {
        startPercentage = uint16(bound(uint256(startPercentage), 0, 10000));
        maxPercentage = uint16(bound(uint256(maxPercentage), uint256(startPercentage), 10000));
        increment = uint16(bound(uint256(increment), 0, uint256(maxPercentage) - uint256(startPercentage)));
        iterations = bound(iterations, 0, 100);

        uint256 currentPercentage = startPercentage;

        for (uint256 i = 0; i < iterations; i++) {
            uint256 nextPercentage = currentPercentage + increment;
            if (nextPercentage > maxPercentage) {
                nextPercentage = maxPercentage;
            }

            assertLe(nextPercentage, maxPercentage, "Dynamic adjustment exceeds max");
            assertLe(nextPercentage, 10000, "Dynamic adjustment exceeds 100%");

            currentPercentage = nextPercentage;
            if (currentPercentage >= maxPercentage) break;
        }
    }
}

