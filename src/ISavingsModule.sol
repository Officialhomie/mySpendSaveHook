// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SpendSaveStorage.sol";
import "./ISpendSaveModule.sol";

// Savings Module Interface
interface ISavingsModule is ISpendSaveModule {
    function processSavingsFromOutput(
        address user,
        address outputToken,
        uint256 outputAmount,
        SpendSaveStorage.SwapContext memory context
    ) external;
    
    function processSavingsToSpecificToken(
        address user,
        address outputToken,
        uint256 outputAmount,
        SpendSaveStorage.SwapContext memory context
    ) external;
    
    function processSavings(
        address user,
        address token,
        uint256 amount
    ) external;
    
    function withdrawSavings(
        address user,
        address token,
        uint256 amount
    ) external;

    function processInputSavingsAfterSwap(
        address user,
        address token,
        uint256 amount
    ) external;
    
    function depositSavings(
        address user,
        address token,
        uint256 amount
    ) external;
    
    function setWithdrawalTimelock(address user, uint256 timelock) external;
}