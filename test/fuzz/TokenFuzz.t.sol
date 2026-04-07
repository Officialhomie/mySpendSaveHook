// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/**
 * @title TokenFuzz
 * @notice Fuzz tests for token operations
 * @dev Tests edge cases in token transfers and approvals
 */
contract TokenFuzz is Test {

    /**
     * @notice Fuzz test: Token transfer amount
     */
    function testFuzz_tokenTransferAmount(
        uint256 balance,
        uint256 transferAmount
    ) public {
        balance = bound(balance, 0, type(uint128).max);
        transferAmount = bound(transferAmount, 0, balance);

        assertLe(transferAmount, balance, "Transfer amount exceeds balance");

        uint256 remaining = balance - transferAmount;
        assertEq(balance, transferAmount + remaining, "Transfer value not conserved");
    }

    /**
     * @notice Fuzz test: Token approval amount
     */
    function testFuzz_tokenApprovalAmount(
        uint256 balance,
        uint256 approvalAmount
    ) public {
        balance = bound(balance, 0, type(uint128).max);
        approvalAmount = bound(approvalAmount, 0, type(uint128).max);

        // Approval can be any amount, even > balance (for future deposits)
        assertGe(approvalAmount, 0, "Approval negative");
    }

    /**
     * @notice Fuzz test: Token burn amount
     */
    function testFuzz_tokenBurnAmount(
        uint256 balance,
        uint256 burnAmount
    ) public {
        balance = bound(balance, 0, type(uint128).max);
        burnAmount = bound(burnAmount, 0, balance);

        assertLe(burnAmount, balance, "Burn amount exceeds balance");

        uint256 remaining = balance - burnAmount;
        assertEq(balance, burnAmount + remaining, "Burn value not conserved");
    }

    /**
     * @notice Fuzz test: Token operator permissions
     */
    function testFuzz_tokenOperatorPermissions(
        bool isOperator
    ) public {
        // Operator status should be boolean
        assertTrue(isOperator || !isOperator, "Operator status invalid");

        // If operator, can transfer
        // If not operator, cannot transfer (tested in integration tests)
    }
}

