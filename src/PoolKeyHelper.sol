// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";

/**
 * @title PoolKeyHelper
 * @notice Helper library for creating PoolKey structs with default parameters
 * @dev Pure library functions that are inlined at compile time (zero gas overhead)
 */
library PoolKeyHelper {
    uint24 internal constant DEFAULT_FEE_TIER = 3000;
    int24 internal constant DEFAULT_TICK_SPACING = 60;

    /**
     * @notice Create a PoolKey struct with default fee tier and tick spacing
     * @param token0 First token address
     * @param token1 Second token address
     * @return key PoolKey struct with default parameters
     */
    function createPoolKey(address token0, address token1) internal pure returns (PoolKey memory key) {
        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: DEFAULT_FEE_TIER,
            tickSpacing: DEFAULT_TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }
}
