// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SpendSaveStorage.sol";

// Base module interface
interface ISpendSaveModule {
    function initialize(SpendSaveStorage storage_) external;
}