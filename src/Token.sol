// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./SpendSaveStorage.sol";
import "./ITokenModule.sol";
import {ReentrancyGuard} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title Token
 * @dev Implements ERC6909 token standard for representing savings
 */
contract Token is ITokenModule, ReentrancyGuard {
    // Storage reference
    SpendSaveStorage public storage_;
    
    // ERC6909 interface constants
    bytes4 constant private _ERC6909_RECEIVED = 0x05e3242b; // bytes4(keccak256("onERC6909Received(address,address,uint256,uint256,bytes)"))
    
    // Events (same as in ERC6909)
    event Transfer(address indexed sender, address indexed receiver, uint256 indexed id, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 indexed id, uint256 amount);
    event TokenRegistered(address indexed token, uint256 indexed tokenId);
    event ModuleInitialized(address indexed storage_);
    event SavingsTokenMinted(address indexed user, address indexed token, uint256 tokenId, uint256 amount);
    event SavingsTokenBurned(address indexed user, address indexed token, uint256 tokenId, uint256 amount);
    event TreasuryFeeCollected(address indexed user, address token, uint256 amount);
    
    // Custom errors
    error InvalidTokenAddress();
    error TokenNotRegistered(address token);
    error InsufficientBalance(address owner, uint256 tokenId, uint256 requested, uint256 available);
    error InsufficientAllowance(address owner, address spender, uint256 tokenId, uint256 requested, uint256 available);
    error TransferToZeroAddress();
    error TransferFromZeroAddress();
    error ERC6909ReceiverRejected();
    error NonERC6909ReceiverImplementer(string reason);
    error NonERC6909ReceiverImplementerNoReason();
    error AlreadyInitialized();
    error UnauthorizedCaller();
    
    // Constructor is empty since module will be initialized via initialize()
    constructor() {}

    modifier onlyAuthorized(address user) {
        if (msg.sender != user && 
            msg.sender != address(storage_) && 
            msg.sender != storage_.spendSaveHook()) {
            revert UnauthorizedCaller();
        }
        _;
    }
    
    // Initialize module with storage reference
    function initialize(SpendSaveStorage _storage) external override {
        if(address(storage_) != address(0)) revert AlreadyInitialized();
        storage_ = _storage;
        emit ModuleInitialized(address(_storage));
    }
    
    // Register a new token and assign it an ID for ERC-6909
    function registerToken(address token) public override nonReentrant returns (uint256) {
        if (token == address(0)) revert InvalidTokenAddress();
        
        // If token already registered, return existing ID
        if (storage_.tokenToId(token) != 0) {
            return storage_.tokenToId(token);
        }
        
        // Assign new ID
        uint256 newId = storage_.getNextTokenId();
        storage_.incrementNextTokenId();
        
        // Update mappings
        storage_.setTokenToId(token, newId);
        storage_.setIdToToken(newId, token);
        
        emit TokenRegistered(token, newId);
        return newId;
    }
    
    // Mint ERC-6909 tokens to represent savings
    function mintSavingsToken(address user, address token, uint256 amount) external override onlyAuthorized(user) nonReentrant {
        uint256 tokenId = _getOrRegisterTokenId(token);
        
        // Process fee and update balances
        _processTokenMinting(user, token, tokenId, amount);
    }

    // Helper to get or register token ID
    function _getOrRegisterTokenId(address token) internal returns (uint256) {
        uint256 tokenId = storage_.tokenToId(token);
        if (tokenId == 0) {
            tokenId = registerToken(token);
        }
        return tokenId;
    }

    // Helper to process token minting with fees
    function _processTokenMinting(address user, address token, uint256 tokenId, uint256 amount) internal {
        // Apply treasury fee if configured
        uint256 finalAmount = storage_.calculateAndTransferFee(user, token, amount);
        
        // Handle treasury fee if taken
        if (finalAmount < amount) {
            _handleTreasuryFee(user, token, tokenId, amount - finalAmount);
        }
        
        // Update user's balance
        storage_.increaseBalance(user, tokenId, finalAmount);
        
        // Emit events
        emit Transfer(address(0), user, tokenId, finalAmount);
        emit SavingsTokenMinted(user, token, tokenId, finalAmount);
    }

    // Helper to handle treasury fee
    function _handleTreasuryFee(address user, address token, uint256 tokenId, uint256 feeAmount) internal {
        address treasury = storage_.treasury();
        storage_.increaseBalance(treasury, tokenId, feeAmount);
        
        emit Transfer(address(0), treasury, tokenId, feeAmount);
        emit TreasuryFeeCollected(user, token, feeAmount);
    }
    
    // Burn ERC-6909 tokens when withdrawing
    function burnSavingsToken(address user, address token, uint256 amount) external override onlyAuthorized(user) nonReentrant {
        uint256 tokenId = storage_.tokenToId(token);
        if (tokenId == 0) revert TokenNotRegistered(token);
        
        uint256 currentBalance = storage_.getBalance(user, tokenId);
        if (currentBalance < amount) {
            revert InsufficientBalance(user, tokenId, amount, currentBalance);
        }
        storage_.decreaseBalance(user, tokenId, amount);
        
        emit Transfer(user, address(0), tokenId, amount);
        emit SavingsTokenBurned(user, token, tokenId, amount);
    }
    
    // ERC6909: Get balance of tokens for an owner
    function balanceOf(address owner, uint256 id) external view override returns (uint256) {
        return storage_.getBalance(owner, id);
    }
    
    // ERC6909: Get allowance for a spender
    function allowance(address owner, address spender, uint256 id) external view override returns (uint256) {
        return storage_.getAllowance(owner, spender, id);
    }
    
    // ERC6909: Transfer tokens
    function transfer(address sender, address receiver, uint256 id, uint256 amount) external override onlyAuthorized(sender) nonReentrant returns (bool) {
        if (receiver == address(0)) revert TransferToZeroAddress();
        
        uint256 senderBalance = storage_.getBalance(sender, id);
        if (senderBalance < amount) {
            revert InsufficientBalance(sender, id, amount, senderBalance);
        }

        storage_.decreaseBalance(sender, id, amount);
        storage_.increaseBalance(receiver, id, amount);
        
        emit Transfer(sender, receiver, id, amount);
        return true;
    }
    
    // ERC6909: Transfer tokens on behalf of another user
    function transferFrom(
        address operator, 
        address sender, 
        address receiver, 
        uint256 id, 
        uint256 amount
    ) external override onlyAuthorized(operator) nonReentrant returns (bool) {
        _validateTransferAddresses(sender, receiver);
        _checkSenderBalance(sender, id, amount);
        
        // Check allowance if needed
        if (operator != sender) {
            _checkAndUpdateAllowance(sender, operator, id, amount);
        }
        
        // Execute the transfer
        _executeTransfer(sender, receiver, id, amount);
        
        return true;
    }

    function _validateTransferAddresses(address sender, address receiver) internal pure {
        if (sender == address(0)) revert TransferFromZeroAddress();
        if (receiver == address(0)) revert TransferToZeroAddress();
    }

    function _checkSenderBalance(address sender, uint256 id, uint256 amount) internal view {
        uint256 senderBalance = storage_.getBalance(sender, id);
        if (senderBalance < amount) {
            revert InsufficientBalance(sender, id, amount, senderBalance);
        }
    }

    function _checkAndUpdateAllowance(address owner, address spender, uint256 id, uint256 amount) internal {
        uint256 currentAllowance = storage_.getAllowance(owner, spender, id);
        if (currentAllowance < amount) {
            revert InsufficientAllowance(owner, spender, id, amount, currentAllowance);
        }
        
        storage_.setAllowance(owner, spender, id, currentAllowance - amount);
    }

    function _executeTransfer(address sender, address receiver, uint256 id, uint256 amount) internal {
        storage_.decreaseBalance(sender, id, amount);
        storage_.increaseBalance(receiver, id, amount);
        
        emit Transfer(sender, receiver, id, amount);
    }
    
    // ERC6909: Approve spending limit
    function approve(address owner, address spender, uint256 id, uint256 amount) external override onlyAuthorized(owner) nonReentrant returns (bool) {
        storage_.setAllowance(owner, spender, id, amount);
        
        emit Approval(owner, spender, id, amount);
        return true;
    }
    
    // ERC6909: Safe transfer with receiver check
    function safeTransfer(
        address sender,
        address receiver,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external override onlyAuthorized(sender) nonReentrant returns (bool) {
        // Validate receiver
        if (receiver == address(0)) revert TransferToZeroAddress();
        
        // Check sender balance
        _checkSenderBalance(sender, id, amount);
        
        // Execute the transfer
        _executeTransfer(sender, receiver, id, amount);
        
        // Check if receiver is a contract and call onERC6909Received
        // Note the sender is both the operator and from address in this case
        _checkERC6909Receiver(sender, sender, receiver, id, amount, data);
        
        return true;
    }

    


    // ERC6909: Safe transferFrom with receiver check
    function safeTransferFrom(
        address operator,
        address sender,
        address receiver,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external override onlyAuthorized(operator) nonReentrant returns (bool) {
        // Reuse the same checks we already implemented
        _validateTransferAddresses(sender, receiver);
        _checkSenderBalance(sender, id, amount);
        
        // Check allowance if needed
        if (operator != sender) {
            _checkAndUpdateAllowance(sender, operator, id, amount);
        }
        
        // Execute the transfer
        _executeTransfer(sender, receiver, id, amount);
        
        // Check if receiver is a contract and call onERC6909Received
        _checkERC6909Receiver(operator, sender, receiver, id, amount, data);
        
        return true;
    }

    function _checkERC6909Receiver(
        address operator,
        address sender,
        address receiver,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) internal {
        if (_isContract(receiver)) {
            _callERC6909Receiver(operator, sender, receiver, id, amount, data);
        }
    }

    function _callERC6909Receiver(
        address operator,
        address sender,
        address receiver,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) internal {
        try IERC6909Receiver(receiver).onERC6909Received(operator, sender, id, amount, data) returns (bytes4 retval) {
            if (retval != _ERC6909_RECEIVED) {
                revert ERC6909ReceiverRejected();
            }
        } catch Error(string memory reason) {
            revert NonERC6909ReceiverImplementer(reason);
        } catch {
            revert NonERC6909ReceiverImplementerNoReason();
        }
    }
    
    // Function to query token ID by token address
    function getTokenId(address token) external view override returns (uint256) {
        return storage_.tokenToId(token);
    }
    
    // Function to query token address by token ID
    function getTokenAddress(uint256 id) external view override returns (address) {
        return storage_.idToToken(id);
    }
    
    // Helper to check if an address is a contract
    function _isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
}

interface IERC6909Receiver {
    function onERC6909Received(
        address operator,
        address from,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external returns (bytes4);
}