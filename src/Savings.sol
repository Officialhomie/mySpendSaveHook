// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import "./SpendSaveStorage.sol";
import "./ISavingsModule.sol";
import "./ITokenModule.sol";
import "./ISavingStrategyModule.sol";

/**
 * @title Savings
 * @dev Handles user savings, deposits and withdrawals
 */
contract Savings is ISavingsModule, ReentrancyGuard {
    using SafeERC20 for IERC20;
    
    // Storage reference
    SpendSaveStorage public storage_;
    
    // Module references
    ITokenModule public tokenModule;
    ISavingStrategyModule public strategyModule;
    
    // Events
    event AmountSaved(address indexed user, address indexed token, uint256 amount, uint256 totalSaved);
    event SavingsWithdrawn(address indexed user, address indexed token, uint256 amount, uint256 remaining);
    event GoalReached(address indexed user, address indexed token, uint256 amount);
    event ModuleInitialized(address storage_);
    event ModuleReferencesSet(address tokenModule, address strategyModule);
    event WithdrawalTimelockSet(address indexed user, uint256 timelock);
    event TreasuryFeeCollected(address indexed user, address token, uint256 amount);
    
    // Custom errors
    error InsufficientSavings(address token, uint256 requested, uint256 available);
    error WithdrawalTimelockActive(uint256 unlockTime);
    error InvalidTokenAddress();
    error AlreadyInitialized();
    error OnlyOwner();
    error OnlyHook();
    error OnlyAuthorizedCaller();
    error UnauthorizedCaller();
    
    // Constructor is empty since module will be initialized via initialize()
    constructor() {}

    modifier onlyAuthorized(address user) {
        if (!_isAuthorizedCaller(user)) {
            revert UnauthorizedCaller();
        }
        _;
    }
    
    modifier onlyOwner() {
        if (msg.sender != storage_.owner()) {
            revert OnlyOwner();
        }
        _;
    }
    
    // Helper for authorization check
    function _isAuthorizedCaller(address user) internal view returns (bool) {
        return (msg.sender == user || 
                msg.sender == address(storage_) || 
                msg.sender == storage_.spendSaveHook() ||
                msg.sender == address(strategyModule));
    }
    
    // Initialize module with storage reference
    function initialize(SpendSaveStorage _storage) external override {
        if (address(storage_) != address(0)) revert AlreadyInitialized();
        storage_ = _storage;
        emit ModuleInitialized(address(_storage));
    }
    
    // Set references to other modules
    function setModuleReferences(address _tokenModule, address _strategyModule) external onlyOwner {
        tokenModule = ITokenModule(_tokenModule);
        strategyModule = ISavingStrategyModule(_strategyModule);
        emit ModuleReferencesSet(_tokenModule, _strategyModule);
    }
    
    // Process savings from swap output
    function processSavingsFromOutput(
        address user,
        address outputToken,
        uint256 outputAmount,
        SpendSaveStorage.SwapContext memory context
    ) external override onlyAuthorized(user) {
        uint256 saveAmount = _calculateSaveAmount(outputAmount, context);
        
        if (saveAmount > 0) {
            // Process the savings
            processSavings(user, outputToken, saveAmount);
        }
    }
    
    // Helper to calculate save amount
    function _calculateSaveAmount(
        uint256 amount,
        SpendSaveStorage.SwapContext memory context
    ) internal view returns (uint256) {
        return strategyModule.calculateSavingsAmount(
            amount,
            context.currentPercentage,
            context.roundUpSavings
        );
    }

    // Add this to the Savings contract
    function processInputSavingsAfterSwap(
        address user,
        address token,
        uint256 amount
    ) external override onlyAuthorized(user) {
        // This is similar to processSavings but specifically for input tokens
        // that have been diverted by the hook
        
        // Calculate and transfer fee
        uint256 finalAmount = storage_.calculateAndTransferFee(user, token, amount);
        
        // Update savings balance and data
        _updateSavingsRecords(user, token, finalAmount);
        
        // Check for goal achievement
        _checkSavingsGoal(user, token);
        
        // Get current total saved amount for event
        (uint256 totalSaved, , , ) = storage_.getSavingsData(user, token);
        
        emit AmountSaved(user, token, finalAmount, totalSaved);
    }
        
    // Process savings to a specific token from output
    function processSavingsToSpecificToken(
        address user,
        address outputToken,
        uint256 outputAmount,
        SpendSaveStorage.SwapContext memory context
    ) external override onlyAuthorized(user) {
        address specificToken = context.specificSavingsToken;
        
        // Calculate amount to save
        uint256 saveAmount = _calculateSaveAmount(outputAmount, context);
        
        if (saveAmount > 0 && specificToken != address(0)) {
            _processSavingsForSpecificToken(user, outputToken, specificToken, saveAmount);
        }
    }
    
    // Helper to process savings for specific token
    function _processSavingsForSpecificToken(
        address user,
        address outputToken,
        address specificToken, 
        uint256 saveAmount
    ) internal {
        // If the output token is already the specific token, no need to swap
        if (outputToken == specificToken) {
            processSavings(user, specificToken, saveAmount);
        } else {
            // In a real implementation, we would handle swapping from output token
            // to specific token here, but that requires complex swap execution logic.
            // For simplicity, we'll just save the output token.
            
            // First, process the savings of the output token
            processSavings(user, outputToken, saveAmount);
            
            // In a full implementation, we would swap these tokens to the specific token
            // This would be handled by a specialized swap execution module
        }
    }
    
    // Process savings for a user
    function processSavings(
        address user,
        address token,
        uint256 amount
    ) public override onlyAuthorized(user) {
        // Calculate and transfer fee
        uint256 finalAmount = storage_.calculateAndTransferFee(user, token, amount);
        
        // Update savings balance and data
        _updateSavingsRecords(user, token, finalAmount);
        
        // Check for goal achievement
        _checkSavingsGoal(user, token);
        
        // Get current total saved amount for event
        (uint256 totalSaved, , , ) = storage_.getSavingsData(user, token);
        
        emit AmountSaved(user, token, finalAmount, totalSaved);
    }
    
    // Helper to update savings records
    function _updateSavingsRecords(address user, address token, uint256 amount) internal {
        // Update savings balance in storage
        storage_.increaseSavings(user, token, amount);
        
        // Mint ERC-6909 tokens to represent savings
        tokenModule.mintSavingsToken(user, token, amount);
        
        // Update savings data
        storage_.updateSavingsData(user, token, amount);
    }
    
    // Helper to check savings goal
    function _checkSavingsGoal(address user, address token) internal {
        // Get current savings data
        (uint256 totalSaved, , , ) = storage_.getSavingsData(user, token);
        
        // Check if savings goal reached
        (,,,uint256 goalAmount,,,, ) = storage_.getUserSavingStrategy(user);
        if (goalAmount > 0 && totalSaved >= goalAmount) {
            emit GoalReached(user, token, totalSaved);
        }
    }
    
    // Allow users to withdraw their savings
    function withdrawSavings(
        address user,
        address token,
        uint256 amount
    ) external override onlyAuthorized(user) nonReentrant {
        // Validate withdrawal amount and timelock
        _validateWithdrawal(user, token, amount);
        
        // Calculate and transfer fee
        uint256 finalAmount = storage_.calculateAndTransferFee(user, token, amount);
        
        // Process the withdrawal
        _processWithdrawal(user, token, amount, finalAmount);
    }
    
    // Helper to validate withdrawal
    function _validateWithdrawal(address user, address token, uint256 amount) internal view {
        // Check available savings
        uint256 userSavings = storage_.savings(user, token);
        if (userSavings < amount) {
            revert InsufficientSavings(token, amount, userSavings);
        }
        
        // Check timelock if set
        uint256 withdrawalTimelock = storage_.withdrawalTimelock(user);
        if (withdrawalTimelock > 0) {
            (,uint256 lastSaveTime,,) = storage_.getSavingsData(user, token);
            uint256 unlockTime = lastSaveTime + withdrawalTimelock;
            if (block.timestamp < unlockTime) {
                revert WithdrawalTimelockActive(unlockTime);
            }
        }
    }
    
    // Helper to process withdrawal
    function _processWithdrawal(address user, address token, uint256 amount, uint256 finalAmount) internal {
        // Update savings balance
        storage_.decreaseSavings(user, token, amount);
        
        // Burn ERC-6909 tokens
        tokenModule.burnSavingsToken(user, token, amount);
        
        // Transfer tokens to user
        IERC20(token).safeTransfer(user, finalAmount);
        
        uint256 remaining = storage_.savings(user, token);
        emit SavingsWithdrawn(user, token, finalAmount, remaining);
    }
    
    // Allow users to deposit tokens directly to savings
    function depositSavings(
        address user,
        address token,
        uint256 amount
    ) external override onlyAuthorized(user) nonReentrant {
        if (token == address(0)) revert InvalidTokenAddress();
        
        // Transfer tokens from user to this contract
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        
        // Process the savings
        processSavings(user, token, amount);
    }
    
    // Set time-lock for withdrawals (in seconds)
    function setWithdrawalTimelock(address user, uint256 timelock) external override onlyAuthorized(user) {
        storage_.setWithdrawalTimelock(user, timelock);
        emit WithdrawalTimelockSet(user, timelock);
    }
}