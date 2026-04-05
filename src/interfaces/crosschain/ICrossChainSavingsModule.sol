// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface ICrossChainSavingsModule {
    function transferSavingsToChain(uint256 destinationChainId, address user, address token, uint256 amount)
        external
        returns (bytes32 messageHash);

    function receiveSavingsFromChain(
        address user,
        address token,
        uint256 amount,
        uint256 sourceChainId,
        bytes32 messageHash
    ) external;

    function aggregateSavingsToHomeChain(address user, address token, uint256 homeChainId)
        external
        returns (bytes32 messageHash);

    function registerPeerModule(uint256 chainId, address moduleAddress) external;

    function getCrossChainBalance(address user, address token, uint256[] calldata chainIds)
        external
        view
        returns (uint256[] memory balances, uint256 total);
}

