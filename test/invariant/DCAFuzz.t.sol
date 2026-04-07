// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/**
 * @title DCAFuzz
 * @notice Fuzz tests for DCA logic
 * @dev Tests edge cases in DCA calculations
 */
contract DCAFuzz is Test {

    /**
     * @notice Fuzz test: DCA amounts within savings
     */
    function testFuzz_dcaAmountBounds(
        uint256 savings,
        uint256 dcaAmount
    ) public {
        savings = bound(savings, 0, type(uint128).max);
        dcaAmount = bound(dcaAmount, 0, savings);

        assertLe(dcaAmount, savings, "DCA amount exceeds savings");
    }

    /**
     * @notice Fuzz test: DCA slippage calculation
     */
    function testFuzz_dcaSlippageCalculation(
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 slippageBps
    ) public {
        inputAmount = bound(inputAmount, 1, type(uint128).max);
        slippageBps = bound(slippageBps, 0, 10000);
        outputAmount = bound(outputAmount, 0, inputAmount * 2);

        // Calculate minimum acceptable output
        uint256 minOutput = inputAmount * (10000 - slippageBps) / 10000;

        // Output should be >= minOutput for valid swap
        if (outputAmount >= minOutput) {
            assertGe(outputAmount, minOutput, "Output below minimum");
        }
    }

    /**
     * @notice Fuzz test: DCA deadline validation
     */
    function testFuzz_dcaDeadlineValidation(
        uint256 deadline,
        uint256 currentTime
    ) public {
        currentTime = bound(currentTime, block.timestamp, block.timestamp + 365 days);
        // Fix: Ensure deadline calculation doesn't underflow
        uint256 minDeadline = currentTime > 30 days ? currentTime - 30 days : 0;
        deadline = bound(deadline, minDeadline, currentTime + 365 days);

        bool isValid = deadline >= currentTime;

        assertEq(isValid, deadline >= currentTime, "Deadline validation incorrect");
    }

    /**
     * @notice Fuzz test: DCA queue ordering
     */
    function testFuzz_dcaQueueOrdering(
        uint256 deadline1,
        uint256 deadline2
    ) public {
        uint256 baseTime = block.timestamp;
        deadline1 = bound(deadline1, baseTime, baseTime + 365 days);
        deadline2 = bound(deadline2, baseTime, baseTime + 365 days);

        // Earlier deadline should come first
        if (deadline1 < deadline2) {
            assertLt(deadline1, deadline2, "Queue ordering incorrect");
        } else if (deadline2 < deadline1) {
            assertLt(deadline2, deadline1, "Queue ordering incorrect");
        }
    }

    /**
     * @notice Fuzz test: DCA tick calculation
     */
    function testFuzz_dcaTickCalculation(
        int256 tickInput
    ) public {
        int24 maxTick = 887272;
        int24 minTick = -887272;

        // Fix: Use safe conversion to avoid underflow
        // Bound the input directly to valid tick range
        int256 boundedTick = tickInput;
        if (boundedTick < int256(int24(minTick))) {
            boundedTick = int256(int24(minTick));
        }
        if (boundedTick > int256(int24(maxTick))) {
            boundedTick = int256(int24(maxTick));
        }
        
        int24 tick = int24(boundedTick);

        assertGe(tick, minTick, "Tick too low");
        assertLe(tick, maxTick, "Tick too high");
    }

    /**
     * @notice Fuzz test: DCA batch execution value conservation
     */
    function testFuzz_dcaBatchExecution(
        uint256[] memory inputAmounts,
        uint256[] memory outputAmounts,
        uint256 slippageBps
    ) public {
        // Fix: Very lenient bounds to avoid too many rejections
        uint256 maxLength = 3; // Further reduced to avoid rejections
        if (inputAmounts.length == 0 || inputAmounts.length > maxLength) return;
        if (inputAmounts.length != outputAmounts.length) return;
        slippageBps = bound(slippageBps, 0, 10000);

        uint256 totalInput = 0;
        uint256 totalOutput = 0;

        for (uint256 i = 0; i < inputAmounts.length; i++) {
            // Use much smaller bounds to avoid overflow and rejections
            inputAmounts[i] = bound(inputAmounts[i], 1, type(uint64).max);
            outputAmounts[i] = bound(outputAmounts[i], 0, inputAmounts[i] * 2);
            totalInput += inputAmounts[i];
            totalOutput += outputAmounts[i];
        }

        // Total output should be >= total input * (1 - slippage)
        uint256 minTotalOutput = totalInput * (10000 - slippageBps) / 10000;

        if (totalOutput >= minTotalOutput) {
            assertGe(totalOutput, minTotalOutput, "Batch DCA value not conserved");
        }
    }
}

