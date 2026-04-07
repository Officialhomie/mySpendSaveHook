// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {SpendSaveStorage} from "../src/SpendSaveStorage.sol";
import {CrossChainSavingsModule} from "../src/modules/CrossChainSavingsModule.sol";
import {CrossChainDCAModule} from "../src/modules/CrossChainDCAModule.sol";

/**
 * @title LinkCrossChainPeers
 * @notice Links SpendSave deployments across multiple Superchains for cross-chain functionality
 * @dev This script MUST be run AFTER deploying on all target chains
 *
 * USAGE:
 * 1. Deploy SpendSave on all chains using DeploySpendSave.s.sol
 * 2. Update the deployment addresses in the chainDeployments mapping below
 * 3. Run this script to link all chains together:
 *    forge script script/LinkCrossChainPeers.s.sol --multi --broadcast
 *
 * SUPPORTED CHAINS:
 * - Base (8453)
 * - Optimism (10)
 * - Unichain (1301)
 * - Arbitrum (42161)
 * - Base Sepolia (84532) - testnet
 */
contract LinkCrossChainPeers is Script {

    // ==================== CHAIN IDS ====================

    uint256 constant CHAIN_ID_BASE = 8453;
    uint256 constant CHAIN_ID_OPTIMISM = 10;
    uint256 constant CHAIN_ID_UNICHAIN = 1301; // Unichain mainnet
    uint256 constant CHAIN_ID_ARBITRUM = 42161;
    uint256 constant CHAIN_ID_BASE_SEPOLIA = 84532; // Testnet

    // ==================== DEPLOYMENT TRACKING ====================

    struct ChainDeployment {
        uint256 chainId;
        string name;
        string rpcUrl;
        address storageContract;
        address crossChainSavingsModule;
        address crossChainDCAModule;
        bool isDeployed;
    }

    // Store all chain deployments
    mapping(uint256 => ChainDeployment) public chainDeployments;
    uint256[] public deployedChains;

    // ==================== INITIALIZATION ====================

    constructor() {
        _initializeDeployments();
    }

    /**
     * @notice Initialize deployment addresses for all chains
     * @dev UPDATE THESE ADDRESSES after deploying to each chain!
     */
    function _initializeDeployments() internal {
        // Base Mainnet
        chainDeployments[CHAIN_ID_BASE] = ChainDeployment({
            chainId: CHAIN_ID_BASE,
            name: "Base",
            rpcUrl: "base",
            storageContract: address(0), // UPDATE AFTER DEPLOYMENT
            crossChainSavingsModule: address(0), // UPDATE AFTER DEPLOYMENT
            crossChainDCAModule: address(0), // UPDATE AFTER DEPLOYMENT
            isDeployed: false // Set to true after updating addresses
        });

        // Optimism Mainnet
        chainDeployments[CHAIN_ID_OPTIMISM] = ChainDeployment({
            chainId: CHAIN_ID_OPTIMISM,
            name: "Optimism",
            rpcUrl: "optimism",
            storageContract: address(0), // UPDATE AFTER DEPLOYMENT
            crossChainSavingsModule: address(0), // UPDATE AFTER DEPLOYMENT
            crossChainDCAModule: address(0), // UPDATE AFTER DEPLOYMENT
            isDeployed: false
        });

        // Unichain Mainnet
        chainDeployments[CHAIN_ID_UNICHAIN] = ChainDeployment({
            chainId: CHAIN_ID_UNICHAIN,
            name: "Unichain",
            rpcUrl: "unichain",
            storageContract: address(0), // UPDATE AFTER DEPLOYMENT
            crossChainSavingsModule: address(0), // UPDATE AFTER DEPLOYMENT
            crossChainDCAModule: address(0), // UPDATE AFTER DEPLOYMENT
            isDeployed: false
        });

        // Arbitrum One
        chainDeployments[CHAIN_ID_ARBITRUM] = ChainDeployment({
            chainId: CHAIN_ID_ARBITRUM,
            name: "Arbitrum",
            rpcUrl: "arbitrum",
            storageContract: address(0), // UPDATE AFTER DEPLOYMENT
            crossChainSavingsModule: address(0), // UPDATE AFTER DEPLOYMENT
            crossChainDCAModule: address(0), // UPDATE AFTER DEPLOYMENT
            isDeployed: false
        });

        // Base Sepolia Testnet
        chainDeployments[CHAIN_ID_BASE_SEPOLIA] = ChainDeployment({
            chainId: CHAIN_ID_BASE_SEPOLIA,
            name: "Base Sepolia",
            rpcUrl: "base_sepolia",
            storageContract: address(0), // UPDATE AFTER DEPLOYMENT
            crossChainSavingsModule: address(0), // UPDATE AFTER DEPLOYMENT
            crossChainDCAModule: address(0), // UPDATE AFTER DEPLOYMENT
            isDeployed: false
        });

        // Build list of deployed chains
        _buildDeployedChainsList();
    }

    /**
     * @notice Build list of chains that have been deployed
     */
    function _buildDeployedChainsList() internal {
        if (chainDeployments[CHAIN_ID_BASE].isDeployed) deployedChains.push(CHAIN_ID_BASE);
        if (chainDeployments[CHAIN_ID_OPTIMISM].isDeployed) deployedChains.push(CHAIN_ID_OPTIMISM);
        if (chainDeployments[CHAIN_ID_UNICHAIN].isDeployed) deployedChains.push(CHAIN_ID_UNICHAIN);
        if (chainDeployments[CHAIN_ID_ARBITRUM].isDeployed) deployedChains.push(CHAIN_ID_ARBITRUM);
        if (chainDeployments[CHAIN_ID_BASE_SEPOLIA].isDeployed) deployedChains.push(CHAIN_ID_BASE_SEPOLIA);
    }

    // ==================== MAIN LINKING FUNCTION ====================

    /**
     * @notice Main function to link all chain deployments together
     * @dev This will register peer modules on each chain for all other chains
     */
    function run() external {
        console2.log("=============================================================");
        console2.log("       SPENDSAVE CROSS-CHAIN PEER LINKING                   ");
        console2.log("=============================================================");
        console2.log("");

        // Validate deployments
        _validateDeployments();

        // Display linking plan
        _displayLinkingPlan();

        // Link all chains
        _linkAllChains();

        // Verify linking
        _verifyLinking();

        console2.log("");
        console2.log("=============================================================");
        console2.log("   CROSS-CHAIN LINKING COMPLETED SUCCESSFULLY!              ");
        console2.log("=============================================================");
    }

    /**
     * @notice Validate that all deployments have valid addresses
     */
    function _validateDeployments() internal view {
        console2.log("Validating deployments...");

        require(deployedChains.length >= 2, "Need at least 2 chains deployed for cross-chain functionality");

        for (uint256 i = 0; i < deployedChains.length; i++) {
            uint256 chainId = deployedChains[i];
            ChainDeployment memory deployment = chainDeployments[chainId];

            require(deployment.storageContract != address(0), string.concat("Storage not deployed on ", deployment.name));
            require(deployment.crossChainSavingsModule != address(0), string.concat("CC Savings not deployed on ", deployment.name));
            require(deployment.crossChainDCAModule != address(0), string.concat("CC DCA not deployed on ", deployment.name));

            console2.log(string.concat("  ", deployment.name, ": VALID"));
        }

        console2.log("All deployments validated!");
        console2.log("");
    }

    /**
     * @notice Display the linking plan
     */
    function _displayLinkingPlan() internal view {
        console2.log("Linking Plan:");
        console2.log(string.concat("  Total chains: ", vm.toString(deployedChains.length)));
        console2.log(string.concat("  Peer connections per chain: ", vm.toString(deployedChains.length - 1)));
        console2.log(string.concat("  Total transactions: ", vm.toString(deployedChains.length * (deployedChains.length - 1) * 2)));
        console2.log("");

        console2.log("Chains to link:");
        for (uint256 i = 0; i < deployedChains.length; i++) {
            ChainDeployment memory deployment = chainDeployments[deployedChains[i]];
            console2.log(string.concat("  ", vm.toString(i + 1), ". ", deployment.name, " (Chain ID: ", vm.toString(deployment.chainId), ")"));
        }
        console2.log("");
    }

    /**
     * @notice Link all chains together by registering peer modules
     */
    function _linkAllChains() internal {
        console2.log("Starting cross-chain peer linking...");
        console2.log("");

        // For each source chain
        for (uint256 i = 0; i < deployedChains.length; i++) {
            uint256 sourceChainId = deployedChains[i];
            ChainDeployment memory sourceDeployment = chainDeployments[sourceChainId];

            console2.log(string.concat("Linking ", sourceDeployment.name, "..."));

            // Switch to source chain
            vm.createSelectFork(sourceDeployment.rpcUrl);

            // Get contracts
            SpendSaveStorage storage_ = SpendSaveStorage(sourceDeployment.storageContract);
            CrossChainSavingsModule savingsModule = CrossChainSavingsModule(sourceDeployment.crossChainSavingsModule);
            CrossChainDCAModule dcaModule = CrossChainDCAModule(sourceDeployment.crossChainDCAModule);

            // Start broadcasting transactions
            vm.startBroadcast();

            // Register all other chains as peers
            for (uint256 j = 0; j < deployedChains.length; j++) {
                if (i == j) continue; // Skip self

                uint256 peerChainId = deployedChains[j];
                ChainDeployment memory peerDeployment = chainDeployments[peerChainId];

                console2.log(string.concat("  -> Registering peer: ", peerDeployment.name));

                // Register in storage contract
                storage_.registerCrossChainPeer(
                    peerChainId,
                    peerDeployment.storageContract,
                    peerDeployment.crossChainSavingsModule
                );

                // Register in CrossChainSavingsModule
                savingsModule.registerPeerModule(peerChainId, peerDeployment.crossChainSavingsModule);

                // Register in CrossChainDCAModule
                dcaModule.registerPeerModule(peerChainId, peerDeployment.crossChainDCAModule);
            }

            vm.stopBroadcast();

            console2.log(string.concat("  ", sourceDeployment.name, " linked successfully!"));
            console2.log("");
        }
    }

    /**
     * @notice Verify that all chains are properly linked
     */
    function _verifyLinking() internal {
        console2.log("Verifying cross-chain links...");
        console2.log("");

        for (uint256 i = 0; i < deployedChains.length; i++) {
            uint256 sourceChainId = deployedChains[i];
            ChainDeployment memory sourceDeployment = chainDeployments[sourceChainId];

            console2.log(string.concat("Verifying ", sourceDeployment.name, "..."));

            vm.createSelectFork(sourceDeployment.rpcUrl);
            SpendSaveStorage storage_ = SpendSaveStorage(sourceDeployment.storageContract);

            // Check each peer
            for (uint256 j = 0; j < deployedChains.length; j++) {
                if (i == j) continue;

                uint256 peerChainId = deployedChains[j];
                ChainDeployment memory peerDeployment = chainDeployments[peerChainId];

                // Verify peer is registered
                bool isRegistered = storage_.isCrossChainPeer(peerChainId);
                require(isRegistered, string.concat("Peer not registered: ", peerDeployment.name));

                console2.log(string.concat("  ", peerDeployment.name, ": LINKED"));
            }

            console2.log("");
        }

        console2.log("All cross-chain links verified!");
        console2.log("");
    }
}
