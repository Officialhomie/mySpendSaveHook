// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import "../src/SpendSaveStorage.sol";
import "../src/modules/CrossChainSavingsModule.sol";
import "../src/modules/CrossChainDCAModule.sol";
import "../src/LiquidityRouter.sol";

contract DeployCrossChainModules is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address storageAddress = vm.envAddress("SPENDSAVE_STORAGE");
        address messengerAddress = vm.envOr("L2_TO_L2_MESSENGER", address(0x4200000000000000000000000000000000000023));

        // Map chain IDs to quoter addresses
        uint256 chainId = block.chainid;
        address quoterAddress;

        if (chainId == 84532) {
            // Base Sepolia
            quoterAddress = 0xf3A39C86dbd13C45365E57FB90fe413371F65AF8;
        } else if (chainId == 8453) {
            // Base Mainnet
            quoterAddress = 0x0d5e0F971ED27FBfF6c2837bf31316121532048D;
        } else if (chainId == 10) {
            // Optimism Mainnet
            quoterAddress = 0x1f3131A13296FB91C90870043742C3CDBFF1A8d7;
        } else {
            revert("Unsupported chain");
        }

        vm.startBroadcast(deployerKey);

        CrossChainSavingsModule savingsModule = new CrossChainSavingsModule(storageAddress, messengerAddress);

        CrossChainDCAModule dcaModule =
            new CrossChainDCAModule(storageAddress, address(savingsModule), messengerAddress, quoterAddress);

        SpendSaveStorage storageContract = SpendSaveStorage(storageAddress);

        storageContract.registerModule(keccak256("CROSSCHAIN"), address(savingsModule));
        storageContract.registerModule(keccak256("CROSSCHAIN_DCA"), address(dcaModule));

        LiquidityRouter liquidityRouter = new LiquidityRouter(storageAddress);
        dcaModule.setLiquidityRouter(address(liquidityRouter));

        // Configure common pools (example - adjust based on your needs)
        address USDC = _getUSDCForChain(chainId);
        address WETH = _getWETHForChain(chainId);

        if (USDC != address(0) && WETH != address(0)) {
            vm.prank(storageContract.owner());
            dcaModule.configurePool(
                USDC < WETH ? USDC : WETH, // token0
                USDC < WETH ? WETH : USDC, // token1
                3000, // 0.3% fee tier
                60 // tick spacing
            );
        }

        vm.stopBroadcast();

        console2.log("CrossChainSavingsModule deployed:", address(savingsModule));
        console2.log("CrossChainDCAModule deployed:", address(dcaModule));
        console2.log("LiquidityRouter deployed:", address(liquidityRouter));
        console2.log("Using V4 Quoter:", quoterAddress);
    }

    function _getUSDCForChain(uint256 chainId) internal pure returns (address) {
        if (chainId == 84532) return 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
        if (chainId == 8453) return 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
        if (chainId == 10) return 0x7F5c764cBc14f9669B88837ca1490cCa17c31607;
        return address(0);
    }

    function _getWETHForChain(uint256 chainId) internal pure returns (address) {
        if (chainId == 84532) return 0x4200000000000000000000000000000000000006;
        if (chainId == 8453) return 0x4200000000000000000000000000000000000006;
        if (chainId == 10) return 0x4200000000000000000000000000000000000006;
        return address(0);
    }
}

