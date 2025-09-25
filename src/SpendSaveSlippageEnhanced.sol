// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SlippageCheck} from "lib/v4-periphery/src/libraries/SlippageCheck.sol";
import {BalanceDelta} from "lib/v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {SpendSaveStorage} from "./SpendSaveStorage.sol";

/**
 * @title SpendSaveSlippageEnhanced  
 * @notice Enhanced slippage protection using V4 SlippageCheck library
 */
contract SpendSaveSlippageEnhanced {
    using SlippageCheck for BalanceDelta;

    SpendSaveStorage public immutable storage_;

    // Enhanced slippage protection constants
    uint256 public constant MAX_SLIPPAGE_BPS = 500; // 5%
    uint256 public constant DEFAULT_SLIPPAGE_BPS = 50; // 0.5%

    constructor(address _storage) {
        storage_ = SpendSaveStorage(_storage);
    }

    /**
     * @notice Validate slippage for swap operations
     */
    function validateSwapSlippage(
        BalanceDelta delta,
        uint128 amountInMax,
        uint128 amountOutMin
    ) external pure {
        // Use V4's SlippageCheck library for validation
        delta.validateMaxIn(amountInMax, 0);
        delta.validateMinOut(0, amountOutMin);
    }

    /**
     * @notice Calculate dynamic slippage based on market conditions
     */
    function calculateDynamicSlippage(
        address token,
        uint256 amount,
        uint256 baseSlippageBps
    ) external view returns (uint256 adjustedSlippageBps) {
        adjustedSlippageBps = baseSlippageBps;
        
        // Factor 1: Trade size impact
        adjustedSlippageBps = _adjustForTradeSize(adjustedSlippageBps, amount);
        
        // Factor 2: Token-specific volatility
        adjustedSlippageBps = _adjustForTokenVolatility(adjustedSlippageBps, token);
        
        // Factor 3: Market conditions (time-based)
        adjustedSlippageBps = _adjustForMarketConditions(adjustedSlippageBps);
        
        // Factor 4: User's historical slippage tolerance
        adjustedSlippageBps = _adjustForUserHistory(adjustedSlippageBps, msg.sender);
        
        // Ensure within bounds
        if (adjustedSlippageBps > MAX_SLIPPAGE_BPS) {
            adjustedSlippageBps = MAX_SLIPPAGE_BPS;
        }
        if (adjustedSlippageBps < DEFAULT_SLIPPAGE_BPS) {
            adjustedSlippageBps = DEFAULT_SLIPPAGE_BPS;
        }
        
        return adjustedSlippageBps;
    }
    
    /**
     * @notice Adjust slippage based on trade size
     */
    function _adjustForTradeSize(uint256 baseSlippage, uint256 amount) internal pure returns (uint256) {
        // Progressive slippage adjustment based on trade size
        if (amount >= 100000e18) { // Very large trades (100k tokens)
            return (baseSlippage * 200) / 100; // 2x slippage
        } else if (amount >= 50000e18) { // Large trades (50k tokens)
            return (baseSlippage * 175) / 100; // 1.75x slippage
        } else if (amount >= 10000e18) { // Medium trades (10k tokens)
            return (baseSlippage * 150) / 100; // 1.5x slippage
        } else if (amount >= 1000e18) { // Small-medium trades (1k tokens)
            return (baseSlippage * 125) / 100; // 1.25x slippage
        }
        
        return baseSlippage; // No adjustment for small trades
    }
    
    /**
     * @notice Adjust slippage based on token characteristics
     */
    function _adjustForTokenVolatility(uint256 baseSlippage, address token) internal view returns (uint256) {
        // Check if token is a known stable token (lower volatility)
        if (_isStableToken(token)) {
            return (baseSlippage * 80) / 100; // 20% reduction for stable tokens
        }
        
        // Check if token is a known high-volatility token
        if (_isVolatileToken(token)) {
            return (baseSlippage * 150) / 100; // 50% increase for volatile tokens
        }
        
        return baseSlippage; // No adjustment for normal tokens
    }
    
    /**
     * @notice Adjust slippage based on market conditions
     */
    function _adjustForMarketConditions(uint256 baseSlippage) internal view returns (uint256) {
        // Adjust based on time of day (simplified approach)
        // In production, this would use volatility indices or market data
        uint256 hour = (block.timestamp / 3600) % 24;
        
        // Higher volatility during market open/close hours (simplified)
        if (hour >= 13 && hour <= 15) { // 1-3 PM UTC (market active hours)
            return (baseSlippage * 120) / 100; // 20% increase during active hours
        } else if (hour >= 0 && hour <= 6) { // Late night/early morning
            return (baseSlippage * 110) / 100; // 10% increase during low liquidity
        }
        
        return baseSlippage;
    }
    
    /**
     * @notice Adjust slippage based on user's historical performance
     */
    function _adjustForUserHistory(uint256 baseSlippage, address user) internal view returns (uint256) {
        // Get user's preferred slippage tolerance from storage
        uint256 userTolerance = storage_.userSlippageTolerance(user);
        
        if (userTolerance > 0) {
            // Use user's preference as a factor
            return (baseSlippage + userTolerance) / 2; // Average with user preference
        }
        
        return baseSlippage;
    }
    
    /**
     * @notice Check if token is considered stable
     */
    function _isStableToken(address token) internal pure returns (bool) {
        // Base network stable tokens
        return (
            token == address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913) || // USDC
            token == address(0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA) || // USDbC  
            token == address(0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb)    // DAI
        );
    }
    
    /**
     * @notice Check if token is considered high volatility
     */
    function _isVolatileToken(address token) internal pure returns (bool) {
        // This would be maintained as a list of known volatile tokens
        // For now, treating non-stable, non-ETH tokens as potentially volatile
        return !_isStableToken(token) && 
               token != address(0x4200000000000000000000000000000000000006); // Not WETH
    }
}