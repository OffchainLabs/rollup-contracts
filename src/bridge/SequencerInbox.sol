// Copyright 2021-2022, Offchain Labs, Inc.
// For license information, see https://github.com/OffchainLabs/nitro-contracts/blob/main/LICENSE
// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.24;

import {
    AlreadyInit,
    HadZeroInit,
    NotOrigin,
    DataTooLarge,
    NotRollup,
    DelayedBackwards,
    DelayedTooFar,
    ForceIncludeBlockTooSoon,
    ForceIncludeTimeTooSoon,
    IncorrectMessagePreimage,
    NotBatchPoster,
    BadSequencerNumber,
    DataNotAuthenticated,
    AlreadyValidDASKeyset,
    NoSuchKeyset,
    NotForked,
    NotBatchPosterManager,
    RollupNotChanged,
    DataBlobsNotSupported,
    InitParamZero,
    MissingDataHashes,
    InvalidBlobMetadata,
    NotOwner,
    RollupNotChanged,
    EmptyBatchData,
    InvalidHeaderFlag,
    NativeTokenMismatch,
    Deprecated,
    NotDelayBufferable,
    NotDelayedFarEnough,
    DelayProofRequired,
    NotDelayBufferable,
    ExtraGasNotUint64,
    KeysetTooLarge
} from "../libraries/Error.sol";
import "./IBridge.sol";
import "./IInboxBase.sol";
import "./ISequencerInbox.sol";
import "../rollup/IRollupLogic.sol";
import "../precompiles/ArbGasInfo.sol";
import "../precompiles/ArbSys.sol";
import "./DelayBuffer.sol";

import {L1MessageType_batchPostingReport} from "../libraries/MessageTypes.sol";
import "../libraries/DelegateCallAware.sol";
import {IGasRefunder} from "../libraries/IGasRefunder.sol";
import {GasRefundEnabled} from "../libraries/GasRefundEnabled.sol";
import {BlobDataHashReader} from "../libraries/BlobDataHashReader.sol";
import "../libraries/ArbitrumChecker.sol";
import {IERC20Bridge} from "./IERC20Bridge.sol";
import "./DelayBufferable.sol";

/**
 * @title Accepts batches from the sequencer and adds them to the rollup inbox.
 * @notice Contains the inbox accumulator which is the ordering of all data and transactions to be processed by the rollup.
 * As part of submitting a batch the sequencer is also expected to include items enqueued
 * in the delayed inbox (Bridge.sol). If items in the delayed inbox are not included by a
 * sequencer within a time limit they can be force included into the rollup inbox by anyone.
 */
contract SequencerInbox is GasRefundEnabled, DelayBufferable, ISequencerInbox {
    IBridge public immutable bridge;

    /// @inheritdoc ISequencerInbox
    uint256 public constant HEADER_LENGTH = 40;

    /// @inheritdoc ISequencerInbox
    bytes1 public constant DATA_AUTHENTICATED_FLAG = 0x40;

    /// @inheritdoc ISequencerInbox
    bytes1 public constant DATA_BLOB_HEADER_FLAG = DATA_AUTHENTICATED_FLAG | 0x10;

    /// @inheritdoc ISequencerInbox
    bytes1 public constant DAS_MESSAGE_HEADER_FLAG = 0x80;

    /// @inheritdoc ISequencerInbox
    bytes1 public constant TREE_DAS_MESSAGE_HEADER_FLAG = 0x08;

    /// @inheritdoc ISequencerInbox
    bytes1 public constant BROTLI_MESSAGE_HEADER_FLAG = 0x00;

    /// @inheritdoc ISequencerInbox
    bytes1 public constant ZERO_HEAVY_MESSAGE_HEADER_FLAG = 0x20;

    // GAS_PER_BLOB from EIP-4844
    uint256 internal constant GAS_PER_BLOB = 1 << 17;

    IOwnable public rollup;

    mapping(address => BatchPosterData) internal batchPosterData;

    mapping(bytes32 => DasKeySetInfo) public dasKeySetInfo;

    modifier onlyRollupOwner() {
        if (msg.sender != rollup.owner()) revert NotOwner(msg.sender, rollup.owner());
        _;
    }

    modifier onlyRollupOwnerOrBatchPosterManager() {
        if (msg.sender != rollup.owner() && msg.sender != batchPosterManager) {
            revert NotBatchPosterManager(msg.sender);
        }
        _;
    }

    mapping(address => bool) public isSequencer;

    /// @inheritdoc ISequencerInbox
    address public batchPosterManager;

    uint256 internal immutable deployTimeChainId = block.chainid;

    // On L1 this should be set to 117964: 90% of Geth's 128KB tx size limit, leaving ~13KB for proving
    uint256 public immutable maxDataSize;
    // If the chain this SequencerInbox is deployed on is an Arbitrum chain.
    bool internal immutable hostChainIsArbitrum = ArbitrumChecker.runningOnArbitrum();
    // True if the chain this SequencerInbox is deployed on uses custom fee token
    bool public immutable isUsingFeeToken;
    // True the SequencerInbox is delay bufferable
    bool public immutable isDelayBufferable;

    constructor(
        IBridge bridge_,
        ISequencerInbox.MaxTimeVariation memory maxTimeVariation_,
        IDelayBufferable.ReplenishRate memory replenishRate_,
        IDelayBufferable.Config memory config_,
        uint256 _maxDataSize,
        bool _isUsingFeeToken
    ) DelayBufferable(maxTimeVariation_, replenishRate_, config_) {
        if (bridge_ == IBridge(address(0))) revert HadZeroInit();
        bridge = bridge_;
        rollup = bridge_.rollup();
        maxDataSize = _maxDataSize;
        isUsingFeeToken = _isUsingFeeToken;
        isDelayBufferable =
            config_.thresholdBlocks != type(uint64).max ||
            config_.thresholdSeconds != type(uint64).max;
        if (
            isDelayBufferable && bridge.delayedMessageCount() == bridge.totalDelayedMessagesRead()
        ) {
            // if the delayed message count is equal to the total delayed messages
            // then the sequencer inbox is in sync and the sync validity window
            // can be set to the current block and timestamp
            updateSyncValidity(uint64(block.number), uint64(block.timestamp));
        }
    }

    function maxTimeVariationInternal()
        internal
        view
        returns (
            uint64,
            uint64,
            uint64,
            uint64
        )
    {
        if (_chainIdChanged()) {
            return (1, 1, 1, 1);
        } else if (!isDelayBufferable) {
            return (delayBlocks, futureBlocks, delaySeconds, futureSeconds);
        } else if (isFullBufferSyncCacheValid()) {
            return maxTimeVariationBufferable(maxBufferBlocks, maxBufferSeconds);
        } else {
            return
                maxTimeVariationBufferable(
                    delayBufferData.bufferBlocks,
                    delayBufferData.bufferSeconds
                );
        }
    }

    function _chainIdChanged() internal view returns (bool) {
        return deployTimeChainId != block.chainid;
    }

    /// @inheritdoc ISequencerInbox
    function updateRollupAddress() external {
        if (msg.sender != IOwnable(rollup).owner())
            revert NotOwner(msg.sender, IOwnable(rollup).owner());
        IOwnable newRollup = bridge.rollup();
        if (rollup == newRollup) revert RollupNotChanged();
        rollup = newRollup;
    }

    /// @inheritdoc ISequencerInbox
    function totalDelayedMessagesRead() public view returns (uint256) {
        return bridge.totalDelayedMessagesRead();
    }

    function getTimeBounds() internal view virtual returns (IBridge.TimeBounds memory) {
        IBridge.TimeBounds memory bounds;
        (
            uint64 delayBlocks_,
            uint64 futureBlocks_,
            uint64 delaySeconds_,
            uint64 futureSeconds_
        ) = maxTimeVariationInternal();
        if (block.timestamp > delaySeconds_) {
            bounds.minTimestamp = uint64(block.timestamp) - delaySeconds_;
        }
        bounds.maxTimestamp = uint64(block.timestamp) + futureSeconds_;
        if (block.number > delayBlocks_) {
            bounds.minBlockNumber = uint64(block.number) - delayBlocks_;
        }
        bounds.maxBlockNumber = uint64(block.number) + futureBlocks_;
        return bounds;
    }

    function maxTimeVariation()
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        (
            uint64 delayBlocks_,
            uint64 futureBlocks_,
            uint64 delaySeconds_,
            uint64 futureSeconds_
        ) = maxTimeVariationInternal();

        return (
            uint256(delayBlocks_),
            uint256(futureBlocks_),
            uint256(delaySeconds_),
            uint256(futureSeconds_)
        );
    }

    /// @inheritdoc ISequencerInbox
    function forceInclusion(
        uint256 _totalDelayedMessagesRead,
        uint8 kind,
        uint64[2] calldata l1BlockAndTime,
        uint256 baseFeeL1,
        address sender,
        bytes32 messageDataHash
    ) external {
        if (_totalDelayedMessagesRead <= totalDelayedMessagesRead()) revert DelayedBackwards();
        bytes32 messageHash = Messages.messageHash(
            kind,
            sender,
            l1BlockAndTime[0],
            l1BlockAndTime[1],
            _totalDelayedMessagesRead - 1,
            baseFeeL1,
            messageDataHash
        );

        if (isDelayBufferable) {
            // buffer updates are applied retroactively, so we need to update the buffer state
            // first to apply any pending decrements before we check if the message is past the
            // force inclusion threshold
            updateBuffers(l1BlockAndTime[0], l1BlockAndTime[1]);
        }
        (uint256 delayBlocks_, , uint256 delaySeconds_, ) = maxTimeVariationInternal();
        // Can only force-include after the Sequencer-only window has expired.
        if (l1BlockAndTime[0] + delayBlocks_ >= block.number) revert ForceIncludeBlockTooSoon();
        if (l1BlockAndTime[1] + delaySeconds_ >= block.timestamp) revert ForceIncludeTimeTooSoon();

        // Verify that message hash represents the last message sequence of delayed message to be included
        {
            bytes32 prevDelayedAcc = 0;
            if (_totalDelayedMessagesRead > 1) {
                prevDelayedAcc = bridge.delayedInboxAccs(_totalDelayedMessagesRead - 2);
            }
            if (
                bridge.delayedInboxAccs(_totalDelayedMessagesRead - 1) !=
                Messages.accumulateInboxMessage(prevDelayedAcc, messageHash)
            ) revert IncorrectMessagePreimage();
        }

        (bytes32 dataHash, IBridge.TimeBounds memory timeBounds) = formEmptyDataHash(
            _totalDelayedMessagesRead
        );
        uint256 prevSeqMsgCount = bridge.sequencerReportedSubMessageCount();
        uint256 newSeqMsgCount = prevSeqMsgCount +
            _totalDelayedMessagesRead -
            totalDelayedMessagesRead();

        bridge.enqueueSequencerMessage(
            dataHash,
            _totalDelayedMessagesRead,
            prevSeqMsgCount,
            newSeqMsgCount,
            timeBounds,
            IBridge.BatchDataLocation.NoData
        );
    }

    function addSequencerL2BatchFromOrigin(
        uint256 sequenceNumber,
        bytes calldata data,
        uint256 afterDelayedMessagesRead,
        IGasRefunder gasRefunder,
        uint256 prevMessageCount,
        uint256 newMessageCount
    ) external refundsGas(gasRefunder, false) {
        // solhint-disable-next-line avoid-tx-origin
        if (msg.sender != tx.origin) revert NotOrigin();
        if (!isBatchPoster(msg.sender)) revert NotBatchPoster();
        if (isDelayBufferable && !isSynced()) {
            if (afterDelayedMessagesRead > bridge.totalDelayedMessagesRead()) {
                revert DelayProofRequired();
            }
            // if no new delayed messages are read, no buffer updates can be applied
            // and there are no new delayed messages to prove delays, so no proof is required
        }

        (bytes32 dataHash, IBridge.TimeBounds memory timeBounds) = formCallDataHash(
            data,
            afterDelayedMessagesRead
        );

        (uint256 seqMessageIndex, , , ) = bridge.enqueueSequencerMessage(
            dataHash,
            afterDelayedMessagesRead,
            prevMessageCount,
            newMessageCount,
            timeBounds,
            IBridge.BatchDataLocation.TxInput
        );

        // ~uint256(0) is type(uint256).max, but ever so slightly cheaper
        if (seqMessageIndex != sequenceNumber && sequenceNumber != ~uint256(0)) {
            revert BadSequencerNumber(seqMessageIndex, sequenceNumber);
        }

        if (!isUsingFeeToken) {
            // only report batch poster spendings if chain is using ETH as native currency
            submitBatchSpendingReport(dataHash, seqMessageIndex, block.basefee, 0);
        }
    }

    /// @inheritdoc ISequencerInbox
    function addSequencerL2BatchFromBlobs(
        uint256 sequenceNumber,
        uint256 afterDelayedMessagesRead,
        IGasRefunder gasRefunder,
        uint256 prevMessageCount,
        uint256 newMessageCount
    ) external refundsGas(gasRefunder, true) {
        if (!isBatchPoster(msg.sender)) revert NotBatchPoster();
        if (isDelayBufferable && !isSynced()) {
            if (afterDelayedMessagesRead > bridge.totalDelayedMessagesRead()) {
                revert DelayProofRequired();
            }
            // if no new delayed messages are read, no buffer updates can be applied
            // and there are no new delayed messages to prove delays, so no proof is required
        }
        addSequencerL2BatchFromBlobsImpl(
            sequenceNumber,
            afterDelayedMessagesRead,
            prevMessageCount,
            newMessageCount
        );
    }

    /// @inheritdoc ISequencerInbox
    function addSequencerL2BatchFromBlobs(
        uint256 sequenceNumber,
        uint256 afterDelayedMessagesRead,
        IGasRefunder gasRefunder,
        uint256 prevMessageCount,
        uint256 newMessageCount,
        bytes32 beforeDelayedAcc,
        Messages.Message calldata delayedMessage
    ) external refundsGas(gasRefunder, true) {
        if (!isBatchPoster(msg.sender)) revert NotBatchPoster();
        if (!isDelayBufferable) revert NotDelayBufferable();

        // must read atleast 1 new delayed message
        uint256 _totalDelayedMessagesRead = bridge.totalDelayedMessagesRead();
        if (afterDelayedMessagesRead <= _totalDelayedMessagesRead) revert NotDelayedFarEnough();

        // validate the delayed message against the delayed accumulator
        bytes32 delayedAcc = bridge.delayedInboxAccs(_totalDelayedMessagesRead);
        sync(delayedAcc, beforeDelayedAcc, delayedMessage);

        addSequencerL2BatchFromBlobsImpl(
            sequenceNumber,
            afterDelayedMessagesRead,
            prevMessageCount,
            newMessageCount
        );
    }

    /// @inheritdoc ISequencerInbox
    function addSequencerL2BatchFromOrigin(
        uint256 sequenceNumber,
        bytes calldata data,
        uint256 afterDelayedMessagesRead,
        IGasRefunder gasRefunder,
        uint256 prevMessageCount,
        uint256 newMessageCount,
        bytes32 beforeDelayedAcc,
        Messages.Message calldata delayedMessage
    ) external refundsGas(gasRefunder, true) {
        // solhint-disable-next-line avoid-tx-origin
        if (msg.sender != tx.origin) revert NotOrigin();
        if (!isBatchPoster(msg.sender)) revert NotBatchPoster();
        if (!isDelayBufferable) revert NotDelayBufferable();

        // must read atleast 1 new delayed message
        uint256 _totalDelayedMessagesRead = bridge.totalDelayedMessagesRead();
        if (afterDelayedMessagesRead <= _totalDelayedMessagesRead) revert NotDelayedFarEnough();

        // validate the delayed message against the delayed accumulator
        bytes32 delayedAcc = bridge.delayedInboxAccs(_totalDelayedMessagesRead);
        sync(delayedAcc, beforeDelayedAcc, delayedMessage);

        addSequencerL2BatchFromOriginImpl(
            sequenceNumber,
            data,
            afterDelayedMessagesRead,
            prevMessageCount,
            newMessageCount
        );
    }

    /// @inheritdoc ISequencerInbox
    function addSequencerL2BatchFromBlobs(
        uint256 sequenceNumber,
        uint256 afterDelayedMessagesRead,
        IGasRefunder gasRefunder,
        uint256 prevMessageCount,
        uint256 newMessageCount,
        bytes32 beforeDelayedAcc,
        Messages.Message calldata delayedMessage,
        Messages.InboxAccPreimage calldata preimage
    ) external refundsGas(gasRefunder, true) {
        if (!isBatchPoster(msg.sender)) revert NotBatchPoster();
        if (!isDelayBufferable) revert NotDelayBufferable();
        bytes32 beforeAcc = addSequencerL2BatchFromBlobsImpl(
            sequenceNumber,
            afterDelayedMessagesRead,
            prevMessageCount,
            newMessageCount
        );

        resync(beforeDelayedAcc, delayedMessage, beforeAcc, preimage);
    }

    /// @inheritdoc ISequencerInbox
    function addSequencerL2BatchFromOrigin(
        uint256 sequenceNumber,
        bytes calldata data,
        uint256 afterDelayedMessagesRead,
        IGasRefunder gasRefunder,
        uint256 prevMessageCount,
        uint256 newMessageCount,
        bytes32 beforeDelayedAcc,
        Messages.Message calldata delayedMessage,
        Messages.InboxAccPreimage calldata preimage
    ) external refundsGas(gasRefunder, true) {
        // solhint-disable-next-line avoid-tx-origin
        if (msg.sender != tx.origin) revert NotOrigin();
        if (!isBatchPoster(msg.sender)) revert NotBatchPoster();
        if (!isDelayBufferable) revert NotDelayBufferable();
        bytes32 beforeAcc = addSequencerL2BatchFromOriginImpl(
            sequenceNumber,
            data,
            afterDelayedMessagesRead,
            prevMessageCount,
            newMessageCount
        );

        resync(beforeDelayedAcc, delayedMessage, beforeAcc, preimage);
    }

    function addSequencerL2BatchFromBlobsImpl(
        uint256 sequenceNumber,
        uint256 afterDelayedMessagesRead,
        uint256 prevMessageCount,
        uint256 newMessageCount
    ) internal returns (bytes32) {
        (
            bytes32 dataHash,
            IBridge.TimeBounds memory timeBounds,
            uint256 blobGas
        ) = formBlobDataHash(afterDelayedMessagesRead);

        (uint256 seqMessageIndex, bytes32 beforeAcc, , ) = bridge.enqueueSequencerMessage(
            dataHash,
            afterDelayedMessagesRead,
            prevMessageCount,
            newMessageCount,
            timeBounds,
            IBridge.BatchDataLocation.Blob
        );

        // ~uint256(0) is type(uint256).max, but ever so slightly cheaper
        if (seqMessageIndex != sequenceNumber && sequenceNumber != ~uint256(0)) {
            revert BadSequencerNumber(seqMessageIndex, sequenceNumber);
        }

        // blobs are currently not supported on host arbitrum chains, when support is added it may
        // consume gas in a different way to L1, so explicitly block host arb chains so that if support for blobs
        // on arb is added it will need to explicitly turned on in the sequencer inbox
        if (hostChainIsArbitrum) revert DataBlobsNotSupported();

        // submit a batch spending report to refund the entity that produced the blob batch data
        // same as using calldata, we only submit spending report if the caller is the origin of the tx
        // such that one cannot "double-claim" batch posting refund in the same tx
        // solhint-disable-next-line avoid-tx-origin
        if (msg.sender == tx.origin && !isUsingFeeToken) {
            submitBatchSpendingReport(dataHash, seqMessageIndex, block.basefee, blobGas);
        }

        return beforeAcc;
    }

    function addSequencerL2BatchFromOriginImpl(
        uint256 sequenceNumber,
        bytes calldata data,
        uint256 afterDelayedMessagesRead,
        uint256 prevMessageCount,
        uint256 newMessageCount
    ) internal returns (bytes32) {
        (bytes32 dataHash, IBridge.TimeBounds memory timeBounds) = formCallDataHash(
            data,
            afterDelayedMessagesRead
        );

        (uint256 seqMessageIndex, bytes32 beforeAcc, , ) = bridge.enqueueSequencerMessage(
            dataHash,
            afterDelayedMessagesRead,
            prevMessageCount,
            newMessageCount,
            timeBounds,
            IBridge.BatchDataLocation.TxInput
        );

        // ~uint256(0) is type(uint256).max, but ever so slightly cheaper
        if (seqMessageIndex != sequenceNumber && sequenceNumber != ~uint256(0)) {
            revert BadSequencerNumber(seqMessageIndex, sequenceNumber);
        }

        if (!isUsingFeeToken) {
            // only report batch poster spendings if chain is using ETH as native currency
            submitBatchSpendingReport(dataHash, seqMessageIndex, block.basefee, 0);
        }

        return beforeAcc;
    }

    function addSequencerL2Batch(
        uint256 sequenceNumber,
        bytes calldata data,
        uint256 afterDelayedMessagesRead,
        IGasRefunder gasRefunder,
        uint256 prevMessageCount,
        uint256 newMessageCount
    ) external override refundsGas(gasRefunder, false) {
        if (!isBatchPoster(msg.sender) && msg.sender != address(rollup)) revert NotBatchPoster();
        if (isDelayBufferable && !isSynced()) {
            if (afterDelayedMessagesRead != bridge.totalDelayedMessagesRead()) {
                revert DelayProofRequired();
            }
            // if no new delayed messages are read, no buffer updates can be applied
            // and there are no new delayed messages to prove delays, so no proof is required
        }
        (bytes32 dataHash, IBridge.TimeBounds memory timeBounds) = formCallDataHash(
            data,
            afterDelayedMessagesRead
        );

        (uint256 seqMessageIndex, , , ) = bridge.enqueueSequencerMessage(
            dataHash,
            afterDelayedMessagesRead,
            prevMessageCount,
            newMessageCount,
            timeBounds,
            IBridge.BatchDataLocation.SeparateBatchEvent
        );

        // ~uint256(0) is type(uint256).max, but ever so slightly cheaper
        if (seqMessageIndex != sequenceNumber && sequenceNumber != ~uint256(0)) {
            revert BadSequencerNumber(seqMessageIndex, sequenceNumber);
        }

        emit SequencerBatchData(sequenceNumber, data);
    }

    function packHeader(uint256 afterDelayedMessagesRead)
        internal
        view
        returns (bytes memory, IBridge.TimeBounds memory)
    {
        IBridge.TimeBounds memory timeBounds = getTimeBounds();
        bytes memory header = abi.encodePacked(
            timeBounds.minTimestamp,
            timeBounds.maxTimestamp,
            timeBounds.minBlockNumber,
            timeBounds.maxBlockNumber,
            uint64(afterDelayedMessagesRead)
        );
        // This must always be true from the packed encoding
        assert(header.length == HEADER_LENGTH);
        return (header, timeBounds);
    }

    /// @dev    Form a hash for a sequencer message with no batch data
    /// @param  afterDelayedMessagesRead The delayed messages count read up to
    /// @return The data hash
    /// @return The timebounds within which the message should be processed
    function formEmptyDataHash(uint256 afterDelayedMessagesRead)
        internal
        view
        returns (bytes32, IBridge.TimeBounds memory)
    {
        (bytes memory header, IBridge.TimeBounds memory timeBounds) = packHeader(
            afterDelayedMessagesRead
        );
        return (keccak256(header), timeBounds);
    }

    /// @dev    Since the data is supplied from calldata, the batch poster can choose the data type
    ///         We need to ensure that this data cannot cause a collision with data supplied via another method (eg blobs)
    ///         therefore we restrict which flags can be provided as a header in this field
    ///         This also safe guards unused flags for future use, as we know they would have been disallowed up until this point
    /// @param  headerByte The first byte in the calldata
    function isValidCallDataFlag(bytes1 headerByte) internal pure returns (bool) {
        return
            headerByte == BROTLI_MESSAGE_HEADER_FLAG ||
            headerByte == DAS_MESSAGE_HEADER_FLAG ||
            (headerByte == (DAS_MESSAGE_HEADER_FLAG | TREE_DAS_MESSAGE_HEADER_FLAG)) ||
            headerByte == ZERO_HEAVY_MESSAGE_HEADER_FLAG;
    }

    /// @dev    Form a hash of the data taken from the calldata
    /// @param  data The calldata to be hashed
    /// @param  afterDelayedMessagesRead The delayed messages count read up to
    /// @return The data hash
    /// @return The timebounds within which the message should be processed
    function formCallDataHash(bytes calldata data, uint256 afterDelayedMessagesRead)
        internal
        view
        returns (bytes32, IBridge.TimeBounds memory)
    {
        uint256 fullDataLen = HEADER_LENGTH + data.length;
        if (fullDataLen > maxDataSize) revert DataTooLarge(fullDataLen, maxDataSize);

        (bytes memory header, IBridge.TimeBounds memory timeBounds) = packHeader(
            afterDelayedMessagesRead
        );

        // the batch poster is allowed to submit an empty batch, they can use this to progress the
        // delayed inbox without providing extra batch data
        if (data.length > 0) {
            // The first data byte cannot be the same as any that have been set via other methods (eg 4844 blob header) as this
            // would allow the supplier of the data to spoof an incorrect 4844 data batch
            if (!isValidCallDataFlag(data[0])) revert InvalidHeaderFlag(data[0]);

            // the first byte is used to identify the type of batch data
            // das batches expect to have the type byte set, followed by the keyset (so they should have at least 33 bytes)
            // if invalid data is supplied here the state transition function will process it as an empty block
            // however we can provide a nice additional check here for the batch poster
            if (data[0] & DAS_MESSAGE_HEADER_FLAG != 0 && data.length >= 33) {
                // we skip the first byte, then read the next 32 bytes for the keyset
                bytes32 dasKeysetHash = bytes32(data[1:33]);
                if (!dasKeySetInfo[dasKeysetHash].isValidKeyset) revert NoSuchKeyset(dasKeysetHash);
            }
        }
        return (keccak256(bytes.concat(header, data)), timeBounds);
    }

    /// @dev   Form a hash of the data being provided in 4844 data blobs
    /// @param afterDelayedMessagesRead The delayed messages count read up to
    /// @return The data hash
    /// @return The timebounds within which the message should be processed
    /// @return The normalized amount of gas used for blob posting
    function formBlobDataHash(uint256 afterDelayedMessagesRead)
        internal
        view
        returns (
            bytes32,
            IBridge.TimeBounds memory,
            uint256
        )
    {
        bytes32[] memory dataHashes = BlobDataHashReader.getDataHashes();
        if (dataHashes.length == 0) revert MissingDataHashes();

        (bytes memory header, IBridge.TimeBounds memory timeBounds) = packHeader(
            afterDelayedMessagesRead
        );

        uint256 blobCost = block.blobbasefee * GAS_PER_BLOB * dataHashes.length;
        return (
            keccak256(bytes.concat(header, DATA_BLOB_HEADER_FLAG, abi.encodePacked(dataHashes))),
            timeBounds,
            block.basefee > 0 ? blobCost / block.basefee : 0
        );
    }

    /// @dev   Submit a batch spending report message so that the batch poster can be reimbursed on the rollup
    ///        This function expect msg.sender is tx.origin, and will always record tx.origin as the spender
    /// @param dataHash The hash of the message the spending report is being submitted for
    /// @param seqMessageIndex The index of the message to submit the spending report for
    /// @param gasPrice The gas price that was paid for the data (standard gas or data gas)
    function submitBatchSpendingReport(
        bytes32 dataHash,
        uint256 seqMessageIndex,
        uint256 gasPrice,
        uint256 extraGas
    ) internal {
        // report the account who paid the gas (tx.origin) for the tx as batch poster
        // if msg.sender is used and is a contract, it might not be able to spend the refund on l2
        // solhint-disable-next-line avoid-tx-origin
        address batchPoster = tx.origin;

        // this msg isn't included in the current sequencer batch, but instead added to
        // the delayed messages queue that is yet to be included
        if (hostChainIsArbitrum) {
            // Include extra gas for the host chain's L1 gas charging
            uint256 l1Fees = ArbGasInfo(address(0x6c)).getCurrentTxL1GasFees();
            extraGas += l1Fees / block.basefee;
        }
        if (extraGas > type(uint64).max) revert ExtraGasNotUint64();
        bytes memory spendingReportMsg = abi.encodePacked(
            block.timestamp,
            batchPoster,
            dataHash,
            seqMessageIndex,
            gasPrice,
            uint64(extraGas)
        );

        uint256 msgNum = bridge.submitBatchSpendingReport(
            batchPoster,
            keccak256(spendingReportMsg)
        );
        // this is the same event used by Inbox.sol after including a message to the delayed message accumulator
        emit InboxMessageDelivered(msgNum, spendingReportMsg);
    }

    function inboxAccs(uint256 index) external view returns (bytes32) {
        return bridge.sequencerInboxAccs(index);
    }

    function batchCount() external view returns (uint256) {
        return bridge.sequencerMessageCount();
    }

    /// @inheritdoc ISequencerInbox
    function setIsBatchPoster(address addr, bool isBatchPoster_)
        public
        onlyRollupOwnerOrBatchPosterManager
    {
        batchPosterData[addr].isBatchPoster = isBatchPoster_;
        // we used to have OwnerFunctionCalled(0) for setting the maxTimeVariation
        // so we dont use index = 0 here, even though this is the first owner function
        // to stay compatible with legacy events
        emit OwnerFunctionCalled(1);
    }

    /// @inheritdoc ISequencerInbox
    function setValidKeyset(bytes calldata keysetBytes) external onlyRollupOwner {
        uint256 ksWord = uint256(keccak256(bytes.concat(hex"fe", keccak256(keysetBytes))));
        bytes32 ksHash = bytes32(ksWord ^ (1 << 255));
        if (keysetBytes.length >= 64 * 1024) revert KeysetTooLarge();

        if (dasKeySetInfo[ksHash].isValidKeyset) revert AlreadyValidDASKeyset(ksHash);
        uint256 creationBlock = block.number;
        if (hostChainIsArbitrum) {
            creationBlock = ArbSys(address(100)).arbBlockNumber();
        }
        dasKeySetInfo[ksHash] = DasKeySetInfo({
            isValidKeyset: true,
            creationBlock: uint64(creationBlock)
        });
        emit SetValidKeyset(ksHash, keysetBytes);
        emit OwnerFunctionCalled(2);
    }

    /// @inheritdoc ISequencerInbox
    function invalidateKeysetHash(bytes32 ksHash) external onlyRollupOwner {
        if (!dasKeySetInfo[ksHash].isValidKeyset) revert NoSuchKeyset(ksHash);
        // we don't delete the block creation value since its used to fetch the SetValidKeyset
        // event efficiently. The event provides the hash preimage of the key.
        // this is still needed when syncing the chain after a keyset is invalidated.
        dasKeySetInfo[ksHash].isValidKeyset = false;
        emit InvalidateKeyset(ksHash);
        emit OwnerFunctionCalled(3);
    }

    /// @inheritdoc ISequencerInbox
    function setIsSequencer(address addr, bool isSequencer_)
        external
        onlyRollupOwnerOrBatchPosterManager
    {
        isSequencer[addr] = isSequencer_;
        emit OwnerFunctionCalled(4); // Owner in this context can also be batch poster manager
    }

    /// @inheritdoc ISequencerInbox
    function setBatchPosterManager(address newBatchPosterManager) external onlyRollupOwner {
        batchPosterManager = newBatchPosterManager;
        emit OwnerFunctionCalled(5);
    }

    function isValidKeysetHash(bytes32 ksHash) external view returns (bool) {
        return dasKeySetInfo[ksHash].isValidKeyset;
    }

    /// @inheritdoc ISequencerInbox
    function getKeysetCreationBlock(bytes32 ksHash) external view returns (uint256) {
        DasKeySetInfo memory ksInfo = dasKeySetInfo[ksHash];
        if (ksInfo.creationBlock == 0) revert NoSuchKeyset(ksHash);
        return uint256(ksInfo.creationBlock);
    }

    function isBatchPoster(address addr) public view override returns (bool) {
        return batchPosterData[addr].isBatchPoster;
    }

    /// @notice Returns true if the inbox is in a synced state (no unexpected delays are possible) and the buffer is full
    function isFullBufferSyncCacheValid() internal view override returns (bool) {
        return (block.number <= batchPosterData[msg.sender].cachedBlockNumber &&
            block.timestamp <= batchPosterData[msg.sender].cachedTimestamp);
    }

    /// @notice Packs full buffer & synced state with batchPoster authentication
    function cacheFullBufferSyncExpiry(uint64 expiryBlockNumber, uint64 expiryTimestamp)
        internal
        override
    {
        batchPosterData[msg.sender].cachedBlockNumber = expiryBlockNumber;
        batchPosterData[msg.sender].cachedTimestamp = expiryTimestamp;
    }
}
