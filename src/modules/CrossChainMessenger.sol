// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IL2ToL2CrossDomainMessenger} from "../interfaces/crosschain/IL2ToL2CrossDomainMessenger.sol";

contract CrossChainMessenger {
    address public immutable messenger;

    constructor(address messengerAddress) {
        require(messengerAddress != address(0), "Invalid messenger");
        messenger = messengerAddress;
    }

    function sendMessage(uint256 destinationChainId, address target, bytes calldata message)
        external
        payable
        returns (bytes32 messageHash)
    {
        messageHash = IL2ToL2CrossDomainMessenger(messenger).sendMessage(destinationChainId, target, message);
    }

    function getMessageSource() external view returns (uint256 sourceChainId, address sourceSender) {
        IL2ToL2CrossDomainMessenger messengerContract = IL2ToL2CrossDomainMessenger(messenger);
        sourceChainId = messengerContract.crossDomainMessageSource();
        sourceSender = messengerContract.crossDomainMessageSender();
    }
}

