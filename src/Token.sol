// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SpendSaveStorage} from "./SpendSaveStorage.sol";
import {ITokenModule} from "./interfaces/ITokenModule.sol";
import {ReentrancyGuard} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {IERC20Metadata} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title Token
 * @dev Implements ERC6909 token standard for representing savings
 */
contract Token is ITokenModule, ReentrancyGuard {
    // Storage reference
    SpendSaveStorage public storage_;
    
    // ERC6909 interface constants
    bytes4 constant private _ERC6909_RECEIVED = 0x05e3242b; // bytes4(keccak256("onERC6909Received(address,address,uint256,uint256,bytes)"))
    
    // ERC6909 operator storage
    mapping(address => mapping(address => bool)) public isOperator;
    
    // Standardized module references
    address internal _savingStrategyModule;
    address internal _savingsModule;
    address internal _dcaModule;
    address internal _slippageModule;
    address internal _tokenModule;
    address internal _dailySavingsModule;


    // ERC6909 compliant events
    event Transfer(address caller, address indexed sender, address indexed receiver, uint256 indexed id, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 indexed id, uint256 amount);
    event OperatorSet(address indexed owner, address indexed operator, bool approved);
    event ModuleInitialized(address indexed storage_);
    event SavingsTokenMinted(address indexed user, address indexed token, uint256 tokenId, uint256 amount);
    event SavingsTokenBurned(address indexed user, address indexed token, uint256 tokenId, uint256 amount);
    event TreasuryFeeCollected(address indexed user, address token, uint256 amount);
    
    // Interface-compliant events
    event ModuleReferencesSet();
    
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
    error InvalidAmount();
    error InvalidBatchLength();
    
    // Constructor is empty since module will be initialized via initialize()
    constructor() {}

    modifier onlyAuthorized(address user) {
        if (msg.sender != user &&
            msg.sender != address(storage_) &&
            msg.sender != storage_.spendSaveHook() &&
            msg.sender != _savingsModule &&
            msg.sender != _dailySavingsModule &&
            !isOperator[user][msg.sender]) {  // Also allow operators
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

    function setModuleReferences(
        address savingStrategy,
        address savings,
        address dca,
        address slippage,
        address token,
        address dailySavings
    ) external override {
        if (msg.sender != storage_.spendSaveHook() && msg.sender != storage_.owner()) {
            revert UnauthorizedCaller();
        }
        
        _savingStrategyModule = savingStrategy;
        _savingsModule = savings;
        _dcaModule = dca;
        _slippageModule = slippage;
        _tokenModule = token;
        _dailySavingsModule = dailySavings;
        
        emit ModuleReferencesSet();
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
    
    /**
     * @notice Batch register multiple tokens
     * @param tokens Array of token addresses
     * @return tokenIds Array of assigned token IDs
     */
    function batchRegisterTokens(
        address[] calldata tokens
    ) external override returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](tokens.length);
        
        for (uint256 i = 0; i < tokens.length; i++) {
            tokenIds[i] = registerToken(tokens[i]);
        }
        
        emit BatchOperationCompleted(msg.sender, tokens.length);
    }
    
    // Mint ERC-6909 tokens to represent savings
    function mintSavingsToken(address user, uint256 tokenId, uint256 amount) external override onlyAuthorized(user) {
        if (amount == 0) revert InvalidAmount();
        
        // Verify token is registered
        address token = storage_.idToToken(tokenId);
        if (token == address(0)) revert TokenNotRegistered(token);
        
        // Mint tokens directly to user
        storage_.increaseBalance(user, tokenId, amount);
        storage_.increaseTotalSupply(tokenId, amount);
        
        // Emit events
        emit Transfer(msg.sender, address(0), user, tokenId, amount);
        emit SavingsTokenMinted(user, token, tokenId, amount);
        emit TokenMinted(user, tokenId, amount);
    }
    
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
    ) external override onlyAuthorized(user) {
        if (tokenIds.length != amounts.length) revert InvalidBatchLength();
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (amounts[i] > 0) {
                // Verify token is registered
                address token = storage_.idToToken(tokenIds[i]);
                if (token == address(0)) revert TokenNotRegistered(token);
                
                // Mint tokens
                storage_.increaseBalance(user, tokenIds[i], amounts[i]);
                storage_.increaseTotalSupply(tokenIds[i], amounts[i]);
                
                // Emit events
                emit Transfer(msg.sender, address(0), user, tokenIds[i], amounts[i]);
                emit SavingsTokenMinted(user, token, tokenIds[i], amounts[i]);
                emit TokenMinted(user, tokenIds[i], amounts[i]);
            }
        }
        
        emit BatchOperationCompleted(user, tokenIds.length);
    }
    
    /**
     * @notice Burn savings tokens from a user
     * @dev Called when user withdraws savings
     * @param user The user address
     * @param tokenId The ERC6909 token ID
     * @param amount The amount to burn
     */
    function burnSavingsToken(address user, uint256 tokenId, uint256 amount) external override onlyAuthorized(user) nonReentrant {
        if (amount == 0) revert InvalidAmount();
        
        // Verify token is registered
        address token = storage_.idToToken(tokenId);
        if (token == address(0)) revert TokenNotRegistered(token);
        
        uint256 currentBalance = storage_.getBalance(user, tokenId);
        if (currentBalance < amount) {
            revert InsufficientBalance(user, tokenId, amount, currentBalance);
        }
        
        storage_.decreaseBalance(user, tokenId, amount);
        storage_.decreaseTotalSupply(tokenId, amount);
        
        emit Transfer(msg.sender, user, address(0), tokenId, amount);
        emit SavingsTokenBurned(user, token, tokenId, amount);
        emit TokenBurned(user, tokenId, amount);
    }
    
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
    ) external override onlyAuthorized(user) nonReentrant {
        if (tokenIds.length != amounts.length) revert InvalidBatchLength();
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (amounts[i] > 0) {
                // Verify token is registered
                address token = storage_.idToToken(tokenIds[i]);
                if (token == address(0)) revert TokenNotRegistered(token);
                
                // Check balance
                uint256 currentBalance = storage_.getBalance(user, tokenIds[i]);
                if (currentBalance < amounts[i]) {
                    revert InsufficientBalance(user, tokenIds[i], amounts[i], currentBalance);
                }
                
                // Burn tokens
                storage_.decreaseBalance(user, tokenIds[i], amounts[i]);
                storage_.decreaseTotalSupply(tokenIds[i], amounts[i]);
                
                // Emit events
                emit Transfer(msg.sender, user, address(0), tokenIds[i], amounts[i]);
                emit SavingsTokenBurned(user, token, tokenIds[i], amounts[i]);
                emit TokenBurned(user, tokenIds[i], amounts[i]);
            }
        }
        
        emit BatchOperationCompleted(user, tokenIds.length);
    }

    // ERC6909: Get balance of tokens for an owner
    function balanceOf(address owner, uint256 id) external view override returns (uint256) {
        return storage_.getBalance(owner, id);
    }
    
    /**
     * @notice Get user's balances for multiple savings tokens
     * @param user The user address
     * @param tokenIds Array of token IDs
     * @return balances Array of balances
     */
    function balanceOfBatch(
        address user,
        uint256[] calldata tokenIds
    ) external view override returns (uint256[] memory balances) {
        balances = new uint256[](tokenIds.length);
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            balances[i] = storage_.getBalance(user, tokenIds[i]);
        }
    }
    
    // Only keep one totalSupply function implementation
    function totalSupply(uint256 tokenId) external view override returns (uint256) {
        return storage_.getTotalSupply(tokenId);
    }
    
    // ERC6909: Get allowance for a spender
    function allowance(address owner, address spender, uint256 id) external view returns (uint256) {
        return storage_.getAllowance(owner, spender, id);
    }
    
    // ERC6909: Transfer tokens
    function transfer(address sender, address receiver, uint256 id, uint256 amount) external onlyAuthorized(sender) nonReentrant returns (bool) {
        if (receiver == address(0)) revert TransferToZeroAddress();
        
        uint256 senderBalance = storage_.getBalance(sender, id);
        if (senderBalance < amount) {
            revert InsufficientBalance(sender, id, amount, senderBalance);
        }

        storage_.decreaseBalance(sender, id, amount);
        storage_.increaseBalance(receiver, id, amount);
        
        emit Transfer(msg.sender, sender, receiver, id, amount);
        return true;
    }
    
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
    ) external override onlyAuthorized(from) nonReentrant returns (bool success) {
        if (tokenIds.length != amounts.length) revert InvalidBatchLength();
        if (to == address(0)) revert TransferToZeroAddress();
        
        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (amounts[i] > 0) {
                uint256 senderBalance = storage_.getBalance(from, tokenIds[i]);
                if (senderBalance < amounts[i]) {
                    revert InsufficientBalance(from, tokenIds[i], amounts[i], senderBalance);
                }
                
                storage_.decreaseBalance(from, tokenIds[i], amounts[i]);
                storage_.increaseBalance(to, tokenIds[i], amounts[i]);
                
                emit Transfer(msg.sender, from, to, tokenIds[i], amounts[i]);
            }
        }
        
        emit BatchOperationCompleted(from, tokenIds.length);
        return true;
    }
    
    // ERC6909: Transfer tokens on behalf of another user
    function transferFrom(
        address operator, 
        address sender, 
        address receiver, 
        uint256 id, 
        uint256 amount
    ) external onlyAuthorized(operator) nonReentrant returns (bool) {
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
        
        emit Transfer(msg.sender, sender, receiver, id, amount);
    }
    
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
    ) external override returns (bool success) {
        if (spender == address(0)) revert TransferToZeroAddress();
        
        // Set approval in storage
        storage_.setAllowance(msg.sender, spender, tokenId, amount);
        
        emit Approval(msg.sender, spender, tokenId, amount);
        return true;
    }
    
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
    ) external override nonReentrant returns (bool success) {
        if (to == address(0)) revert TransferToZeroAddress();
        if (from == address(0)) revert TransferFromZeroAddress();
        
        // Check allowance
        uint256 currentAllowance = storage_.getAllowance(from, msg.sender, tokenId);
        if (currentAllowance < amount) revert InsufficientAllowance(from, msg.sender, tokenId, amount, currentAllowance);
        
        // Check balance
        uint256 fromBalance = storage_.getBalance(from, tokenId);
        if (fromBalance < amount) revert InsufficientBalance(from, tokenId, amount, fromBalance);
        
        // Update balances
        storage_.decreaseBalance(from, tokenId, amount);
        storage_.increaseBalance(to, tokenId, amount);
        
        // Update allowance
        storage_.setAllowance(from, msg.sender, tokenId, currentAllowance - amount);
        
        emit Transfer(msg.sender, from, to, tokenId, amount);
        return true;
    }
    
    // ERC6909: Safe transfer with receiver check
    function safeTransfer(
        address sender,
        address receiver,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) external onlyAuthorized(sender) nonReentrant returns (bool) {
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
    ) external onlyAuthorized(operator) nonReentrant returns (bool) {
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
    
    /**
     * @notice Check if a token is registered
     * @param token The token address
     * @return isRegistered Whether the token is registered
     */
    function isTokenRegistered(address token) external view override returns (bool) {
        return storage_.tokenToId(token) != 0;
    }
    
    // Helper to check if an address is a contract
    function _isContract(address addr) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
    
    // ==================== ERC6909 STANDARD COMPLIANCE FUNCTIONS ====================
    
    /**
     * @notice Set or unset an operator for the caller
     * @param operator The operator address
     * @param approved Whether to approve or revoke approval
     * @return success Always returns true
     */
    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }
    
    /**
     * @notice Standard ERC6909 transfer function (caller is sender)
     * @param receiver The recipient address
     * @param id The token ID
     * @param amount The amount to transfer
     * @return success Always returns true on successful transfer
     */
    function transfer(address receiver, uint256 id, uint256 amount) external nonReentrant returns (bool) {
        // Validate addresses
        _validateTransferAddresses(msg.sender, receiver);
        
        // Check sender balance
        _checkSenderBalance(msg.sender, id, amount);
        
        // Execute the transfer
        _executeTransfer(msg.sender, receiver, id, amount);
        
        return true;
    }
    
    /**
     * @notice Standard ERC6909 transferFrom function (caller is operator/approved)
     * @param sender The sender address  
     * @param receiver The recipient address
     * @param id The token ID
     * @param amount The amount to transfer
     * @return success Always returns true on successful transfer
     */
    /**
     * @notice ERC165 interface support detection
     * @param interfaceId The interface identifier
     * @return supported Whether the interface is supported
     */
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x0f632fb3 || // ERC6909
               interfaceId == 0x01ffc9a7;   // ERC165
    }
    
    /**
     * @notice Get token metadata (ERC6909 extension)
     * @param id The token ID
     * @return name The token name
     */
    function name(uint256 id) external view returns (string memory) {
        address token = storage_.idToToken(id);
        require(token != address(0), "Token not registered");
        
        // Try to get name from token contract
        try IERC20Metadata(token).name() returns (string memory tokenName) {
            return string(abi.encodePacked("SpendSave ", tokenName));
        } catch {
            return string(abi.encodePacked("SpendSave Token #", _toString(id)));
        }
    }
    
    /**
     * @notice Get token symbol (ERC6909 extension)
     * @param id The token ID
     * @return symbol The token symbol
     */
    function symbol(uint256 id) external view returns (string memory) {
        address token = storage_.idToToken(id);
        require(token != address(0), "Token not registered");
        
        // Try to get symbol from token contract
        try IERC20Metadata(token).symbol() returns (string memory tokenSymbol) {
            return string(abi.encodePacked("ss", tokenSymbol));
        } catch {
            return string(abi.encodePacked("SST", _toString(id)));
        }
    }
    
    /**
     * @notice Get token decimals (ERC6909 extension)
     * @param id The token ID
     * @return decimals The number of decimals
     */
    function decimals(uint256 id) external view returns (uint8) {
        address token = storage_.idToToken(id);
        require(token != address(0), "Token not registered");
        
        // Try to get decimals from token contract
        try IERC20Metadata(token).decimals() returns (uint8 tokenDecimals) {
            return tokenDecimals;
        } catch {
            return 18; // Default to 18 decimals
        }
    }
    
    /**
     * @notice Convert number to string (internal utility)
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        
        uint256 temp = value;
        uint256 digits;
        
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        
        bytes memory buffer = new bytes(digits);
        
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        
        return string(buffer);
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