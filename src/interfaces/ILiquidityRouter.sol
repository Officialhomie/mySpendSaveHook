// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title ILiquidityRouter
 * @notice Interface for retrieving multi-chain liquidity quotes and best execution routing.
 */
interface ILiquidityRouter {
    struct LiquidityQuote {
        uint256 chainId;
        uint256 expectedOutput;
        uint256 priceImpactBps;
        uint256 gasEstimate;
    }

    function getBestExecutionChain(address tokenIn, address tokenOut, uint256 amountIn)
        external
        returns (LiquidityQuote memory);
}

