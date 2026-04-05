// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IL2ToL2CrossDomainMessenger {
    function sendMessage(uint256 destinationChainId, address target, bytes calldata message)
        external
        payable
        returns (bytes32 messageHash);

    function crossDomainMessageSource() external view returns (uint256 sourceChainId);

    function crossDomainMessageSender() external view returns (address sourceSender);
}

