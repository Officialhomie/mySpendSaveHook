// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseInvariantTest} from "./BaseInvariantTest.sol";

/**
 * @title ERC6909Invariants
 * @notice CRITICAL: Ensures ERC6909 token standard compliance
 * @dev Violations break integrations and enable token duplication attacks
 */
contract ERC6909Invariants is BaseInvariantTest {

    /**
     * @notice INVARIANT 10: Total supply equals sum of all balances
     * @dev For each tokenId: totalSupply == sum(balanceOf(user, tokenId))
     * Priority: CRITICAL
     * Risk: Token duplication or destruction
     */
    function invariant_erc6909_total_supply_equals_balances() external view {
        uint256 tokenCount = registry.tokensLength();

        for (uint256 t = 0; t < tokenCount; t++) {
            address tokenAddress = registry.tokenAt(t);
            uint256 tokenId = tokenModule.getTokenId(tokenAddress);

            if (tokenId == 0) continue; // Not registered yet

            // Sum all user balances
            uint256 sumOfBalances = 0;
            uint256 userCount = registry.usersLength();

            for (uint256 u = 0; u < userCount; u++) {
                address user = registry.userAt(u);
                uint256 balance = storage_.balanceOf(user, tokenId);
                sumOfBalances += balance;
            }

            // Get recorded total supply
            uint256 totalSupply = storage_.getTotalSupply(tokenId);

            assertEq(
                totalSupply,
                sumOfBalances,
                string.concat(
                    "ERC6909 supply mismatch for token ",
                    vm.toString(tokenAddress)
                )
            );
        }
    }

    /**
     * @notice INVARIANT 11: Transfer preserves total value
     * @dev After transfer: sender_balance_before + receiver_balance_before ==
     *                     sender_balance_after + receiver_balance_after
     * Priority: CRITICAL
     * Risk: Token duplication
     */
    function invariant_erc6909_transfer_conservation() external view {
        // This is tracked by handler during transfers
        uint256 transferCount = registry.transferOperationCount();

        for (uint256 i = 0; i < transferCount; i++) {
            (
                address from,
                address to,
                uint256 tokenId,
                uint256 balancesBefore,
                uint256 balancesAfter
            ) = registry.getTransferOperation(i);

            assertEq(
                balancesBefore,
                balancesAfter,
                string.concat(
                    "Transfer violated conservation: ",
                    vm.toString(from),
                    " -> ",
                    vm.toString(to)
                )
            );
        }
    }

    /**
     * @notice INVARIANT 12: Allowances never go negative
     * @dev Allowances should decrease on transferFrom, never below zero
     * Priority: HIGH
     * Risk: Unauthorized transfers
     */
    function invariant_erc6909_allowances_non_negative() external view {
        uint256 userCount = registry.usersLength();
        uint256 tokenCount = registry.tokensLength();

        for (uint256 u = 0; u < userCount; u++) {
            address owner = registry.userAt(u);

            for (uint256 s = 0; s < userCount; s++) {
                address spender = registry.userAt(s);
                if (owner == spender) continue;

                for (uint256 t = 0; t < tokenCount; t++) {
                    address tokenAddress = registry.tokenAt(t);
                    uint256 tokenId = tokenModule.getTokenId(tokenAddress);

                    if (tokenId == 0) continue;

                    uint256 allowance = storage_.getAllowance(owner, spender, tokenId);

                    // Allowances are uint256, but check they're reasonable
                    // (not max uint256 which indicates unlimited)
                    if (allowance != type(uint256).max) {
                        uint256 ownerBalance = storage_.balanceOf(owner, tokenId);
                        assertLe(
                            allowance,
                            ownerBalance * 100, // Max 100x balance
                            "Allowance unreasonably high"
                        );
                    }
                }
            }
        }
    }

    /**
     * @notice INVARIANT 13: Balances never go negative (overflow check)
     * @dev All balances should be reasonable values, not near uint256.max
     * Priority: HIGH
     * Risk: Underflow bugs causing massive balances
     */
    function invariant_erc6909_balances_reasonable() external view {
        uint256 userCount = registry.usersLength();
        uint256 tokenCount = registry.tokensLength();

        for (uint256 u = 0; u < userCount; u++) {
            address user = registry.userAt(u);

            for (uint256 t = 0; t < tokenCount; t++) {
                address tokenAddress = registry.tokenAt(t);
                uint256 tokenId = tokenModule.getTokenId(tokenAddress);

                if (tokenId == 0) continue;

                uint256 balance = storage_.balanceOf(user, tokenId);

                // Balance should not be suspiciously high (indicates underflow)
                assertLt(
                    balance,
                    type(uint128).max, // Use uint128 as reasonable max
                    string.concat(
                        "Suspicious balance for user ",
                        vm.toString(user),
                        " token ",
                        vm.toString(tokenAddress)
                    )
                );
            }
        }
    }

    /**
     * @notice INVARIANT 14: Operator permissions are bidirectional
     * @dev If A sets B as operator, B can transfer A's tokens
     * Priority: MEDIUM
     * Risk: Broken delegation
     */
    function invariant_erc6909_operator_consistency() external view {
        uint256 userCount = registry.usersLength();

        for (uint256 o = 0; o < userCount; o++) {
            address owner = registry.userAt(o);

            for (uint256 op = 0; op < userCount; op++) {
                address operator = registry.userAt(op);
                if (owner == operator) continue;

                bool isOperator = tokenModule.isOperator(owner, operator);

                // If operator status set, should be consistent in storage
                if (isOperator) {
                    // Verify operator can indeed operate
                    // (Would need to test actual transfer in fuzz test)
                    assertTrue(
                        storage_.isOperator(owner, operator),
                        "Operator status inconsistent"
                    );
                }
            }
        }
    }

    /**
     * @notice INVARIANT 15: Mint increases supply, burn decreases supply
     * @dev Supply changes should match mint/burn operations exactly
     * Priority: CRITICAL
     * Risk: Supply inflation/deflation bugs
     */
    function invariant_erc6909_mint_burn_supply_changes() external view {
        uint256 tokenCount = registry.tokensLength();

        for (uint256 t = 0; t < tokenCount; t++) {
            address tokenAddress = registry.tokenAt(t);
            uint256 tokenId = tokenModule.getTokenId(tokenAddress);

            if (tokenId == 0) continue;

            // Get tracked mint/burn amounts from handler
            uint256 totalMinted = registry.totalMinted(tokenId);
            uint256 totalBurned = registry.totalBurned(tokenId);

            // Get current supply
            uint256 currentSupply = storage_.getTotalSupply(tokenId);

            // Supply should equal: minted - burned
            assertEq(
                currentSupply,
                totalMinted - totalBurned,
                string.concat(
                    "Supply doesn't match mint/burn for token ",
                    vm.toString(tokenAddress)
                )
            );
        }
    }

    /**
     * @notice INVARIANT 16: Token URI consistent with token ID
     * @dev If token registered, should have valid URI
     * Priority: LOW
     * Risk: Broken metadata
     */
    function invariant_erc6909_token_metadata_consistent() external view {
        uint256 tokenCount = registry.tokensLength();

        for (uint256 t = 0; t < tokenCount; t++) {
            address tokenAddress = registry.tokenAt(t);
            uint256 tokenId = tokenModule.getTokenId(tokenAddress);

            if (tokenId > 0) {
                // Token is registered, should have metadata
                address retrievedAddress = storage_.idToToken(tokenId);

                assertEq(
                    retrievedAddress,
                    tokenAddress,
                    "Token ID -> address mapping broken"
                );
            }
        }
    }

    /**
     * @notice INVARIANT 17: No duplicate token IDs
     * @dev Each token address gets unique ID
     * Priority: HIGH
     * Risk: Token confusion, wrong withdrawals
     */
    function invariant_erc6909_unique_token_ids() external view {
        uint256 tokenCount = registry.tokensLength();

        // Build mapping of tokenId -> count
        // Note: Solidity doesn't support dynamic mappings in memory, so we check pairs
        for (uint256 t1 = 0; t1 < tokenCount; t1++) {
            address token1 = registry.tokenAt(t1);
            uint256 tokenId1 = tokenModule.getTokenId(token1);

            if (tokenId1 == 0) continue;

            for (uint256 t2 = t1 + 1; t2 < tokenCount; t2++) {
                address token2 = registry.tokenAt(t2);
                uint256 tokenId2 = tokenModule.getTokenId(token2);

                if (tokenId2 == 0) continue;

                // Different tokens should have different IDs
                if (token1 != token2) {
                    assertTrue(
                        tokenId1 != tokenId2,
                        string.concat(
                            "Duplicate token ID detected: ",
                            vm.toString(tokenId1)
                        )
                    );
                }
            }
        }
    }
}

