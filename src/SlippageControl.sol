// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {SpendSaveStorage} from "./SpendSaveStorage.sol";
import {ISlippageControlModule} from "./interfaces/ISlippageControlModule.sol";
import {ReentrancyGuard} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SlippageControl
 * @dev Manages slippage settings and protection for swaps
 */
contract SlippageControl is ISlippageControlModule, ReentrancyGuard {
    // Constants
    uint256 private constant MAX_USER_SLIPPAGE = 1000; // 10%
    uint256 private constant MAX_DEFAULT_SLIPPAGE = 500; // 5%
    uint256 private constant BASIS_POINTS_DENOMINATOR = 10000;
    
    // Storage reference
    SpendSaveStorage public storage_;
    
    // Standardized module references
    address internal _savingStrategyModule;
    address internal _savingsModule;
    address internal _dcaModule;
    address internal _slippageModule;
    address internal _tokenModule;
    address internal _dailySavingsModule;
    
    // Events
    event SlippageToleranceSet(address indexed user, uint256 basisPoints);
    event TokenSlippageToleranceSet(address indexed user, address indexed token, uint256 basisPoints);
    event SlippageActionSet(address indexed user, SpendSaveStorage.SlippageAction action);
    event DefaultSlippageToleranceSet(uint256 basisPoints);
    event SlippageExceeded(address indexed user, address indexed fromToken, address indexed toToken, uint256 fromAmount, uint256 actualToAmount, uint256 expectedMinimum);
    event ModuleInitialized(address indexed storage_);
    event ModuleReferencesSet();
    
    // Custom errors
    error SlippageToleranceTooHigh(uint256 provided, uint256 max);
    error OnlyTreasury();
    error SlippageToleranceExceeded(uint256 received, uint256 expected);
    error AlreadyInitialized();
    error UnauthorizedCaller();
    error OnlyUserOrHook();
    error Unauthorized();
    
    // Constructor is empty since module will be initialized via initialize()
    constructor() {}

    modifier onlyAuthorized(address user) {
        if (!_isAuthorizedCaller(user)) {
            revert UnauthorizedCaller();
        }
        _;
    }
    
    modifier onlyTreasury() {
        if (msg.sender != storage_.treasury()) {
            revert OnlyTreasury();
        }
        _;
    }
    
    // Helper for authorization check
    function _isAuthorizedCaller(address user) internal view returns (bool) {
        return (msg.sender == user || 
                msg.sender == address(storage_) || 
                msg.sender == storage_.spendSaveHook());
    }
    
    // Initialize module with storage reference
    function initialize(SpendSaveStorage _storage) external override {
        if (address(storage_) != address(0)) revert AlreadyInitialized();
        storage_ = _storage;
        emit ModuleInitialized(address(_storage));
    }
    
    // Set references to other modules
    function setModuleReferences(
        address savingStrategy,
        address savings,
        address dca,
        address slippage,
        address token,
        address dailySavings
    ) external override {
        if (msg.sender != storage_.spendSaveHook() && msg.sender != storage_.owner()) {
            revert Unauthorized();
        }
        
        _savingStrategyModule = savingStrategy;
        _savingsModule = savings;
        _dcaModule = dca;
        _slippageModule = slippage;
        _tokenModule = token;
        _dailySavingsModule = dailySavings;
        
        emit ModuleReferencesSet();
    }
    
    // Function for users to set their preferred slippage tolerance
    function setSlippageTolerance(address user, uint256 basisPoints) external override onlyAuthorized(user) nonReentrant {
        _validateSlippageTolerance(basisPoints, MAX_USER_SLIPPAGE);
        storage_.setUserSlippageTolerance(user, basisPoints);
        emit SlippageToleranceSet(user, basisPoints);
    }
    
    // Helper to validate slippage tolerance
    function _validateSlippageTolerance(uint256 basisPoints, uint256 maxValue) internal pure {
        if (basisPoints > maxValue) {
            revert SlippageToleranceTooHigh(basisPoints, maxValue);
        }
    }
    
    // Function for users to set token-specific slippage tolerance
    function setTokenSlippageTolerance(address user, address token, uint256 basisPoints) external override onlyAuthorized(user) nonReentrant {
        _validateSlippageTolerance(basisPoints, MAX_USER_SLIPPAGE);
        storage_.setTokenSlippageTolerance(user, token, basisPoints);
        emit TokenSlippageToleranceSet(user, token, basisPoints);
    }
    
    // Function for users to set their preferred action when slippage is exceeded
    function setSlippageAction(address user, SpendSaveStorage.SlippageAction action) external override onlyAuthorized(user) nonReentrant {
        storage_.setSlippageExceededAction(user, action);
        emit SlippageActionSet(user, action);
    }
    
    // Function for admin to set the default slippage tolerance
    function setDefaultSlippageTolerance(uint256 basisPoints) external nonReentrant onlyTreasury {
        _validateSlippageTolerance(basisPoints, MAX_DEFAULT_SLIPPAGE);
        storage_.setDefaultSlippageTolerance(basisPoints);
        emit DefaultSlippageToleranceSet(basisPoints);
    }
    
    // Helper function to get minimum amount out based on slippage
    function getMinimumAmountOut(
        address user,
        address fromToken,
        address toToken,
        uint256 amountIn,
        uint256 customSlippageTolerance
    ) external view override returns (uint256) {
        // Get the effective slippage tolerance to use for this specific token
        uint256 slippageBps = getEffectiveSlippageTolerance(user, toToken, customSlippageTolerance);
        
        // Calculate expected output with slippage tolerance
        return _calculateOutputWithSlippage(amountIn, slippageBps);
    }
    
    // Helper to calculate expected output with slippage
    function _calculateOutputWithSlippage(uint256 expectedAmount, uint256 slippageBps) internal pure returns (uint256) {
        // Apply slippage tolerance (slippageBps is in basis points, 100 = 1%)
        return expectedAmount * (BASIS_POINTS_DENOMINATOR - slippageBps) / BASIS_POINTS_DENOMINATOR;
    }
    
    // Handle slippage exceeded according to user preferences
    function handleSlippageExceeded(
        address user,
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 receivedAmount,
        uint256 expectedMinimum
    ) external override onlyAuthorized(user) nonReentrant returns (bool) {
        // Calculate and emit slippage information
        _emitSlippageExceeded(user, fromToken, toToken, fromAmount, receivedAmount, expectedMinimum);
        
        // Apply user's configured slippage action
        return _applySlippageAction(user, receivedAmount, expectedMinimum);
    }
    
    // Helper to emit slippage exceeded event
    function _emitSlippageExceeded(
        address user,
        address fromToken,
        address toToken,
        uint256 fromAmount,
        uint256 receivedAmount,
        uint256 expectedMinimum
    ) internal {
        emit SlippageExceeded(
            user,
            fromToken,
            toToken,
            fromAmount,
            receivedAmount,
            expectedMinimum
        );
    }
    
    // Helper to apply slippage action
    function _applySlippageAction(
        address user, 
        uint256 receivedAmount, 
        uint256 expectedMinimum
    ) internal view returns (bool) {
        SpendSaveStorage.SlippageAction action = storage_.slippageExceededAction(user);
        
        if (action == SpendSaveStorage.SlippageAction.REVERT) {
            revert SlippageToleranceExceeded(receivedAmount, expectedMinimum);
        }
        
        // Default is to continue with the transaction (CONTINUE action)
        return true;
    }
    
    // Helper function to get a user's effective slippage tolerance
    function getEffectiveSlippageTolerance(
        address user, 
        address token,
        uint256 customSlippageTolerance
    ) internal view returns (uint256) {
        // If custom slippage was provided for this specific transaction, use it
        if (customSlippageTolerance > 0) {
            return customSlippageTolerance;
        }
        
        // If user has token-specific preference, use that
        uint256 tokenSpecificSlippage = storage_.tokenSlippageTolerance(user, token);
        if (tokenSpecificSlippage > 0) {
            return tokenSpecificSlippage;
        }
        
        // If user has a global persistent preference, use that
        uint256 userSlippage = storage_.userSlippageTolerance(user);
        if (userSlippage > 0) {
            return userSlippage;
        }
        
        // Otherwise use the contract default
        return storage_.defaultSlippageTolerance();
    }
}