// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ILiquidityRouter} from "../ILiquidityRouter.sol";

interface ICrossChainDCAModule {
    enum ExecutionStatus {
        Pending,
        Transferring,
        Executing,
        Completed,
        Failed,
        Cancelled
    }

    struct DCAExecution {
        address user;
        address fromToken;
        address toToken;
        uint256 amount;
        uint256 minAmountOut;
        uint256 sourceChain;
        uint256 targetChain;
        uint256 initiatedAt;
        ExecutionStatus status;
    }

    function executeCrossChainDCA(
        address user,
        address fromToken,
        address toToken,
        uint256 amount,
        uint256 minAmountOut,
        uint256 targetChainId
    ) external returns (bytes32 executionId);

    function receiveAndExecuteDCA(DCAExecution calldata execution, bytes calldata swapData) external;

    function cancelDCA(bytes32 executionId) external;

    function setChainGasCost(uint256 chainId, uint256 gasCost) external;

    function getExecution(bytes32 executionId) external view returns (DCAExecution memory execution);

    function getLocalQuote(address fromToken, address toToken, uint256 amount)
        external
        returns (ILiquidityRouter.LiquidityQuote memory);
}

