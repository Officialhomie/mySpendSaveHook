// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SpendSaveStorage} from "../SpendSaveStorage.sol";

/**
 * @title ISpendSaveModule
 * @notice Base interface for deployment script
 */
interface ISpendSaveModule {
    function initialize(SpendSaveStorage storage_) external;
    function setModuleReferences(
        address savingStrategy,
        address savings,
        address dca,
        address slippage,
        address token,
        address dailySavings
    ) external;
}
