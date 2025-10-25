// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StateView} from "lib/v4-periphery/src/lens/StateView.sol";
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "lib/v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {SpendSaveStorage} from "./SpendSaveStorage.sol";

/**
 * @title SpendSaveAnalytics
 * @notice Real-time analytics and portfolio tracking using StateView
 */
contract SpendSaveAnalytics {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    SpendSaveStorage public immutable storage_;
    IPoolManager public immutable poolManager;
    StateView public immutable stateView;

    constructor(address _storage, address _stateView) {
        storage_ = SpendSaveStorage(_storage);
        poolManager = IPoolManager(storage_.poolManager());
        stateView = StateView(_stateView);
    }

    /**
     * @notice Get user portfolio summary
     */
    function getUserPortfolio(address user)
        external
        returns (address[] memory tokens, uint256[] memory savings, uint256[] memory dcaAmounts, uint256 totalValueUSD)
    {
        // Get user's savings tokens from storage
        address[] memory userTokens = storage_.getUserSavingsTokens(user);

        if (userTokens.length == 0) {
            return (new address[](0), new uint256[](0), new uint256[](0), 0);
        }

        tokens = userTokens;
        savings = new uint256[](userTokens.length);
        dcaAmounts = new uint256[](userTokens.length);
        totalValueUSD = 0;

        // Aggregate savings data for each token
        for (uint256 i = 0; i < userTokens.length; i++) {
            address token = userTokens[i];

            // Get savings balance
            savings[i] = storage_.savings(user, token);

            // Get DCA queue amounts for this token
            dcaAmounts[i] = _getUserDCAAmountForToken(user, token);

            // Calculate USD value (simplified - would use price oracles in production)
            totalValueUSD += _estimateTokenValueUSD(token, savings[i] + dcaAmounts[i]);
        }

        return (tokens, savings, dcaAmounts, totalValueUSD);
    }

    /**
     * @notice Get total DCA amounts for a user and specific token
     */
    function _getUserDCAAmountForToken(address user, address token) internal view returns (uint256 totalDCAAmount) {
        // Get user's DCA queue length
        uint256 queueLength = storage_.getDcaQueueLength(user);

        for (uint256 i = 0; i < queueLength; i++) {
            try storage_.getDcaQueueItem(user, i) returns (
                address fromToken,
                address toToken,
                uint256 amount,
                int24, // executionTick
                uint256, // deadline
                bool executed,
                uint256 // customSlippageTolerance
            ) {
                // Sum up pending DCA amounts for this token (both from and to)
                if (!executed && block.timestamp < storage_.getDcaQueue(user).executionTimes[i]) {
                    if (fromToken == token || toToken == token) {
                        totalDCAAmount += amount;
                    }
                }
            } catch {
                // Skip invalid queue items
                continue;
            }
        }

        return totalDCAAmount;
    }

    /**
     * @notice Get detailed pool analytics using StateView
     * @param poolKey The pool to analyze
     * @return sqrtPriceX96 Current pool price
     * @return tick Current tick
     * @return liquidity Total active liquidity
     * @return feeGrowthGlobal0 Total fee accumulation for token0
     * @return feeGrowthGlobal1 Total fee accumulation for token1
     */
    function getPoolAnalytics(PoolKey memory poolKey)
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint128 liquidity,
            uint256 feeGrowthGlobal0,
            uint256 feeGrowthGlobal1
        )
    {
        PoolId poolId = poolKey.toId();

        // Get comprehensive pool state using StateView
        (sqrtPriceX96, tick,,) = stateView.getSlot0(poolId);
        liquidity = stateView.getLiquidity(poolId);
        (feeGrowthGlobal0, feeGrowthGlobal1) = stateView.getFeeGrowthGlobals(poolId);

        return (sqrtPriceX96, tick, liquidity, feeGrowthGlobal0, feeGrowthGlobal1);
    }

    /**
     * @notice Get tick liquidity information around current price
     * @param poolKey The pool to analyze
     * @param tickRange Number of ticks above and below current tick to analyze
     * @return currentTick The current pool tick
     * @return ticks Array of tick values analyzed
     * @return liquidityGross Array of gross liquidity at each tick
     * @return liquidityNet Array of net liquidity at each tick
     */
    function getTickLiquidityDistribution(PoolKey memory poolKey, uint256 tickRange)
        external
        view
        returns (int24 currentTick, int24[] memory ticks, uint128[] memory liquidityGross, int128[] memory liquidityNet)
    {
        PoolId poolId = poolKey.toId();

        // Get current tick
        (, currentTick,,) = stateView.getSlot0(poolId);

        // Calculate tick spacing for the pool
        int24 tickSpacing = poolKey.tickSpacing;

        // Prepare arrays for tick data
        uint256 numTicks = tickRange * 2 + 1; // Range above + range below + current
        ticks = new int24[](numTicks);
        liquidityGross = new uint128[](numTicks);
        liquidityNet = new int128[](numTicks);

        // Get liquidity data for each tick in range
        for (uint256 i = 0; i < numTicks; i++) {
            int24 targetTick = currentTick + int24(int256(i - tickRange)) * tickSpacing;
            ticks[i] = targetTick;

            try stateView.getTickLiquidity(poolId, targetTick) returns (uint128 gross, int128 net) {
                liquidityGross[i] = gross;
                liquidityNet[i] = net;
            } catch {
                // Tick not initialized, leave as zero
                liquidityGross[i] = 0;
                liquidityNet[i] = 0;
            }
        }

        return (currentTick, ticks, liquidityGross, liquidityNet);
    }

    /**
     * @notice Estimate token value in USD using real V4 pool data
     * @dev Production implementation using V4 pool pricing with USDC as base currency
     * @param token The token address to price
     * @param amount The token amount to value
     * @return valueUSD The estimated USD value scaled to 1e6 (USDC decimals)
     */
    function _estimateTokenValueUSD(address token, uint256 amount) internal returns (uint256 valueUSD) {
        if (amount == 0) return 0;

        // Base network USD stablecoins (1:1 USD pegged)
        address USDC = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        address USDbC = address(0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA);
        address DAI = address(0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb);

        // Direct USD value for stablecoins
        if (token == USDC) {
            return amount; // USDC has 6 decimals, matches our output format
        }
        if (token == USDbC) {
            return amount; // USDbC has 6 decimals
        }
        if (token == DAI) {
            return amount / 1e12; // DAI has 18 decimals, convert to 6 decimal USDC equivalent
        }

        // For other tokens, get real-time price through V4 pools
        return _getPriceFromV4Pool(token, amount, USDC);
    }

    /**
     * @notice Get token price using real V4 pool data
     * @param token The token to price
     * @param amount The amount to value
     * @param baseToken The base currency (USDC)
     * @return valueUSD The USD value in base token units
     */
    function _getPriceFromV4Pool(address token, uint256 amount, address baseToken)
        internal
        returns (uint256 valueUSD)
    {
        // Try direct pool first (token/USDC)
        uint256 directPrice = _getDirectPoolPrice(token, amount, baseToken);
        if (directPrice > 0) {
            return directPrice;
        }

        // Try indirect pricing through WETH if direct pool doesn't exist
        address WETH = address(0x4200000000000000000000000000000000000006);
        if (token != WETH) {
            return _getIndirectPrice(token, amount, WETH, baseToken);
        }

        // If all pricing methods fail, return 0 (no price available)
        return 0;
    }

    /**
     * @notice Get price from direct V4 pool (token/USDC)
     * @dev Uses StateView for gas-efficient pool state reading
     */
    function _getDirectPoolPrice(address token, uint256 amount, address baseToken) internal returns (uint256) {
        try storage_.getPoolKey(token, baseToken) returns (PoolKey memory poolKey) {
            PoolId poolId = poolKey.toId();

            // Get pool state using StateView for optimized access
            (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = stateView.getSlot0(poolId);

            if (sqrtPriceX96 == 0) return 0; // Pool doesn't exist

            // Verify pool has sufficient liquidity for reliable pricing
            uint128 liquidity = stateView.getLiquidity(poolId);
            if (liquidity < 10000) return 0; // Minimum liquidity threshold for reliable pricing

            // Calculate price based on current pool state
            return _calculatePriceFromSqrtPrice(token, baseToken, amount, sqrtPriceX96);
        } catch {
            return 0; // Pool creation failed or doesn't exist
        }
    }

    /**
     * @notice Get price through indirect routing (token -> WETH -> USDC)
     * @dev Uses StateView for optimized multi-hop pricing
     */
    function _getIndirectPrice(address token, uint256 amount, address intermediateToken, address baseToken)
        internal
        returns (uint256)
    {
        // Step 1: Get token -> WETH conversion rate
        try storage_.getPoolKey(token, intermediateToken) returns (PoolKey memory poolKey1) {
            PoolId poolId1 = poolKey1.toId();

            (uint160 sqrtPrice1,,,) = stateView.getSlot0(poolId1);
            if (sqrtPrice1 == 0) return 0;

            uint128 liquidity1 = stateView.getLiquidity(poolId1);
            if (liquidity1 < 10000) return 0;

            uint256 wethAmount = _calculatePriceFromSqrtPrice(token, intermediateToken, amount, sqrtPrice1);
            if (wethAmount == 0) return 0;

            // Step 2: Get WETH -> USDC conversion rate
            return _getDirectPoolPrice(intermediateToken, wethAmount, baseToken);
        } catch {
            return 0; // Indirect routing failed
        }
    }

    /**
     * @notice Calculate actual price from V4 pool sqrtPriceX96
     */
    function _calculatePriceFromSqrtPrice(address token0, address token1, uint256 amount, uint160 sqrtPriceX96)
        internal
        view
        returns (uint256)
    {
        if (sqrtPriceX96 == 0 || amount == 0) return 0;

        // Determine token order in the pool
        bool zeroForOne = token0 < token1;

        // Get token decimals for proper scaling
        uint8 decimals0 = _getTokenDecimals(token0);
        uint8 decimals1 = _getTokenDecimals(token1);

        // Convert sqrtPriceX96 to price ratio
        // price = (sqrtPriceX96 / 2^96)^2
        uint256 numerator = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);

        // Apply the price to the amount with correct decimal scaling
        if (zeroForOne) {
            // token0 -> token1
            uint256 scaledAmount = amount * (10 ** decimals1);
            return (scaledAmount * numerator) >> (192 + decimals0 * 1); // Adjust for fixed point and decimals
        } else {
            // token1 -> token0
            uint256 scaledAmount = amount * (10 ** decimals0);
            return (scaledAmount * (1 << 192)) / (numerator * (10 ** decimals1));
        }
    }

    /**
     * @notice Get token decimals with known Base network tokens
     */
    function _getTokenDecimals(address token) internal view returns (uint8) {
        // Base network known token decimals
        if (token == address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)) return 6; // USDC
        if (token == address(0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA)) return 6; // USDbC
        if (token == address(0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb)) return 18; // DAI
        if (token == address(0x4200000000000000000000000000000000000006)) return 18; // WETH
        if (token == address(0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22)) return 18; // cbETH

        // Query decimals from token contract
        return _queryTokenDecimals(token);
    }

    /**
     * @notice Query token decimals from contract with error handling
     */
    function _queryTokenDecimals(address token) internal view returns (uint8) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));

        if (success && data.length >= 32) {
            uint8 decimals = abi.decode(data, (uint8));
            // Validate reasonable decimal range
            if (decimals <= 18) {
                return decimals;
            }
        }

        // If decimals query fails, assume standard 18 decimals for ERC20
        return 18;
    }
}
