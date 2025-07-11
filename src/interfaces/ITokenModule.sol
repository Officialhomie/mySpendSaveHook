// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ISpendSaveModule} from "./ISpendSaveModule.sol";

/**
 * @title ITokenModule
 * @notice Updated interface for ERC6909 token operations
 * @dev Optimized for batch operations and gas efficiency
 */
interface ITokenModule is ISpendSaveModule {
    
    // ==================== EVENTS ====================
    
    event TokenRegistered(address indexed token, uint256 indexed tokenId);
    event TokenMinted(address indexed user, uint256 indexed tokenId, uint256 amount);
    event TokenBurned(address indexed user, uint256 indexed tokenId, uint256 amount);
    event BatchOperationCompleted(address indexed user, uint256 count);
    
    // ==================== CORE FUNCTIONS ====================
    
    /**
     * @notice Register a new token for savings
     * @dev Assigns a unique tokenId for ERC6909
     * @param token The token address to register
     * @return tokenId The assigned token ID
     */
    function registerToken(address token) external returns (uint256 tokenId);
    
    /**
     * @notice Batch register multiple tokens
     * @param tokens Array of token addresses
     * @return tokenIds Array of assigned token IDs
     */
    function batchRegisterTokens(
        address[] calldata tokens
    ) external returns (uint256[] memory tokenIds);
    
    /**
     * @notice Mint savings tokens to a user
     * @dev Called when user saves tokens
     * @param user The user address
     * @param tokenId The ERC6909 token ID
     * @param amount The amount to mint
     */
    function mintSavingsToken(
        address user,
        uint256 tokenId,
        uint256 amount
    ) external;
    
    /**
     * @notice Batch mint savings tokens
     * @dev Gas-efficient batch operation
     * @param user The user address
     * @param tokenIds Array of token IDs
     * @param amounts Array of amounts to mint
     */
    function batchMintSavingsTokens(
        address user,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external;
    
    /**
     * @notice Burn savings tokens from a user
     * @dev Called when user withdraws savings
     * @param user The user address
     * @param tokenId The ERC6909 token ID
     * @param amount The amount to burn
     */
    function burnSavingsToken(
        address user,
        uint256 tokenId,
        uint256 amount
    ) external;
    
    /**
     * @notice Batch burn savings tokens
     * @dev Gas-efficient batch operation
     * @param user The user address
     * @param tokenIds Array of token IDs
     * @param amounts Array of amounts to burn
     */
    function batchBurnSavingsTokens(
        address user,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external;
    
    // ==================== VIEW FUNCTIONS ====================
    
    /**
     * @notice Get token ID for a token address
     * @param token The token address
     * @return tokenId The ERC6909 token ID (0 if not registered)
     */
    function getTokenId(address token) external view returns (uint256 tokenId);
    
    /**
     * @notice Get token address for a token ID
     * @param tokenId The ERC6909 token ID
     * @return token The token address
     */
    function getTokenAddress(uint256 tokenId) external view returns (address token);
    
    /**
     * @notice Check if a token is registered
     * @param token The token address
     * @return isRegistered Whether the token is registered
     */
    function isTokenRegistered(address token) external view returns (bool isRegistered);
    
    /**
     * @notice Get user's balance for a specific savings token
     * @param user The user address
     * @param tokenId The ERC6909 token ID
     * @return balance The user's balance
     */
    function balanceOf(address user, uint256 tokenId) external view returns (uint256 balance);
    
    /**
     * @notice Get user's balances for multiple savings tokens
     * @param user The user address
     * @param tokenIds Array of token IDs
     * @return balances Array of balances
     */
    function balanceOfBatch(
        address user,
        uint256[] calldata tokenIds
    ) external view returns (uint256[] memory balances);
    
    /**
     * @notice Get total supply for a savings token
     * @param tokenId The ERC6909 token ID
     * @return totalSupply The total supply
     */
    function totalSupply(uint256 tokenId) external view returns (uint256 totalSupply);
    
    // ==================== ERC6909 STANDARD FUNCTIONS ====================
    
    /**
     * @notice Transfer savings tokens between users
     * @param from The sender address
     * @param to The recipient address
     * @param tokenId The ERC6909 token ID
     * @param amount The amount to transfer
     * @return success Whether the transfer succeeded
     */
    function transfer(
        address from,
        address to,
        uint256 tokenId,
        uint256 amount
    ) external returns (bool success);
    
    /**
     * @notice Batch transfer multiple tokens
     * @param from The sender address
     * @param to The recipient address
     * @param tokenIds Array of token IDs
     * @param amounts Array of amounts
     * @return success Whether all transfers succeeded
     */
    function batchTransfer(
        address from,
        address to,
        uint256[] calldata tokenIds,
        uint256[] calldata amounts
    ) external returns (bool success);
    
    /**
     * @notice Approve spending of savings tokens
     * @param spender The spender address
     * @param tokenId The ERC6909 token ID
     * @param amount The approval amount
     * @return success Whether the approval succeeded
     */
    function approve(
        address spender,
        uint256 tokenId,
        uint256 amount
    ) external returns (bool success);
    
    /**
     * @notice Transfer from approved address
     * @param from The token owner
     * @param to The recipient
     * @param tokenId The ERC6909 token ID
     * @param amount The amount to transfer
     * @return success Whether the transfer succeeded
     */
    function transferFrom(
        address from,
        address to,
        uint256 tokenId,
        uint256 amount
    ) external returns (bool success);
}