// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import "../../src/SpendSaveStorage.sol";
import "../../src/modules/CrossChainSavingsModule.sol";
import "../../src/interfaces/crosschain/IL2ToL2CrossDomainMessenger.sol";

contract MockMessenger is IL2ToL2CrossDomainMessenger {
    uint256 private _sourceChain;
    address private _sourceSender;

    function sendMessage(uint256 destinationChainId, address target, bytes calldata message)
        external
        payable
        override
        returns (bytes32 messageHash)
    {
        messageHash = keccak256(abi.encode(destinationChainId, target, message));
    }

    function crossDomainMessageSource() external view override returns (uint256 sourceChainId) {
        return _sourceChain;
    }

    function crossDomainMessageSender() external view override returns (address sourceSender) {
        return _sourceSender;
    }

    function relayToModule(
        address module,
        address sourceModule,
        address user,
        address token,
        uint256 amount,
        uint256 sourceChainId,
        bytes32 messageHash
    ) external {
        _sourceChain = sourceChainId;
        _sourceSender = sourceModule;
        CrossChainSavingsModule(module).receiveSavingsFromChain(user, token, amount, sourceChainId, messageHash);
    }
}

contract CrossChainSavingsModuleTest is Test {
    SpendSaveStorage private sourceStorage;
    SpendSaveStorage private destinationStorage;
    CrossChainSavingsModule private sourceModule;
    CrossChainSavingsModule private destinationModule;
    MockMessenger private messenger;

    address private constant USER = address(0x1234);
    address private constant TOKEN = address(0xBEEF);
    uint256 private constant SOURCE_CHAIN_ID = 8453;
    uint256 private constant DEST_CHAIN_ID = 10;

    function setUp() external {
        messenger = new MockMessenger();

        sourceStorage = new SpendSaveStorage(address(1));
        destinationStorage = new SpendSaveStorage(address(1));

        sourceStorage.initialize(address(this));
        destinationStorage.initialize(address(this));

        sourceModule = new CrossChainSavingsModule(address(sourceStorage), address(messenger));
        destinationModule = new CrossChainSavingsModule(address(destinationStorage), address(messenger));

        bytes32 crossChainId = keccak256("CROSSCHAIN");
        sourceStorage.registerModule(crossChainId, address(sourceModule));
        destinationStorage.registerModule(crossChainId, address(destinationModule));

        sourceModule.registerPeerModule(DEST_CHAIN_ID, address(destinationModule));
        destinationModule.registerPeerModule(SOURCE_CHAIN_ID, address(sourceModule));

        sourceStorage.registerModule(keccak256("TEST"), address(this));
        destinationStorage.registerModule(keccak256("TEST"), address(this));

        sourceStorage.batchUpdateUserSavings(USER, TOKEN, 1_000e6);
    }

    function testTransferAndReceiveSavings() external {
        uint256 initialSourceBalance = sourceStorage.savings(USER, TOKEN);
        assertGt(initialSourceBalance, 0);

        vm.prank(USER);
        bytes32 messageHash = sourceModule.transferSavingsToChain(DEST_CHAIN_ID, USER, TOKEN, 100e6);

        uint256 postTransferBalance = sourceStorage.savings(USER, TOKEN);
        assertEq(postTransferBalance, initialSourceBalance - 100e6);

        messenger.relayToModule(
            address(destinationModule), address(sourceModule), USER, TOKEN, 100e6, SOURCE_CHAIN_ID, messageHash
        );

        uint256 destinationBalance = destinationStorage.savings(USER, TOKEN);
        assertEq(destinationBalance, 100e6);
    }
}

