// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../SpendSaveStorage.sol";
import "./ISpendSaveModule.sol";

// Slippage Control Module Interface
interface ISlippageControlModule is ISpendSaveModule {
    function setSlippageTolerance(address user, uint256 basisPoints) external;
    
    function setTokenSlippageTolerance(address user, address token, uint256 basisPoints) external;
    
    function setSlippageAction(address user, SpendSaveStorage.SlippageAction action) external;
    
    function getMinimumAmountOut(
        address user,
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 customSlippageTolerance
    ) external view returns (uint256);
    
    function handleSlippageExceeded(
        address user,
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 receivedAmount,
        uint256 expectedMinimum
    ) external returns (bool);
}