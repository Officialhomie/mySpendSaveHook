// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    ReentrancyGuard
} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {ILiquidityRouter} from "./interfaces/ILiquidityRouter.sol";
import {SpendSaveStorage} from "./SpendSaveStorage.sol";

/**
 * @title LiquidityRouter
 * @notice Lightweight registry-based router that surfaces the best cross-chain liquidity quotes.
 * @dev Quotes are expected to be provided off-chain and pushed on-chain by authorised updaters.
 */
contract LiquidityRouter is ILiquidityRouter, ReentrancyGuard {
    // ==================== ERRORS ====================

    error InvalidTokenPair();
    error Unauthorized();
    error UnauthorizedQuoteUpdater();
    error NoQuoteAvailable();

    // ==================== EVENTS ====================

    event SupportedChainsUpdated(uint256[] chains);
    event QuoteUpdaterSet(uint256 indexed chainId, address indexed updater, bool allowed);
    event ExternalQuoteUpdated(
        uint256 indexed chainId,
        bytes32 indexed pairKey,
        uint256 expectedOutput,
        uint256 priceImpactBps,
        uint256 gasEstimate
    );
    event ExternalQuoteCleared(uint256 indexed chainId, bytes32 indexed pairKey);
    event BaseGasCostSet(uint256 indexed chainId, uint256 gasCost);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ==================== STRUCTS ====================

    struct ExternalQuote {
        uint256 amountIn;
        uint256 expectedOutput;
        uint256 priceImpactBps;
        uint256 gasEstimate;
        uint64 updatedAt;
    }

    // ==================== STATE ====================

    SpendSaveStorage public immutable storage_;
    address public owner;

    mapping(uint256 => mapping(address => bool)) public quoteUpdaters;
    mapping(uint256 => uint256) public baseGasCost;
    mapping(uint256 => mapping(bytes32 => ExternalQuote)) private _externalQuotes;

    uint256[] private _supportedChains;
    mapping(uint256 => bool) private _chainListed;

    // ==================== MODIFIERS ====================

    modifier onlyOwner() {
        if (msg.sender != owner && msg.sender != storage_.owner()) revert Unauthorized();
        _;
    }

    // ==================== CONSTRUCTOR ====================

    constructor(address storageAddress) {
        if (storageAddress == address(0)) revert InvalidTokenPair();
        storage_ = SpendSaveStorage(storageAddress);
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ==================== ADMIN OPERATIONS ====================

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert Unauthorized();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setSupportedChains(uint256[] calldata chains) external onlyOwner {
        for (uint256 i = 0; i < _supportedChains.length; i++) {
            _chainListed[_supportedChains[i]] = false;
        }
        delete _supportedChains;

        for (uint256 i = 0; i < chains.length; i++) {
            uint256 chainId = chains[i];
            if (_chainListed[chainId]) continue;
            _supportedChains.push(chainId);
            _chainListed[chainId] = true;
        }

        emit SupportedChainsUpdated(chains);
    }

    function setBaseGasCost(uint256 chainId, uint256 gasCost) external onlyOwner {
        baseGasCost[chainId] = gasCost;
        emit BaseGasCostSet(chainId, gasCost);
    }

    function setQuoteUpdater(uint256 chainId, address updater, bool allowed) external onlyOwner {
        quoteUpdaters[chainId][updater] = allowed;
        emit QuoteUpdaterSet(chainId, updater, allowed);
    }

    function updateExternalQuote(
        uint256 chainId,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 expectedOutput,
        uint256 priceImpactBps,
        uint256 gasEstimate
    ) external nonReentrant {
        if (!quoteUpdaters[chainId][msg.sender] && msg.sender != owner && msg.sender != storage_.owner()) {
            revert UnauthorizedQuoteUpdater();
        }
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut) revert InvalidTokenPair();

        bytes32 key = _pairKey(tokenIn, tokenOut);

        ExternalQuote storage stored = _externalQuotes[chainId][key];
        stored.amountIn = amountIn;
        stored.expectedOutput = expectedOutput;
        stored.priceImpactBps = priceImpactBps;
        stored.gasEstimate = gasEstimate;
        stored.updatedAt = uint64(block.timestamp);

        emit ExternalQuoteUpdated(chainId, key, expectedOutput, priceImpactBps, gasEstimate);
    }

    function clearExternalQuote(uint256 chainId, address tokenIn, address tokenOut) external onlyOwner {
        bytes32 key = _pairKey(tokenIn, tokenOut);
        delete _externalQuotes[chainId][key];
        emit ExternalQuoteCleared(chainId, key);
    }

    // ==================== VIEW / QUOTE FUNCTIONS ====================

    function getBestExecutionChain(address tokenIn, address tokenOut, uint256 amountIn)
        external
        override
        returns (ILiquidityRouter.LiquidityQuote memory)
    {
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut) revert InvalidTokenPair();

        bytes32 key = _pairKey(tokenIn, tokenOut);
        return _findBestChain(key, amountIn);
    }

    function _findBestChain(bytes32 key, uint256 amountIn)
        internal
        view
        returns (ILiquidityRouter.LiquidityQuote memory best)
    {
        uint256 bestScore;
        bool found;

        for (uint256 i = 0; i < _supportedChains.length; i++) {
            uint256 candidateChain = _supportedChains[i];
            ExternalQuote storage stored = _externalQuotes[candidateChain][key];
            if (stored.updatedAt == 0) continue;

            uint256 output = _normalizeQuote(amountIn, stored.amountIn, stored.expectedOutput);
            uint256 gas = stored.gasEstimate + baseGasCost[candidateChain];
            uint256 score = _scoreQuote(output, gas);

            if (!found || score > bestScore) {
                found = true;
                bestScore = score;
                best.chainId = candidateChain;
                best.expectedOutput = output;
                best.priceImpactBps = stored.priceImpactBps;
                best.gasEstimate = gas;
            }
        }

        if (!found) revert NoQuoteAvailable();
    }

    // ==================== INTERNAL HELPERS ====================

    function _pairKey(address tokenA, address tokenB) internal pure returns (bytes32) {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        return keccak256(abi.encodePacked(token0, token1));
    }

    function _sortTokens(address tokenA, address tokenB) internal pure returns (address token0, address token1) {
        if (tokenA == tokenB) revert InvalidTokenPair();
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function _normalizeQuote(uint256 requestedAmount, uint256 storedAmount, uint256 storedOutput)
        internal
        pure
        returns (uint256)
    {
        if (storedAmount == 0 || requestedAmount == storedAmount) {
            return storedOutput;
        }
        return (storedOutput * requestedAmount) / storedAmount;
    }

    function _scoreQuote(uint256 output, uint256 gas) internal pure returns (uint256) {
        if (output <= gas) {
            return 0;
        }
        return output - gas;
    }
}

