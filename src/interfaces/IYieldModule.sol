// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SpendSaveStorage} from "../SpendSaveStorage.sol";
import {ISpendSaveModule} from "./ISpendSaveModule.sol";

// Yield Module Interface
interface IYieldModule is ISpendSaveModule {
    function setYieldStrategy(address user, address token, SpendSaveStorage.YieldStrategy strategy) external;
    
    function applyYieldStrategy(address user, address token) external;
}