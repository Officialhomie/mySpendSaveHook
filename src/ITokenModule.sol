// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ISpendSaveModule.sol";

// Token Module Interface (ERC6909)
interface ITokenModule is ISpendSaveModule {
    function registerToken(address token) external returns (uint256);
    
    function mintSavingsToken(address user, address token, uint256 amount) external;
    
    function burnSavingsToken(address user, address token, uint256 amount) external;
    
    function balanceOf(address owner, uint256 id) external view returns (uint256);
    
    function allowance(address owner, address spender, uint256 id) external view returns (uint256);
    
    function transfer(address sender, address receiver, uint256 id, uint256 amount) external returns (bool);
    
    function transferFrom(address operator, address sender, address receiver, uint256 id, uint256 amount) external returns (bool);
    
    function approve(address owner, address spender, uint256 id, uint256 amount) external returns (bool);
    
    function safeTransfer(address sender, address receiver, uint256 id, uint256 amount, bytes calldata data) external returns (bool);
    
    function safeTransferFrom(address operator, address sender, address receiver, uint256 id, uint256 amount, bytes calldata data) external returns (bool);
    
    function getTokenId(address token) external view returns (uint256);
    
    function getTokenAddress(uint256 id) external view returns (address);
}