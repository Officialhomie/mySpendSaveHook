// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "lib/v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "lib/v4-periphery/lib/v4-core/src/types/PoolId.sol";
import {TickMath} from "lib/v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "lib/v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "lib/v4-periphery/lib/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "lib/v4-periphery/lib/v4-core/src/libraries/FixedPoint96.sol";
import {IHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {PositionInfo, PositionInfoLibrary} from "lib/v4-periphery/src/libraries/PositionInfoLibrary.sol";
import {LiquidityAmounts} from "lib/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IMulticall_v4} from "lib/v4-periphery/src/interfaces/IMulticall_v4.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {SpendSaveStorage} from "./SpendSaveStorage.sol";

/**
 * @title SpendSaveLiquidityManager
 * @notice Phase 2 Enhancement: Converts user savings into Uniswap V4 LP positions automatically
 * @dev Integrates with PositionManager to provide:
 *      - Auto-LP conversion for accumulated savings
 *      - ERC-721 NFT representation of LP positions  
 *      - Fee collection and compounding
 *      - Position management and rebalancing
 * 
 * Key Benefits:
 * - Users earn LP fees on their savings
 * - Positions are represented as tradeable NFTs
 * - Automated position management
 * - Gas-efficient batch operations via multicall
 * 
 * @author SpendSave Protocol Team
 */
contract SpendSaveLiquidityManager is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using PositionInfoLibrary for PositionInfo;
    using StateLibrary for IPoolManager;

    // ==================== EVENTS ====================

    /// @notice Emitted when user savings are converted to LP position
    event SavingsConvertedToLP(
        address indexed user,
        uint256 indexed tokenId,
        address indexed poolToken0,
        address poolToken1,
        uint256 amount0,
        uint256 amount1,
        uint128 liquidity
    );

    /// @notice Emitted when LP fees are collected and compounded
    event FeesCollected(
        address indexed user,
        uint256 indexed tokenId,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Emitted when position is rebalanced
    event PositionRebalanced(
        address indexed user,
        uint256 indexed oldTokenId,
        uint256 indexed newTokenId,
        int24 newTickLower,
        int24 newTickUpper
    );

    /// @notice Emitted when minimum amounts are initialized
    event MinAmountsInitialized();

    /// @notice Emitted when tokens are requested from storage for LP operations
    event TokensRequestedFromStorage(address indexed token, uint256 requestedAmount, uint256 actualAmount);

    // ==================== STORAGE ====================

    /// @notice Reference to SpendSave storage contract
    SpendSaveStorage public immutable storage_;

    /// @notice Reference to Uniswap V4 PositionManager
    IPositionManager public immutable positionManager;

    /// @notice Reference to Permit2 for token approvals
    IAllowanceTransfer public immutable permit2;

    /// @notice Reference to Uniswap V4 PoolManager
    IPoolManager public poolManager;

    /// @notice Hook address to use for pool keys (if applicable)
    IHooks public poolHook;

    /// @notice Mapping from user to their LP position token IDs
    mapping(address user => uint256[] tokenIds) public userPositions;

    /// @notice Mapping from token ID to user (reverse lookup)
    mapping(uint256 tokenId => address user) public positionOwner;

    /// @notice Minimum amounts required for LP conversion to prevent dust
    mapping(address token => uint256 minAmount) public minConversionAmounts;
    
    /// @notice Default minimum amount for tokens not explicitly configured
    uint256 public defaultMinAmount;

    /// @notice Default tick range for LP positions (±600 ticks = ~6% range at current price)
    int24 public constant DEFAULT_TICK_RANGE = 600;

    /// @notice Minimum liquidity threshold for position creation
    uint128 public constant MIN_LIQUIDITY = 1000;

    // ==================== CONSTRUCTOR ====================

    /**
     * @notice Initialize the SpendSaveLiquidityManager
     * @param _storage SpendSaveStorage contract address
     * @param _positionManager Uniswap V4 PositionManager address
     * @param _permit2 Permit2 contract address for token approvals
     */
    constructor(
        address _storage,
        address _positionManager,
        address _permit2
    ) {
        require(_storage != address(0), "Invalid storage address");
        require(_positionManager != address(0), "Invalid position manager address");
        require(_permit2 != address(0), "Invalid permit2 address");

        storage_ = SpendSaveStorage(_storage);
        positionManager = IPositionManager(_positionManager);
        permit2 = IAllowanceTransfer(_permit2);
        // Get poolManager from positionManager's immutable state
        poolManager = positionManager.poolManager();

        // Get hook address from storage
        // NOTE: Storage must be initialized BEFORE deploying LiquidityManager
        address hookAddr = storage_.spendSaveHook();
        require(hookAddr != address(0), "Storage not initialized - deploy LiquidityManager after storage.initialize()");
        poolHook = IHooks(hookAddr);

        // Set default minimum conversion amounts (0.01 tokens)
        // These can be updated by governance
        _setDefaultMinAmounts();
    }

    // ==================== LIQUIDITY CONVERSION FUNCTIONS ====================

    /**
     * @notice Convert user's accumulated savings into LP position
     * @param user The user whose savings to convert
     * @param token0 First token in the pair
     * @param token1 Second token in the pair  
     * @param tickLower Lower tick for LP position
     * @param tickUpper Upper tick for LP position
     * @param deadline Deadline for the transaction
     * @return tokenId The NFT token ID representing the LP position
     * @return liquidity The amount of liquidity added
     */
    function convertSavingsToLP(
        address user,
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        uint256 deadline
    ) external nonReentrant returns (uint256 tokenId, uint128 liquidity) {
        require(user != address(0), "Invalid user address");
        require(block.timestamp <= deadline, "Transaction deadline passed");
        
        // Validate tick range
        require(tickLower < tickUpper, "Invalid tick range");
        require(tickUpper - tickLower >= DEFAULT_TICK_RANGE / 2, "Tick range too narrow");

        // Get user savings amounts
        uint256 amount0 = storage_.savings(user, token0);
        uint256 amount1 = storage_.savings(user, token1);

        // Check minimum amounts (use defaultMinAmount if token not configured)
        uint256 minAmount0 = minConversionAmounts[token0] == 0 ? defaultMinAmount : minConversionAmounts[token0];
        uint256 minAmount1 = minConversionAmounts[token1] == 0 ? defaultMinAmount : minConversionAmounts[token1];

        require(amount0 >= minAmount0, "Insufficient token0 amount");
        require(amount1 >= minAmount1, "Insufficient token1 amount");

        // Create pool key
        PoolKey memory poolKey = _createPoolKey(token0, token1);

        // Calculate optimal liquidity amounts
        (uint256 optimalAmount0, uint256 optimalAmount1, uint128 liquidityToAdd) =
            _calculateOptimalAmounts(poolKey, amount0, amount1, tickLower, tickUpper);

        // Better error messages for debugging
        if (liquidityToAdd == 0) {
            if (optimalAmount0 == 0) {
                revert("Insufficient token0 amount");
            }
            if (optimalAmount1 == 0) {
                revert("Insufficient token1 amount");
            }
        }
        require(liquidityToAdd >= MIN_LIQUIDITY, "Insufficient liquidity");

        // Transfer tokens from storage to this contract
        _transferSavingsForLP(user, token0, token1, optimalAmount0, optimalAmount1);

        // Create LP position
        tokenId = _createLPPosition(
            poolKey,
            tickLower,
            tickUpper,
            optimalAmount0,
            optimalAmount1,
            deadline
        );

        // Update tracking
        userPositions[user].push(tokenId);
        positionOwner[tokenId] = user;

        // Update user savings (subtract converted amounts)
        _updateUserSavingsAfterConversion(user, token0, token1, optimalAmount0, optimalAmount1);

        emit SavingsConvertedToLP(
            user,
            tokenId,
            token0,
            token1,
            optimalAmount0,
            optimalAmount1,
            liquidityToAdd
        );

        return (tokenId, liquidityToAdd);
    }

    /**
     * @notice Batch convert multiple users' savings to LP positions
     * @param users Array of users
     * @param params Array of conversion parameters for each user
     * @param deadline Deadline for all transactions
     */
    function batchConvertSavingsToLP(
        address[] calldata users,
        ConversionParams[] calldata params,
        uint256 deadline
    ) external {
        require(users.length == params.length, "Array length mismatch");
        require(users.length > 0, "Empty arrays");

        for (uint256 i = 0; i < users.length; i++) {
            try this.convertSavingsToLP(
                users[i],
                params[i].token0,
                params[i].token1,
                params[i].tickLower,
                params[i].tickUpper,
                deadline
            ) returns (uint256 tokenId, uint128 liquidity) {
                // Successful conversion
                continue;
            } catch {
                // Skip failed conversions, continue with others
                continue;
            }
        }
    }

    // ==================== FEE COLLECTION FUNCTIONS ====================

    /**
     * @notice Collect fees from user's LP positions and compound them
     * @param user The user whose fees to collect
     * @return totalFees0 Total token0 fees collected
     * @return totalFees1 Total token1 fees collected
     */
    function collectAndCompoundFees(address user) 
        external 
        nonReentrant 
        returns (uint256 totalFees0, uint256 totalFees1) 
    {
        uint256[] memory tokenIds = userPositions[user];
        require(tokenIds.length > 0, "No positions found");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            (uint256 fees0, uint256 fees1) = _collectFeesFromPosition(tokenIds[i]);
            totalFees0 += fees0;
            totalFees1 += fees1;
        }

        if (totalFees0 > 0 || totalFees1 > 0) {
            // Add collected fees back to user's savings for compounding
            _addFeesToSavings(user, totalFees0, totalFees1, tokenIds[0]);
        }

        return (totalFees0, totalFees1);
    }

    // ==================== POSITION MANAGEMENT FUNCTIONS ====================

    /**
     * @notice Rebalance user's LP position to new price range
     * @param tokenId The position to rebalance
     * @param newTickLower New lower tick
     * @param newTickUpper New upper tick
     * @param deadline Transaction deadline
     * @return newTokenId The new position token ID
     */
    function rebalancePosition(
        uint256 tokenId,
        int24 newTickLower,
        int24 newTickUpper,
        uint256 deadline
    ) external nonReentrant returns (uint256 newTokenId) {
        address user = positionOwner[tokenId];
        require(user == msg.sender, "Not position owner");
        require(newTickLower < newTickUpper, "Invalid tick range");

        // Get current position info
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        uint128 currentLiquidity = positionManager.getPositionLiquidity(tokenId);
        
        require(currentLiquidity > 0, "Position has no liquidity");

        // Remove liquidity from old position
        (uint256 amount0, uint256 amount1) = _removeLiquidityFromPosition(tokenId, currentLiquidity, deadline);

        // Create new position with collected tokens
        newTokenId = _createLPPosition(
            poolKey,
            newTickLower,
            newTickUpper,
            amount0,
            amount1,
            deadline
        );

        // Update tracking
        _updatePositionTracking(user, tokenId, newTokenId);

        emit PositionRebalanced(user, tokenId, newTokenId, newTickLower, newTickUpper);

        return newTokenId;
    }

    // ==================== VIEW FUNCTIONS ====================

    /**
     * @notice Get user's LP position token IDs
     * @param user The user address
     * @return tokenIds Array of position token IDs
     */
    function getUserPositions(address user) external view returns (uint256[] memory tokenIds) {
        return userPositions[user];
    }

    /**
     * @notice Get position details for a token ID
     * @param tokenId The position token ID
     * @return poolKey The pool key
     * @return positionInfo Packed position information
     * @return liquidity Current liquidity amount
     */
    function getPositionDetails(uint256 tokenId) 
        external 
        view 
        returns (PoolKey memory poolKey, PositionInfo positionInfo, uint128 liquidity) 
    {
        (poolKey, positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        liquidity = positionManager.getPositionLiquidity(tokenId);
        return (poolKey, positionInfo, liquidity);
    }

    /**
     * @notice Calculate potential LP amounts for user's current savings
     * @param user The user address
     * @param token0 First token address
     * @param token1 Second token address
     * @param tickLower Lower tick for calculation
     * @param tickUpper Upper tick for calculation
     * @return amount0 Optimal token0 amount
     * @return amount1 Optimal token1 amount  
     * @return liquidity Estimated liquidity
     */
    function previewSavingsToLP(
        address user,
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper
    ) external view returns (uint256 amount0, uint256 amount1, uint128 liquidity) {
        uint256 savings0 = storage_.savings(user, token0);
        uint256 savings1 = storage_.savings(user, token1);
        
        if (savings0 == 0 && savings1 == 0) {
            return (0, 0, 0);
        }

        PoolKey memory poolKey = _createPoolKey(token0, token1);
        return _calculateOptimalAmounts(poolKey, savings0, savings1, tickLower, tickUpper);
    }

    // ==================== INTERNAL FUNCTIONS ====================

    /**
     * @notice Create pool key ensuring proper token ordering
     * @dev For V4, we need to match the exact pool that was initialized
     * Uses the stored poolHook address to match existing SpendSave pools
     */
    function _createPoolKey(address token0, address token1) internal view returns (PoolKey memory) {
        // Ensure proper token ordering
        if (token0 > token1) {
            (token0, token1) = (token1, token0);
        }

        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000, // 0.3% fee tier
            tickSpacing: 60,
            hooks: poolHook // Use the configured hook (SpendSaveHook or zero address)
        });
    }

    /**
     * @notice Calculate optimal amounts for LP position using production Uniswap V4 patterns
     * @dev Uses the same approach as PositionManager for price-aware liquidity calculation
     */
    function _calculateOptimalAmounts(
        PoolKey memory poolKey,
        uint256 maxAmount0,
        uint256 maxAmount1,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint256 amount0, uint256 amount1, uint128 liquidity) {
        // Get current pool state - same as PositionManager production code
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());
        
        // Calculate sqrt prices for tick range
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);
        
        // Use production pattern: getLiquidityForAmounts handles price-aware logic automatically
        // This is exactly how PositionManager calculates optimal liquidity
        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceLowerX96,
            sqrtPriceUpperX96,
            maxAmount0,
            maxAmount1
        );
        
        // Calculate actual required amounts for this liquidity
        // This ensures we know exactly how much of each token is needed
        (amount0, amount1) = _getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtPriceLowerX96,
            sqrtPriceUpperX96,
            liquidity
        );

        return (amount0, amount1, liquidity);
    }
    
    /**
     * @notice Calculate token amounts needed for given liquidity
     * @dev Production implementation matching LiquidityAmounts library pattern
     */
    function _getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            // Price below range - only token0 needed
            amount0 = _getAmount0ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            // Price in range - both tokens needed
            amount0 = _getAmount0ForLiquidity(sqrtPriceX96, sqrtPriceBX96, liquidity);
            amount1 = _getAmount1ForLiquidity(sqrtPriceAX96, sqrtPriceX96, liquidity);
        } else {
            // Price above range - only token1 needed
            amount1 = _getAmount1ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity);
        }
    }
    
    /**
     * @notice Calculate amount0 for given liquidity
     */
    function _getAmount0ForLiquidity(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount0) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        
        return FullMath.mulDiv(
            uint256(liquidity) << FixedPoint96.RESOLUTION,
            sqrtPriceBX96 - sqrtPriceAX96,
            sqrtPriceBX96
        ) / sqrtPriceAX96;
    }
    
    /**
     * @notice Calculate amount1 for given liquidity  
     */
    function _getAmount1ForLiquidity(
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint128 liquidity
    ) internal pure returns (uint256 amount1) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        
        return FullMath.mulDiv(liquidity, sqrtPriceBX96 - sqrtPriceAX96, FixedPoint96.Q96);
    }

    /**
     * @notice Transfer savings from storage for LP conversion
     */
    function _transferSavingsForLP(
        address user,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) internal {
        // Validate user has sufficient savings in storage
        require(storage_.savings(user, token0) >= amount0, "Insufficient token0 savings");
        require(storage_.savings(user, token1) >= amount1, "Insufficient token1 savings");
        
        // Decrease user's savings in storage (this is the real transfer from savings)
        // Only decrease if amount > 0 (pool might be outside range needing only one token)
        if (amount0 > 0) {
            storage_.decreaseSavings(user, token0, amount0);
            // Request tokens from storage contract for LP operations
            _requestTokensFromStorage(token0, amount0);
        }

        if (amount1 > 0) {
            storage_.decreaseSavings(user, token1, amount1);
            // Request tokens from storage contract for LP operations
            _requestTokensFromStorage(token1, amount1);
        }
    }
    
    /**
     * @notice Request tokens from storage contract for LP operations
     * @dev Production implementation with proper authorization and error handling
     */
    function _requestTokensFromStorage(address token, uint256 amount) internal {
        require(token != address(0), "Invalid token address");
        require(amount > 0, "Invalid amount");
        
        // Check if storage contract has sufficient balance
        uint256 storageBalance = IERC20(token).balanceOf(address(storage_));
        require(storageBalance >= amount, "Insufficient storage balance");
        
        // Record balance before transfer
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        
        // Use the storage contract's release function for authorized operations
        try storage_.releaseTokensForLP(token, amount, address(this)) {
            // Verify the transfer was successful
            uint256 balanceAfter = IERC20(token).balanceOf(address(this));
            require(balanceAfter >= balanceBefore + amount, "Token transfer failed");
            
            emit TokensRequestedFromStorage(token, amount, balanceAfter - balanceBefore);
        } catch Error(string memory reason) {
            revert(string(abi.encodePacked("Token release failed: ", reason)));
        } catch {
            revert("Token release failed: unknown error");
        }
    }

    /**
     * @notice Create LP position through PositionManager
     * @dev Uses V4 Periphery pattern: MINT_POSITION + CLOSE_CURRENCY (x2)
     */
    function _createLPPosition(
        PoolKey memory poolKey,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1,
        uint256 deadline
    ) internal returns (uint256 tokenId) {
        // Calculate liquidity from amounts
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolKey.toId());
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            sqrtPriceLowerX96,
            sqrtPriceUpperX96,
            amount0,
            amount1
        );

        // Approve tokens for PositionManager via Permit2
        // PositionManager uses Permit2 for token transfers
        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);

        // First approve Permit2 (if not already approved)
        if (IERC20(token0).allowance(address(this), address(permit2)) < amount0) {
            IERC20(token0).approve(address(permit2), type(uint256).max);
        }
        if (IERC20(token1).allowance(address(this), address(permit2)) < amount1) {
            IERC20(token1).approve(address(permit2), type(uint256).max);
        }

        // Then approve PositionManager through Permit2
        permit2.approve(
            token0,
            address(positionManager),
            type(uint160).max,
            type(uint48).max
        );
        permit2.approve(
            token1,
            address(positionManager),
            type(uint160).max,
            type(uint48).max
        );

        // Build V4 action sequence: MINT_POSITION + CLOSE_CURRENCY (x2)
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.CLOSE_CURRENCY)
        );

        bytes[] memory params = new bytes[](3);

        // Action 1: MINT_POSITION with 8 parameters (V4 format)
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,              // Use liquidity, not amounts
            type(uint128).max,      // amount0Max (max slippage)
            type(uint128).max,      // amount1Max (max slippage)
            address(this),          // recipient (this contract receives NFT)
            bytes("")               // hookData
        );

        // Action 2: CLOSE_CURRENCY for token0
        params[1] = abi.encode(poolKey.currency0);

        // Action 3: CLOSE_CURRENCY for token1
        params[2] = abi.encode(poolKey.currency1);

        // Execute position creation via PositionManager
        positionManager.modifyLiquidities(abi.encode(actions, params), deadline);

        // Get the token ID (PositionManager increments nextTokenId after minting)
        tokenId = positionManager.nextTokenId() - 1;

        return tokenId;
    }

    /**
     * @notice Update user savings after LP conversion
     */
    function _updateUserSavingsAfterConversion(
        address user,
        address token0,
        address token1,
        uint256 amount0Used,
        uint256 amount1Used
    ) internal {
        // Reduce user's savings by the amounts used for LP
        // This would integrate with SpendSaveStorage
        // storage_.reduceSavings(user, token0, amount0Used);
        // storage_.reduceSavings(user, token1, amount1Used);
    }

    /**
     * @notice Collect fees from a specific position using PRODUCTION V4 periphery patterns
     * @dev Based on actual V4 periphery getCollectEncoded() and PositionManager implementation
     * Uses DECREASE_LIQUIDITY with 0 liquidity to collect fees only
     */
    function _collectFeesFromPosition(uint256 tokenId) internal returns (uint256 fees0, uint256 fees1) {
        // Get position information
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        
        // Record balances before fee collection
        uint256 balance0Before = Currency.unwrap(poolKey.currency0) != address(0) ? 
                                IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(this)) : 0;
        uint256 balance1Before = Currency.unwrap(poolKey.currency1) != address(0) ?
                                IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(this)) : 0;
        
        // Build actions array: DECREASE_LIQUIDITY + 2x CLOSE_CURRENCY (production pattern)
        // Each action must be encoded as uint8
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.CLOSE_CURRENCY)
        );
        
        bytes[] memory params = new bytes[](3);
        
        // Action 1: DECREASE_LIQUIDITY with 0 liquidity (collect fees only)
        // This is the EXACT pattern from V4 periphery getCollectEncoded()
        params[0] = abi.encode(
            tokenId,
            uint128(0), // liquidity to decrease = 0 (fees only)
            uint128(0), // amount0Min = 0 (for fee collection)
            uint128(0), // amount1Min = 0 (for fee collection)  
            bytes("")   // empty hookData
        );
        
        // Action 2: CLOSE_CURRENCY for currency0
        params[1] = abi.encode(poolKey.currency0);
        
        // Action 3: CLOSE_CURRENCY for currency1
        params[2] = abi.encode(poolKey.currency1);

        // Execute using production PositionManager pattern
        // Must use modifyLiquidities (not WithoutUnlock) to unlock the pool manager
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);

        // Calculate collected fees from balance changes (production verification method)
        fees0 = Currency.unwrap(poolKey.currency0) != address(0) ? 
                IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(this)) - balance0Before : 0;
        fees1 = Currency.unwrap(poolKey.currency1) != address(0) ?
                IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(this)) - balance1Before : 0;
        
        return (fees0, fees1);
    }

    /**
     * @notice Add collected fees back to user savings
     */
    function _addFeesToSavings(address user, uint256 fees0, uint256 fees1, uint256 tokenId) internal {
        if (fees0 > 0 || fees1 > 0) {
            (PoolKey memory poolKey,) = positionManager.getPoolAndPositionInfo(tokenId);
            
            address token0 = Currency.unwrap(poolKey.currency0);
            address token1 = Currency.unwrap(poolKey.currency1);
            
            // Add fees to user's savings for compounding
            if (fees0 > 0) {
                storage_.increaseSavings(user, token0, fees0);
                
                // Track the user's token if not already tracked
                storage_.addUserSavingsToken(user, token0);
            }
            
            if (fees1 > 0) {
                storage_.increaseSavings(user, token1, fees1);
                
                // Track the user's token if not already tracked
                storage_.addUserSavingsToken(user, token1);
            }
        }
    }

    /**
     * @notice Remove liquidity from position using PRODUCTION V4 periphery patterns
     * @dev Based on actual V4 periphery DECREASE_LIQUIDITY implementation
     */
    function _removeLiquidityFromPosition(
        uint256 tokenId,
        uint128 liquidity,
        uint256 deadline
    ) internal returns (uint256 amount0, uint256 amount1) {
        require(liquidity > 0, "Zero liquidity");
        require(deadline >= block.timestamp, "Deadline passed");
        
        // Get position information
        (PoolKey memory poolKey, PositionInfo positionInfo) = positionManager.getPoolAndPositionInfo(tokenId);
        
        // Record balances before liquidity removal
        uint256 balance0Before = Currency.unwrap(poolKey.currency0) != address(0) ? 
                                IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(this)) : 0;
        uint256 balance1Before = Currency.unwrap(poolKey.currency1) != address(0) ?
                                IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(this)) : 0;
        
        // Build actions: DECREASE_LIQUIDITY + CLOSE_CURRENCY (production pattern)
        // Each action must be encoded as uint8
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.CLOSE_CURRENCY),
            uint8(Actions.CLOSE_CURRENCY)
        );
        
        bytes[] memory params = new bytes[](3);
        
        // Action 1: DECREASE_LIQUIDITY with actual liquidity amount
        params[0] = abi.encode(
            tokenId,
            liquidity,  // liquidity to decrease
            uint128(0), // amount0Min (handle slippage at higher level)
            uint128(0), // amount1Min (handle slippage at higher level)
            bytes("")   // empty hookData
        );
        
        // Action 2: CLOSE_CURRENCY for currency0
        params[1] = abi.encode(poolKey.currency0);
        
        // Action 3: CLOSE_CURRENCY for currency1
        params[2] = abi.encode(poolKey.currency1);

        // Execute using production PositionManager pattern
        // Must use modifyLiquidities (not WithoutUnlock) to unlock the pool manager
        positionManager.modifyLiquidities(abi.encode(actions, params), deadline);

        // Calculate removed amounts from balance changes (production method)
        amount0 = Currency.unwrap(poolKey.currency0) != address(0) ? 
                  IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(address(this)) - balance0Before : 0;
        amount1 = Currency.unwrap(poolKey.currency1) != address(0) ?
                  IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(address(this)) - balance1Before : 0;
        
        require(amount0 > 0 || amount1 > 0, "No liquidity removed");
        
        return (amount0, amount1);
    }

    /**
     * @notice Update position tracking after rebalancing
     */
    function _updatePositionTracking(address user, uint256 oldTokenId, uint256 newTokenId) internal {
        // Remove old token ID from user positions
        uint256[] storage positions = userPositions[user];
        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i] == oldTokenId) {
                positions[i] = positions[positions.length - 1];
                positions.pop();
                break;
            }
        }
        
        // Add new token ID
        positions.push(newTokenId);
        
        // Update reverse mapping
        delete positionOwner[oldTokenId];
        positionOwner[newTokenId] = user;
    }

    /**
     * @notice Set default minimum conversion amounts for production
     * @dev Sets realistic minimums based on token decimals and gas costs
     */
    function _setDefaultMinAmounts() internal {
        // Set minimum amounts based on token decimals and gas efficiency
        // These prevent dust positions and ensure gas-efficient operations
        
        // WETH (18 decimals) - minimum 0.001 ETH worth (~$2)
        minConversionAmounts[address(0x4200000000000000000000000000000000000006)] = 1e15; // 0.001 ETH
        
        // USDC (6 decimals) - minimum $10 worth
        minConversionAmounts[address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913)] = 10e6; // $10 USDC
        
        // USDbC (6 decimals) - minimum $10 worth  
        minConversionAmounts[address(0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA)] = 10e6; // $10 USDbC
        
        // DAI (18 decimals) - minimum $10 worth
        minConversionAmounts[address(0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb)] = 10e18; // $10 DAI
        
        // cbETH (18 decimals) - minimum 0.001 ETH worth
        minConversionAmounts[address(0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22)] = 1e15; // 0.001 cbETH

        // Default minimum for unlisted tokens (assumes 18 decimals, 0.001 minimum for testing)
        // This prevents dust positions while allowing test tokens to work
        defaultMinAmount = 1e15; // 0.001 tokens for 18-decimal tokens

        emit MinAmountsInitialized();
    }

    // ==================== STRUCTS ====================

    struct ConversionParams {
        address token0;
        address token1;
        int24 tickLower;
        int24 tickUpper;
    }
}