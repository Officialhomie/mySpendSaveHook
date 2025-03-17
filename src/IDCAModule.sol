// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import "./SpendSaveStorage.sol";
import "./ISpendSaveModule.sol";

// DCA Module Interface
interface IDCAModule is ISpendSaveModule {
    function enableDCA(address user, address targetToken, bool enabled) external;
    
    function setDCATickStrategy(
        address user,
        int24 tickDelta,
        uint256 tickExpiryTime,
        bool onlyImprovePrice,
        int24 minTickImprovement,
        bool dynamicSizing
    ) external;
    
    function queueDCAFromSwap(
        address user,
        address fromToken,
        SpendSaveStorage.SwapContext memory context
    ) external;
    
    function queueDCAExecution(
        address user,
        address fromToken,
        address toToken,
        uint256 amount,
        PoolKey memory poolKey,
        int24 currentTick,
        uint256 customSlippageTolerance
    ) external;
    
    function executeDCA(
        address user,
        address fromToken,
        uint256 amount,
        uint256 customSlippageTolerance
    ) external;
    
    function processQueuedDCAs(address user, PoolKey memory poolKey) external;
    
    function getCurrentTick(PoolKey memory poolKey) external returns (int24);
}







