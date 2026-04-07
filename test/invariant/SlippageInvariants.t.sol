// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseInvariantTest} from "./BaseInvariantTest.sol";

/**
 * @title SlippageInvariants
 * @notice HIGH: Ensures slippage protection is correctly configured
 * @dev Tests slippage tolerance bounds
 */
contract SlippageInvariants is BaseInvariantTest {

    /**
     * @notice INVARIANT 35: User slippage <= 10% (1000 bps)
     * @dev User slippage tolerance should never exceed maximum
     * Priority: HIGH
     * Risk: Excessive slippage, user losses
     */
    function invariant_user_slippage_bounded() external view {
        uint256 userCount = registry.usersLength();
        uint256 maxSlippage = 1000; // 10%

        for (uint256 i = 0; i < userCount; i++) {
            address user = registry.userAt(i);
            uint256 tolerance = storage_.userSlippageTolerance(user);

            assertLe(
                tolerance,
                maxSlippage,
                string.concat(
                    "User slippage exceeds 10% for user ",
                    vm.toString(user)
                )
            );
        }
    }

    /**
     * @notice INVARIANT 36: Default slippage <= 5% (500 bps)
     * @dev Default slippage tolerance should never exceed maximum
     * Priority: HIGH
     * Risk: Excessive default slippage
     */
    function invariant_default_slippage_bounded() external view {
        uint256 defaultTolerance = storage_.defaultSlippageTolerance();
        uint256 maxDefaultSlippage = 500; // 5%

        assertLe(
            defaultTolerance,
            maxDefaultSlippage,
            "Default slippage exceeds 5%"
        );
    }

    /**
     * @notice INVARIANT 37: Token-specific slippage respected
     * @dev Token-specific slippage should be <= user slippage or default
     * Priority: MEDIUM
     * Risk: Inconsistent slippage application
     */
    function invariant_token_slippage_respected() external view {
        uint256 userCount = registry.usersLength();
        uint256 tokenCount = registry.tokensLength();
        uint256 maxSlippage = 1000; // 10%

        for (uint256 u = 0; u < userCount; u++) {
            address user = registry.userAt(u);
            uint256 userTolerance = storage_.userSlippageTolerance(user);
            uint256 defaultTolerance = storage_.defaultSlippageTolerance();
            uint256 effectiveMax = userTolerance > 0 ? userTolerance : defaultTolerance;

            for (uint256 t = 0; t < tokenCount; t++) {
                address token = registry.tokenAt(t);
                uint256 tokenTolerance = storage_.tokenSlippageTolerance(user, token);

                // Token-specific tolerance should be <= effective max
                assertLe(
                    tokenTolerance,
                    effectiveMax > 0 ? effectiveMax : maxSlippage,
                    string.concat(
                        "Token slippage exceeds effective max for user ",
                        vm.toString(user)
                    )
                );
            }
        }
    }
}

