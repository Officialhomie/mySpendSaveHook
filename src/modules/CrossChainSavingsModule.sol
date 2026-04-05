// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    ReentrancyGuard
} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {SpendSaveStorage} from "../SpendSaveStorage.sol";
import {ICrossChainSavingsModule} from "../interfaces/crosschain/ICrossChainSavingsModule.sol";
import {IL2ToL2CrossDomainMessenger} from "../interfaces/crosschain/IL2ToL2CrossDomainMessenger.sol";

contract CrossChainSavingsModule is ICrossChainSavingsModule, ReentrancyGuard {
    // ==================== CONSTANTS ====================

    address public constant DEFAULT_MESSENGER = 0x4200000000000000000000000000000000000023;

    // ==================== STATE VARIABLES ====================

    SpendSaveStorage public immutable storage_;
    address public immutable messenger;

    mapping(uint256 => address) public trustedPeerModules;
    mapping(bytes32 => MessageStatus) public messageStatus;

    uint256 public transferNonce;

    struct MessageStatus {
        address user;
        address token;
        uint256 amount;
        uint256 sourceChain;
        uint256 destinationChain;
        uint256 timestamp;
        bool executed;
        uint256 nonce;
    }

    // ==================== EVENTS ====================

    event CrossChainTransferInitiated(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 indexed destinationChainId,
        bytes32 messageHash
    );

    event SavingsReceivedFromChain(
        address indexed user, address indexed token, uint256 amount, uint256 indexed sourceChainId, bytes32 messageHash
    );

    event PeerModuleUpdated(uint256 indexed chainId, address oldModule, address newModule);

    // ==================== ERRORS ====================

    error InvalidDestination();
    error InsufficientSavings();
    error Unauthorized();
    error OnlyMessenger();
    error UntrustedSource();

    // ==================== MODIFIERS ====================

    modifier onlyOwner() {
        if (msg.sender != storage_.owner()) revert Unauthorized();
        _;
    }

    modifier onlyMessenger() {
        if (msg.sender != messenger) revert OnlyMessenger();
        _;
    }

    // ==================== CONSTRUCTOR ====================

    constructor(address storageAddress, address messengerAddress) {
        if (storageAddress == address(0)) revert Unauthorized();
        storage_ = SpendSaveStorage(storageAddress);
        messenger = messengerAddress == address(0) ? DEFAULT_MESSENGER : messengerAddress;
    }

    // ==================== CORE FUNCTIONS ====================

    function transferSavingsToChain(uint256 destinationChainId, address user, address token, uint256 amount)
        external
        override
        nonReentrant
        returns (bytes32 messageHash)
    {
        if (!_isAuthorizedCaller(user)) revert Unauthorized();
        return _transferSavingsToChain(destinationChainId, user, token, amount);
    }

    function receiveSavingsFromChain(
        address user,
        address token,
        uint256 amount,
        uint256 sourceChainId,
        bytes32 messageHash
    ) external override nonReentrant onlyMessenger {
        address expectedSourceModule = trustedPeerModules[sourceChainId];
        if (expectedSourceModule == address(0)) revert UntrustedSource();

        address sourceSender = IL2ToL2CrossDomainMessenger(messenger).crossDomainMessageSender();
        if (sourceSender != expectedSourceModule) revert UntrustedSource();

        storage_.mintSavingsFromCrossChain(user, token, amount);
        storage_.markTransferExecuted(messageHash);

        MessageStatus storage status = messageStatus[messageHash];
        if (status.timestamp == 0) {
            messageStatus[messageHash] = MessageStatus({
                user: user,
                token: token,
                amount: amount,
                sourceChain: sourceChainId,
                destinationChain: block.chainid,
                timestamp: block.timestamp,
                executed: true,
                nonce: 0
            });
        } else {
            status.executed = true;
            status.destinationChain = block.chainid;
            status.timestamp = block.timestamp;
        }

        emit SavingsReceivedFromChain(user, token, amount, sourceChainId, messageHash);
    }

    function aggregateSavingsToHomeChain(address user, address token, uint256 homeChainId)
        external
        override
        returns (bytes32 messageHash)
    {
        if (!_isAuthorizedCaller(user)) revert Unauthorized();
        if (homeChainId == block.chainid) revert InvalidDestination();

        uint256 balance = storage_.savings(user, token);
        if (balance == 0) revert InsufficientSavings();

        return _transferSavingsToChain(homeChainId, user, token, balance);
    }

    // ==================== ADMIN FUNCTIONS ====================

    function registerPeerModule(uint256 chainId, address moduleAddress) external override onlyOwner {
        _setPeerModule(chainId, moduleAddress);
    }

    function setTrustedPeerModules(uint256[] calldata chainIds, address[] calldata moduleAddresses) external onlyOwner {
        if (chainIds.length != moduleAddresses.length) revert InvalidDestination();
        for (uint256 i = 0; i < chainIds.length; i++) {
            _setPeerModule(chainIds[i], moduleAddresses[i]);
        }
    }

    function setTransferNonce(uint256 newNonce) external onlyOwner {
        transferNonce = newNonce;
    }

    // ==================== VIEW FUNCTIONS ====================

    function getCrossChainBalance(address user, address token, uint256[] calldata chainIds)
        external
        view
        override
        returns (uint256[] memory balances, uint256 total)
    {
        balances = new uint256[](chainIds.length);
        for (uint256 i = 0; i < chainIds.length; i++) {
            if (chainIds[i] == block.chainid) {
                uint256 balance = storage_.savings(user, token);
                balances[i] = balance;
                total += balance;
            }
        }
        return (balances, total);
    }

    function hasTrustedPeer(uint256 chainId) external view returns (bool) {
        return trustedPeerModules[chainId] != address(0);
    }

    // ==================== INTERNAL HELPERS ====================

    function _isAuthorizedCaller(address user) internal view returns (bool) {
        if (msg.sender == user) return true;
        if (msg.sender == storage_.spendSaveHook()) return true;
        return storage_.authorizedModules(msg.sender);
    }

    function _transferSavingsToChain(uint256 destinationChainId, address user, address token, uint256 amount)
        internal
        returns (bytes32 messageHash)
    {
        if (trustedPeerModules[destinationChainId] == address(0)) revert InvalidDestination();

        uint256 balance = storage_.savings(user, token);
        if (balance < amount) revert InsufficientSavings();

        storage_.burnSavingsForCrossChain(user, token, amount);

        uint256 nonce = ++transferNonce;
        messageHash = keccak256(abi.encodePacked(block.chainid, destinationChainId, user, token, amount, nonce));

        bytes memory payload = abi.encodeCall(
            ICrossChainSavingsModule.receiveSavingsFromChain, (user, token, amount, block.chainid, messageHash)
        );

        IL2ToL2CrossDomainMessenger(messenger)
            .sendMessage(destinationChainId, trustedPeerModules[destinationChainId], payload);

        storage_.recordPendingTransfer(messageHash, user, token, amount, destinationChainId);

        messageStatus[messageHash] = MessageStatus({
            user: user,
            token: token,
            amount: amount,
            sourceChain: block.chainid,
            destinationChain: destinationChainId,
            timestamp: block.timestamp,
            executed: false,
            nonce: nonce
        });

        emit CrossChainTransferInitiated(user, token, amount, destinationChainId, messageHash);

        return messageHash;
    }

    function _setPeerModule(uint256 chainId, address moduleAddress) internal {
        if (chainId == block.chainid || moduleAddress == address(0)) revert InvalidDestination();
        address previous = trustedPeerModules[chainId];
        trustedPeerModules[chainId] = moduleAddress;

        emit PeerModuleUpdated(chainId, previous, moduleAddress);
    }
}

