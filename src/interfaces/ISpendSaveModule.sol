// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../SpendSaveStorage.sol";

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