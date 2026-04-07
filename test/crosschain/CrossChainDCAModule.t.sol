// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";

import "../../src/SpendSaveStorage.sol";
import "../../src/modules/CrossChainDCAModule.sol";
import "../../src/interfaces/crosschain/ICrossChainSavingsModule.sol";
import "../../src/interfaces/crosschain/IL2ToL2CrossDomainMessenger.sol";
import "../../src/interfaces/ILiquidityRouter.sol";

contract MockCrossChainSavingsModule is ICrossChainSavingsModule {
    bytes32 public lastMessageHash;

    function transferSavingsToChain(uint256 destinationChainId, address user, address token, uint256 amount)
        external
        override
        returns (bytes32 messageHash)
    {
        messageHash = keccak256(abi.encode(destinationChainId, user, token, amount, block.number));
        lastMessageHash = messageHash;
    }

    function receiveSavingsFromChain(address, address, uint256, uint256, bytes32) external override {}

    function aggregateSavingsToHomeChain(address, address, uint256) external pure override returns (bytes32) {
        return bytes32(0);
    }

    function registerPeerModule(uint256, address) external pure override {}

    function getCrossChainBalance(address, address, uint256[] calldata chainIds)
        external
        pure
        override
        returns (uint256[] memory balances, uint256 total)
    {
        balances = new uint256[](chainIds.length);
        total = 0;
    }
}

contract MockMessenger is IL2ToL2CrossDomainMessenger {
    uint256 private _source;
    address private _sender;

    function setContext(uint256 sourceChainId, address sourceSender) external {
        _source = sourceChainId;
        _sender = sourceSender;
    }

    function sendMessage(uint256, address, bytes calldata) external payable override returns (bytes32 messageHash) {
        messageHash = keccak256(abi.encode(block.number));
    }

    function crossDomainMessageSource() external view override returns (uint256 sourceChainId) {
        return _source;
    }

    function crossDomainMessageSender() external view override returns (address sourceSender) {
        return _sender;
    }
}

contract MockLiquidityRouter is ILiquidityRouter {
    LiquidityQuote public quote;

    function setQuote(uint256 chainId, uint256 expectedOutput, uint256 priceImpactBps, uint256 gasEstimate) external {
        quote = LiquidityQuote({
            chainId: chainId, expectedOutput: expectedOutput, priceImpactBps: priceImpactBps, gasEstimate: gasEstimate
        });
    }

    function getBestExecutionChain(address, address, uint256) external override returns (LiquidityQuote memory) {
        return quote;
    }
}

import {IV4Quoter} from "lib/v4-periphery/src/interfaces/IV4Quoter.sol";
import {IPoolManager} from "lib/v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";

contract MockV4Quoter is IV4Quoter {
    IPoolManager public immutable poolManager;

    constructor() {
        poolManager = IPoolManager(address(0x123)); // Mock address
    }

    function quoteExactInputSingle(IV4Quoter.QuoteExactSingleParams memory params)
        external
        pure
        override
        returns (uint256 amountOut, uint256 gasEstimate)
    {
        // Mock implementation - return 1:1 ratio for testing
        amountOut = uint256(params.exactAmount);
        gasEstimate = 50000;
    }

    function quoteExactInput(IV4Quoter.QuoteExactParams memory) external pure override returns (uint256, uint256) {
        revert("Not implemented");
    }

    function quoteExactOutputSingle(IV4Quoter.QuoteExactSingleParams memory)
        external
        pure
        override
        returns (uint256, uint256)
    {
        revert("Not implemented");
    }

    function quoteExactOutput(IV4Quoter.QuoteExactParams memory) external pure override returns (uint256, uint256) {
        revert("Not implemented");
    }

    function msgSender() external pure override returns (address) {
        return address(0);
    }
}

contract CrossChainDCAModuleViewTest is Test {
    SpendSaveStorage private storageContract;
    MockCrossChainSavingsModule private savingsModule;
    MockMessenger private messenger;
    MockV4Quoter private mockQuoter;
    CrossChainDCAModule private crossChainModule;

    function setUp() external {
        storageContract = new SpendSaveStorage(address(1));
        storageContract.initialize(address(this));

        savingsModule = new MockCrossChainSavingsModule();
        messenger = new MockMessenger();
        mockQuoter = new MockV4Quoter();

        crossChainModule = new CrossChainDCAModule(
            address(storageContract), address(savingsModule), address(messenger), address(mockQuoter)
        );

        storageContract.registerModule(keccak256("CROSSCHAIN_DCA"), address(crossChainModule));
    }

    function testFindBestLiquidityChainFallsBackToCurrentChain() external {
        ILiquidityRouter.LiquidityQuote memory quote =
            crossChainModule.findBestLiquidityChain(address(0x1), address(0x2), 1_000);

        assertEq(quote.chainId, block.chainid);
        assertEq(quote.expectedOutput, 1_000);
        assertEq(quote.priceImpactBps, 0);
        assertEq(quote.gasEstimate, 0);
    }

    function testFindBestLiquidityChainUsesRouterQuote() external {
        uint256 alternativeChain = 2345;

        MockLiquidityRouter router = new MockLiquidityRouter();
        router.setQuote(alternativeChain, 1_500, 50, 10);

        vm.prank(storageContract.owner());
        crossChainModule.setLiquidityRouter(address(router));

        ILiquidityRouter.LiquidityQuote memory quote =
            crossChainModule.findBestLiquidityChain(address(0x1), address(0x2), 1_000);

        assertEq(quote.chainId, alternativeChain);
        assertEq(quote.expectedOutput, 1_500);
        assertEq(quote.priceImpactBps, 50);
        assertEq(quote.gasEstimate, 10);
    }
}

