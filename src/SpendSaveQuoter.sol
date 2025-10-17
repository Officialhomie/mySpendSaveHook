// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V4Quoter} from "lib/v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "lib/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PathKey} from "lib/v4-periphery/src/libraries/PathKey.sol";
import {Currency} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {SpendSaveStorage} from "./SpendSaveStorage.sol";

/**
 * @title SpendSaveQuoter
 * @notice Savings impact preview and gas estimation using V4Quoter
 */
contract SpendSaveQuoter {
    
    SpendSaveStorage public immutable storage_;
    V4Quoter public immutable quoter;

    constructor(address _storage, address _quoter) {
        storage_ = SpendSaveStorage(_storage);
        quoter = V4Quoter(_quoter);
    }

    /**
     * @notice Preview savings impact on swap
     */
    function previewSavingsImpact(
        PoolKey memory poolKey,
        bool zeroForOne,
        uint128 amountIn,
        uint256 savingsPercentage
    ) external returns (
        uint256 swapOutput,
        uint256 savedAmount,
        uint256 netOutput
    ) {
        // Get quote for full swap amount
        (uint256 fullSwapOutput, ) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                exactAmount: amountIn,
                hookData: ""
            })
        );

        // Calculate savings amount
        savedAmount = (uint256(uint128(amountIn)) * savingsPercentage) / 10000;
        uint128 adjustedInput = amountIn - uint128(savedAmount);

        // Handle case where all input is saved (100% savings)
        if (adjustedInput == 0) {
            return (fullSwapOutput, savedAmount, 0);
        }

        // Get quote for adjusted amount
        (uint256 adjustedSwapOutput, ) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                exactAmount: adjustedInput,
                hookData: ""
            })
        );

        swapOutput = fullSwapOutput;
        netOutput = adjustedSwapOutput;

        return (swapOutput, savedAmount, netOutput);
    }

    /**
     * @notice Get DCA execution quote
     */
    function getDCAQuote(
        PoolKey memory poolKey,
        bool zeroForOne,
        uint128 amountIn
    ) external returns (uint256 amountOut, uint256 gasEstimate) {
        // Handle zero amount gracefully
        if (amountIn == 0) {
            return (0, 50000); // Return 0 output with base gas estimate
        }

        (uint256 quoteOutput, uint256 gas) = quoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey,
                zeroForOne: zeroForOne,
                exactAmount: amountIn,
                hookData: ""
            })
        );

        amountOut = quoteOutput;
        gasEstimate = gas + 50000; // Add DCA execution overhead

        return (amountOut, gasEstimate);
    }

    /**
     * @notice Preview multi-hop routing using real V4Quoter
     */
    function previewMultiHopRouting(
        Currency startingCurrency,
        PathKey[] memory path,
        uint128 amountIn
    ) external returns (uint256 amountOut, uint256 gasEstimate) {
        require(path.length > 0, "Empty path");
        require(amountIn > 0, "Zero amount");

        // Use V4Quoter for accurate multi-hop pricing with production struct
        (amountOut, gasEstimate) = quoter.quoteExactInput(
            IV4Quoter.QuoteExactParams({
                exactCurrency: startingCurrency,
                path: path,
                exactAmount: amountIn
            })
        );

        return (amountOut, gasEstimate);
    }
}