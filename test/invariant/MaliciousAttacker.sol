// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpendSaveStorage} from "../../src/SpendSaveStorage.sol";
import {Savings} from "../../src/Savings.sol";

/**
 * @title MaliciousAttacker
 * @notice Malicious contract for testing reentrancy protection
 * @dev Attempts to reenter during withdrawals and other operations
 */
contract MaliciousAttacker {
    SpendSaveStorage public storageContract;
    Savings public savings;
    address public targetUser;
    address public targetToken;
    uint256 public attackCount;
    bool public attacking;

    constructor(SpendSaveStorage storageContract_, Savings savings_) {
        storageContract = storageContract_;
        savings = savings_;
    }

    /**
     * @notice Attempt reentrancy attack during withdrawal
     */
    function attackWithdrawal(address user, address token, uint256 amount) external {
        targetUser = user;
        targetToken = token;
        attacking = true;
        attackCount = 0;

        try savings.withdraw(user, token, amount, false) {
            // If withdrawal succeeds, try to reenter
            if (attacking && attackCount < 10) {
                attackCount++;
                savings.withdraw(user, token, amount, false);
            }
        } catch {
            // Reentrancy guard should prevent this
        }

        attacking = false;
    }

    /**
     * @notice Receive tokens and attempt reentrancy
     */
    function onERC6909Received(
        address,
        address,
        uint256,
        uint256,
        bytes calldata
    ) external returns (bytes4) {
        if (attacking && attackCount < 10) {
            attackCount++;
            try savings.withdraw(targetUser, targetToken, 1, false) {
                // Reentrancy attempt
            } catch {
                // Should fail
            }
        }
        return this.onERC6909Received.selector;
    }
}

