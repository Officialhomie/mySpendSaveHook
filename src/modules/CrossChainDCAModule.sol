// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    ReentrancyGuard
} from "lib/v4-periphery/lib/v4-core/lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

import {SpendSaveStorage} from "../SpendSaveStorage.sol";
import {ICrossChainSavingsModule} from "../interfaces/crosschain/ICrossChainSavingsModule.sol";
import {ICrossChainDCAModule} from "../interfaces/crosschain/ICrossChainDCAModule.sol";
import {IL2ToL2CrossDomainMessenger} from "../interfaces/crosschain/IL2ToL2CrossDomainMessenger.sol";
import {ILiquidityRouter} from "../interfaces/ILiquidityRouter.sol";
import {IDCAModule} from "../interfaces/IDCAModule.sol";
import {IV4Quoter} from "lib/v4-periphery/src/interfaces/IV4Quoter.sol";
import {PoolKey} from "lib/v4-periphery/lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-periphery/lib/v4-core/src/interfaces/IHooks.sol";

contract CrossChainDCAModule is ICrossChainDCAModule, ReentrancyGuard {
    // ==================== STATE ====================

    SpendSaveStorage public immutable storage_;
    ICrossChainSavingsModule public immutable crossChainModule;
    address public immutable messenger;
    IV4Quoter public immutable localQuoter;

    mapping(bytes32 => DCAExecution) private _executions;
    mapping(bytes32 => bytes32) public executionMessageHash;
    mapping(bytes32 => bytes32) public savingsTransferMessageHash;
    mapping(uint256 => uint256) public chainGasCosts;
    mapping(uint256 => address) public trustedPeerModules;
    uint256[] public supportedChains;
    uint256 public executionNonce;
    ILiquidityRouter public liquidityRouter;
    mapping(bytes32 => PoolKey) public poolConfigs;

    // ==================== EVENTS ====================

    event CrossChainDCAInitiated(
        bytes32 indexed executionId,
        address indexed user,
        address indexed fromToken,
        address toToken,
        uint256 amount,
        uint256 targetChainId
    );

    event DCAExecutedOnChain(
        bytes32 indexed executionId,
        address indexed user,
        address indexed toToken,
        uint256 fromAmount,
        uint256 toAmount,
        uint256 chainId
    );

    event LiquidityAnalysisCompleted(
        address indexed fromToken,
        address indexed toToken,
        uint256 bestChainId,
        uint256 estimatedOutput,
        uint256 priceImpact,
        uint256 gasCost
    );

    event CrossChainDCARequestSent(bytes32 indexed executionId, uint256 indexed targetChainId, bytes32 messageHash);
    event DCAExecutionPending(
        bytes32 indexed executionId, address indexed user, address indexed fromToken, uint256 amount
    );
    event DCAExecutionFailed(bytes32 indexed executionId, address indexed user, string reason);
    event CrossChainSavingsTransferSent(bytes32 indexed executionId, bytes32 messageHash);
    event LiquidityRouterUpdated(address indexed router);
    event PoolConfigured(address indexed token0, address indexed token1, uint24 fee, int24 tickSpacing);

    // ==================== ERRORS ====================

    error Unauthorized();
    error ExecutionNotFound();
    error InvalidChainConfig();
    error OnlyMessenger();
    error PeerNotConfigured(uint256 chainId);
    error InvalidTargetChain(uint256 expected, uint256 actual);
    error InsufficientSavingsForExecution(address token, uint256 required, uint256 available);
    error InvalidExecutionState();
    error PoolNotConfigured();
    error InvalidTokenOrder();

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

    constructor(address storageAddress, address savingsModuleAddress, address messengerAddress, address quoterAddress) {
        if (storageAddress == address(0) || savingsModuleAddress == address(0) || messengerAddress == address(0)) {
            revert Unauthorized();
        }
        storage_ = SpendSaveStorage(storageAddress);
        crossChainModule = ICrossChainSavingsModule(savingsModuleAddress);
        messenger = messengerAddress;
        localQuoter = IV4Quoter(quoterAddress);
    }

    // ==================== CORE API ====================

    function executeCrossChainDCA(
        address user,
        address fromToken,
        address toToken,
        uint256 amount,
        uint256 minAmountOut,
        uint256 targetChainId
    ) external override nonReentrant returns (bytes32 executionId) {
        if (!_isAuthorizedCaller(user)) revert Unauthorized();
        if (amount == 0) revert InvalidChainConfig();
        if (targetChainId == 0) revert InvalidChainConfig();

        executionId = keccak256(abi.encodePacked(block.chainid, ++executionNonce, user, fromToken, toToken, amount));

        DCAExecution memory execution = DCAExecution({
            user: user,
            fromToken: fromToken,
            toToken: toToken,
            amount: amount,
            minAmountOut: minAmountOut,
            sourceChain: block.chainid,
            targetChain: targetChainId,
            initiatedAt: block.timestamp,
            status: targetChainId == block.chainid ? ExecutionStatus.Executing : ExecutionStatus.Transferring
        });

        _executions[executionId] = execution;

        ILiquidityRouter.LiquidityQuote memory quote;
        if (targetChainId == block.chainid) {
            // If executing locally, validate quote
            quote = getLocalQuote(fromToken, toToken, amount);
            require(quote.expectedOutput >= minAmountOut, "Insufficient output");
            emit LiquidityAnalysisCompleted(
                fromToken, toToken, targetChainId, quote.expectedOutput, quote.priceImpactBps, quote.gasEstimate
            );
            _handleLocalExecution(executionId);
        } else {
            // For cross-chain, use default quote or router if available
            quote = _findBestQuote(fromToken, toToken, amount);
            emit LiquidityAnalysisCompleted(
                fromToken, toToken, targetChainId, quote.expectedOutput, quote.priceImpactBps, quote.gasEstimate
            );
            _initiateCrossChainExecution(executionId);
        }

        emit CrossChainDCAInitiated(executionId, user, fromToken, toToken, amount, targetChainId);

        return executionId;
    }

    function findBestLiquidityChain(address fromToken, address toToken, uint256 amount)
        public
        returns (ILiquidityRouter.LiquidityQuote memory)
    {
        return _findBestQuote(fromToken, toToken, amount);
    }

    function getLocalQuote(address fromToken, address toToken, uint256 amount)
        public
        override
        returns (ILiquidityRouter.LiquidityQuote memory quote)
    {
        require(amount > 0, "Zero amount");

        PoolKey memory poolKey = _getPoolKeyForPair(fromToken, toToken);
        bool zeroForOne = fromToken < toToken;

        try localQuoter.quoteExactInputSingle(
            IV4Quoter.QuoteExactSingleParams({
                poolKey: poolKey, zeroForOne: zeroForOne, exactAmount: uint128(amount), hookData: ""
            })
        ) returns (uint256 amountOut, uint256 gasEstimate) {
            quote = ILiquidityRouter.LiquidityQuote({
                chainId: block.chainid, expectedOutput: amountOut, priceImpactBps: 0, gasEstimate: gasEstimate
            });
        } catch {
            revert("Local quoter failed");
        }
    }

    function _findBestQuote(address fromToken, address toToken, uint256 amount)
        internal
        returns (ILiquidityRouter.LiquidityQuote memory)
    {
        if (address(liquidityRouter) != address(0)) {
            ILiquidityRouter.LiquidityQuote memory quote = _getRouterQuote(fromToken, toToken, amount);
            if (quote.chainId != 0) {
                return quote;
            }
        }

        return _buildDefaultQuote(amount);
    }

    function _getRouterQuote(address fromToken, address toToken, uint256 amount)
        internal
        returns (ILiquidityRouter.LiquidityQuote memory)
    {
        try liquidityRouter.getBestExecutionChain(
            fromToken, toToken, amount
        ) returns (ILiquidityRouter.LiquidityQuote memory quote) {
            return quote;
        } catch {
            return ILiquidityRouter.LiquidityQuote({chainId: 0, expectedOutput: 0, priceImpactBps: 0, gasEstimate: 0});
        }
    }

    function _buildDefaultQuote(uint256 amount) internal view returns (ILiquidityRouter.LiquidityQuote memory) {
        return ILiquidityRouter.LiquidityQuote({
            chainId: block.chainid, expectedOutput: amount, priceImpactBps: 0, gasEstimate: chainGasCosts[block.chainid]
        });
    }

    function receiveAndExecuteDCA(
        DCAExecution calldata execution,
        bytes calldata /*swapData*/
    )
        external
        override
        onlyMessenger
        nonReentrant
    {
        uint256 sourceChain = IL2ToL2CrossDomainMessenger(messenger).crossDomainMessageSource();
        address sourceSender = IL2ToL2CrossDomainMessenger(messenger).crossDomainMessageSender();
        if (trustedPeerModules[sourceChain] != sourceSender) revert Unauthorized();
        if (execution.sourceChain != sourceChain) revert InvalidTargetChain(execution.sourceChain, sourceChain);
        if (execution.targetChain != block.chainid) revert InvalidTargetChain(execution.targetChain, block.chainid);

        bytes32 executionId = keccak256(
            abi.encodePacked(
                execution.sourceChain,
                execution.user,
                execution.fromToken,
                execution.toToken,
                execution.amount,
                execution.initiatedAt
            )
        );

        DCAExecution storage stored = _executions[executionId];
        if (stored.initiatedAt == 0) {
            _executions[executionId] = execution;
            stored = _executions[executionId];
        }

        _handleLocalExecution(executionId);
    }

    function cancelDCA(bytes32 executionId) external override {
        DCAExecution storage execution = _executions[executionId];
        if (execution.initiatedAt == 0) revert ExecutionNotFound();
        if (execution.user != msg.sender && msg.sender != storage_.owner()) revert Unauthorized();
        if (
            execution.status == ExecutionStatus.Transferring || execution.status == ExecutionStatus.Executing
                || execution.status == ExecutionStatus.Completed
        ) {
            revert InvalidExecutionState();
        }
        execution.status = ExecutionStatus.Cancelled;
    }

    // ==================== ADMIN ====================

    function setChainGasCost(uint256 chainId, uint256 gasCost) external override onlyOwner {
        chainGasCosts[chainId] = gasCost;
    }

    function setSupportedChains(uint256[] calldata chainIds) external onlyOwner {
        supportedChains = chainIds;
    }

    function registerPeerModule(uint256 chainId, address moduleAddress) external onlyOwner {
        _setPeerModule(chainId, moduleAddress);
    }

    function setTrustedPeerModules(uint256[] calldata chainIds, address[] calldata moduleAddresses) external onlyOwner {
        if (chainIds.length != moduleAddresses.length) revert InvalidChainConfig();
        for (uint256 i = 0; i < chainIds.length; i++) {
            _setPeerModule(chainIds[i], moduleAddresses[i]);
        }
    }

    function setLiquidityRouter(address router) external onlyOwner {
        liquidityRouter = ILiquidityRouter(router);
        emit LiquidityRouterUpdated(router);
    }

    function configurePool(address token0, address token1, uint24 fee, int24 tickSpacing) external onlyOwner {
        require(token0 < token1, "Invalid order");
        bytes32 pairKey = keccak256(abi.encodePacked(token0, token1));

        poolConfigs[pairKey] = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        emit PoolConfigured(token0, token1, fee, tickSpacing);
    }

    function _getPoolKeyForPair(address tokenA, address tokenB) internal view returns (PoolKey memory) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 pairKey = keccak256(abi.encodePacked(token0, token1));

        PoolKey memory poolKey = poolConfigs[pairKey];
        require(Currency.unwrap(poolKey.currency0) != address(0), "Pool not configured");
        return poolKey;
    }

    // ==================== VIEWS ====================

    function getExecution(bytes32 executionId) external view override returns (DCAExecution memory execution) {
        execution = _executions[executionId];
        if (execution.initiatedAt == 0) revert ExecutionNotFound();
    }

    function supportedChainsLength() external view returns (uint256) {
        return supportedChains.length;
    }

    // ==================== INTERNAL HELPERS ====================

    function _isAuthorizedCaller(address user) internal view returns (bool) {
        if (msg.sender == user) return true;
        if (msg.sender == storage_.spendSaveHook()) return true;
        return storage_.authorizedModules(msg.sender);
    }

    function _handleLocalExecution(bytes32 executionId) private {
        DCAExecution storage stored = _executions[executionId];
        if (stored.initiatedAt == 0) revert ExecutionNotFound();

        if (stored.status == ExecutionStatus.Completed) return;

        DCAExecution memory execution = stored;

        stored.status = ExecutionStatus.Executing;

        uint256 available = storage_.savings(execution.user, execution.fromToken);
        if (available < execution.amount) {
            stored.status = ExecutionStatus.Pending;
            emit DCAExecutionPending(executionId, execution.user, execution.fromToken, execution.amount);
            return;
        }

        address dcaAddress;
        try storage_.dcaModule() returns (address moduleAddr) {
            dcaAddress = moduleAddr;
        } catch {
            stored.status = ExecutionStatus.Failed;
            emit DCAExecutionFailed(executionId, execution.user, "DCA_MODULE_NOT_REGISTERED");
            return;
        }

        IDCAModule dca = IDCAModule(dcaAddress);

        try dca.queueDCAExecution(execution.user, execution.fromToken, execution.toToken, execution.amount) {
            try dca.executeDCA(execution.user) returns (bool executedSwap, uint256 amountOut) {
                if (!executedSwap) {
                    stored.status = ExecutionStatus.Pending;
                    emit DCAExecutionPending(executionId, execution.user, execution.fromToken, execution.amount);
                    return;
                }

                if (amountOut < execution.minAmountOut) {
                    stored.status = ExecutionStatus.Failed;
                    emit DCAExecutionFailed(executionId, execution.user, "MIN_OUTPUT_NOT_MET");
                    return;
                }

                stored.status = ExecutionStatus.Completed;
                emit DCAExecutedOnChain(
                    executionId, execution.user, execution.toToken, execution.amount, amountOut, block.chainid
                );
            } catch (bytes memory reason) {
                stored.status = ExecutionStatus.Failed;
                emit DCAExecutionFailed(executionId, execution.user, _decodeRevert(reason));
            }
        } catch (bytes memory reason) {
            stored.status = ExecutionStatus.Failed;
            emit DCAExecutionFailed(executionId, execution.user, _decodeRevert(reason));
        }
    }

    function _initiateCrossChainExecution(bytes32 executionId) private {
        DCAExecution storage execution = _executions[executionId];
        if (execution.initiatedAt == 0) revert ExecutionNotFound();

        address peer = trustedPeerModules[execution.targetChain];
        if (peer == address(0)) revert PeerNotConfigured(execution.targetChain);

        bytes memory payload =
            abi.encodeCall(ICrossChainDCAModule.receiveAndExecuteDCA, (execution, abi.encode(execution.minAmountOut)));

        bytes32 messageHash = IL2ToL2CrossDomainMessenger(messenger).sendMessage(execution.targetChain, peer, payload);

        executionMessageHash[executionId] = messageHash;

        emit CrossChainDCARequestSent(executionId, execution.targetChain, messageHash);

        bytes32 savingsMessageHash;
        try crossChainModule.transferSavingsToChain(
            execution.targetChain, execution.user, execution.fromToken, execution.amount
        ) returns (bytes32 hash) {
            savingsMessageHash = hash;
        } catch (bytes memory reason) {
            _executions[executionId].status = ExecutionStatus.Failed;
            emit DCAExecutionFailed(executionId, execution.user, _decodeRevert(reason));
            return;
        }

        savingsTransferMessageHash[executionId] = savingsMessageHash;
        emit CrossChainSavingsTransferSent(executionId, savingsMessageHash);
    }

    function finalizePendingExecution(bytes32 executionId) external nonReentrant {
        DCAExecution storage execution = _executions[executionId];
        if (execution.initiatedAt == 0) revert ExecutionNotFound();
        if (!_isAuthorizedCaller(execution.user)) revert Unauthorized();
        if (execution.targetChain != block.chainid) revert InvalidTargetChain(execution.targetChain, block.chainid);

        _handleLocalExecution(executionId);
    }

    function _decodeRevert(bytes memory reason) internal pure returns (string memory) {
        if (reason.length < 68) return "execution reverted";
        assembly {
            reason := add(reason, 0x04)
        }
        return abi.decode(reason, (string));
    }

    function _setPeerModule(uint256 chainId, address moduleAddress) private {
        if (chainId == block.chainid || moduleAddress == address(0)) revert InvalidChainConfig();
        trustedPeerModules[chainId] = moduleAddress;
    }
}

