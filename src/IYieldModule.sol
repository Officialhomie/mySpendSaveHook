// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SpendSaveStorage.sol";
import "./ISpendSaveModule.sol";

// Yield Module Interface
interface IYieldModule is ISpendSaveModule {
    function setYieldStrategy(address user, address token, SpendSaveStorage.YieldStrategy strategy) external;
    
    function applyYieldStrategy(address user, address token) external;
}