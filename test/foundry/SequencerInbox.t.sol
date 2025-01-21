// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

import "forge-std/Test.sol";
import "./util/TestUtil.sol";
import "../../src/bridge/Bridge.sol";
import "../../src/bridge/SequencerInbox.sol";
import {ERC20Bridge} from "../../src/bridge/ERC20Bridge.sol";
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";

contract RollupMock {
    address public immutable owner;

    constructor(
        address _owner
    ) {
        owner = _owner;
    }
}

contract SequencerInboxTest is Test {
    // cannot reference events outside of the original contract until 0.8.21
    // we currently use 0.8.9
    event MessageDelivered(
        uint256 indexed messageIndex,
        bytes32 indexed beforeInboxAcc,
        address inbox,
        uint8 kind,
        address sender,
        bytes32 messageDataHash,
        uint256 baseFeeL1,
        uint64 timestamp
    );
    event InboxMessageDelivered(uint256 indexed messageNum, bytes data);
    event SequencerBatchDelivered(
        uint256 indexed batchSequenceNumber,
        bytes32 indexed beforeAcc,
        bytes32 indexed afterAcc,
        bytes32 delayedAcc,
        uint256 afterDelayedMessagesRead,
        IBridge.TimeBounds timeBounds,
        IBridge.BatchDataLocation dataLocation
    );
    event OwnerFunctionCalled(uint256 indexed id);

    Random RAND = new Random();
    address rollupOwner = address(137);
    uint256 maxDataSize = 10000;
    ISequencerInbox.MaxTimeVariation maxTimeVariation = ISequencerInbox.MaxTimeVariation({
        delayBlocks: 10,
        futureBlocks: 10,
        delaySeconds: 100,
        futureSeconds: 100
    });
    BufferConfig bufferConfigDefault = BufferConfig({
        threshold: type(uint64).max,
        max: type(uint64).max,
        replenishRateInBasis: 714
    });
    address dummyInbox = address(139);
    address proxyAdmin = address(140);
    IReader4844 dummyReader4844 = IReader4844(address(137));

    uint256 public constant MAX_DATA_SIZE = 117964;

    function deployRollup(
        bool isArbHosted,
        bool isDelayBufferable,
        BufferConfig memory bufferConfig
    ) internal returns (SequencerInbox, Bridge, address) {
        RollupMock rollupMock = new RollupMock(rollupOwner);
        Bridge bridgeImpl = new Bridge();
        Bridge bridge =
            Bridge(address(new TransparentUpgradeableProxy(address(bridgeImpl), proxyAdmin, "")));

        bridge.initialize(IOwnable(address(rollupMock)));
        vm.prank(rollupOwner);
        bridge.setDelayedInbox(dummyInbox, true);

        SequencerInbox seqInboxImpl = new SequencerInbox(
            maxDataSize,
            isArbHosted ? IReader4844(address(0)) : dummyReader4844,
            false,
            isDelayBufferable
        );
        SequencerInbox seqInbox = SequencerInbox(
            address(new TransparentUpgradeableProxy(address(seqInboxImpl), proxyAdmin, ""))
        );
        seqInbox.initialize(bridge, maxTimeVariation, bufferConfig, IFeeTokenPricer(address(0)));

        vm.prank(rollupOwner);
        seqInbox.setIsBatchPoster(tx.origin, true);

        vm.prank(rollupOwner);
        bridge.setSequencerInbox(address(seqInbox));

        return (seqInbox, bridge, address(seqInboxImpl));
    }

    function deployFeeTokenBasedRollup() internal returns (SequencerInbox, ERC20Bridge) {
        RollupMock rollupMock = new RollupMock(rollupOwner);
        ERC20Bridge bridgeImpl = new ERC20Bridge();
        ERC20Bridge bridge = ERC20Bridge(
            address(new TransparentUpgradeableProxy(address(bridgeImpl), proxyAdmin, ""))
        );
        address nativeToken = address(new ERC20PresetMinterPauser("Appchain Token", "App"));

        bridge.initialize(IOwnable(address(rollupMock)), nativeToken);
        vm.prank(rollupOwner);
        bridge.setDelayedInbox(dummyInbox, true);

        /// this will result in 'hostChainIsArbitrum = true'
        vm.mockCall(
            address(100),
            abi.encodeWithSelector(ArbSys.arbOSVersion.selector),
            abi.encode(uint256(11))
        );
        SequencerInbox seqInboxImpl =
            new SequencerInbox(maxDataSize, IReader4844(address(0)), true, false);
        SequencerInbox seqInbox = SequencerInbox(
            address(new TransparentUpgradeableProxy(address(seqInboxImpl), proxyAdmin, ""))
        );
        seqInbox.initialize(
            bridge,
            maxTimeVariation,
            bufferConfigDefault,
            IFeeTokenPricer(makeAddr("feeTokenPricer"))
        );

        vm.prank(rollupOwner);
        seqInbox.setIsBatchPoster(tx.origin, true);

        vm.prank(rollupOwner);
        bridge.setSequencerInbox(address(seqInbox));

        return (seqInbox, bridge);
    }

    function expectEvents(
        IBridge bridge,
        SequencerInbox seqInbox,
        bytes memory data,
        bool hostChainIsArbitrum,
        bool isUsingFeeToken,
        uint256 exchangeRate
    ) internal {
        uint256 delayedMessagesRead = bridge.delayedMessageCount();
        uint256 sequenceNumber = bridge.sequencerMessageCount();
        IBridge.TimeBounds memory timeBounds;
        if (block.timestamp > maxTimeVariation.delaySeconds) {
            timeBounds.minTimestamp = uint64(block.timestamp - maxTimeVariation.delaySeconds);
        }
        timeBounds.maxTimestamp = uint64(block.timestamp + maxTimeVariation.futureSeconds);
        if (block.number > maxTimeVariation.delayBlocks) {
            timeBounds.minBlockNumber = uint64(block.number - maxTimeVariation.delayBlocks);
        }
        timeBounds.maxBlockNumber = uint64(block.number + maxTimeVariation.futureBlocks);
        bytes32 dataHash = keccak256(
            bytes.concat(
                abi.encodePacked(
                    timeBounds.minTimestamp,
                    timeBounds.maxTimestamp,
                    timeBounds.minBlockNumber,
                    timeBounds.maxBlockNumber,
                    uint64(delayedMessagesRead)
                ),
                data
            )
        );

        // calculate expected spending report message
        bytes memory expectedSpendingReportMsg = "";
        {
            uint256 expectedReportedExtraGas = 0;
            if (hostChainIsArbitrum) {
                // set 0.1 gwei basefee
                uint256 basefee = 100000000;
                vm.fee(basefee);
                // 30 gwei TX L1 fees
                uint256 l1Fees = 30000000000;
                vm.mockCall(
                    address(0x6c),
                    abi.encodeWithSignature("getCurrentTxL1GasFees()"),
                    abi.encode(l1Fees)
                );
                expectedReportedExtraGas = l1Fees / basefee;
            }

            uint256 expectedReportedGasPrice = block.basefee;
            if (isUsingFeeToken && address(seqInbox.feeTokenPricer()) != address(0)) {
                // calculate the scaled gas price for reporting
                expectedReportedGasPrice = (expectedReportedGasPrice * exchangeRate) / 1e18;
            }
            expectedSpendingReportMsg = abi.encodePacked(
                block.timestamp,
                msg.sender,
                dataHash,
                sequenceNumber,
                expectedReportedGasPrice,
                uint64(expectedReportedExtraGas)
            );
        }

        bytes32 beforeAcc = bytes32(0);
        bytes32 delayedAcc = bridge.delayedInboxAccs(delayedMessagesRead - 1);
        bytes32 afterAcc = keccak256(abi.encodePacked(beforeAcc, dataHash, delayedAcc));

        // spending report
        vm.expectEmit(true, true, true, true);
        emit MessageDelivered(
            delayedMessagesRead,
            delayedAcc,
            address(seqInbox),
            L1MessageType_batchPostingReport,
            tx.origin,
            keccak256(expectedSpendingReportMsg),
            block.basefee,
            uint64(block.timestamp)
        );

        // spending report event in seq inbox
        vm.expectEmit(true, true, true, true);
        emit InboxMessageDelivered(delayedMessagesRead, expectedSpendingReportMsg);

        // sequencer batch delivered
        vm.expectEmit(true, true, true, true);
        emit SequencerBatchDelivered(
            sequenceNumber,
            beforeAcc,
            afterAcc,
            delayedAcc,
            delayedMessagesRead,
            timeBounds,
            IBridge.BatchDataLocation.TxInput
        );
    }

    bytes biggerData =
        hex"00a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890a4567890";

    function testAddSequencerL2BatchFromOrigin(
        BufferConfig memory bufferConfig
    ) public {
        (SequencerInbox seqInbox, Bridge bridge,) = deployRollup(false, false, bufferConfig);
        address delayedInboxSender = address(140);
        uint8 delayedInboxKind = 3;
        bytes32 messageDataHash = RAND.Bytes32();
        bytes memory data = biggerData; // 00 is BROTLI_MESSAGE_HEADER_FLAG

        vm.prank(dummyInbox);
        bridge.enqueueDelayedMessage(delayedInboxKind, delayedInboxSender, messageDataHash);

        uint256 subMessageCount = bridge.sequencerReportedSubMessageCount();
        uint256 sequenceNumber = bridge.sequencerMessageCount();
        uint256 delayedMessagesRead = bridge.delayedMessageCount();

        // set 60 gwei basefee
        uint256 basefee = 60000000000;
        vm.fee(basefee);
        expectEvents(bridge, seqInbox, data, false, false, 0);

        vm.prank(tx.origin);
        seqInbox.addSequencerL2BatchFromOrigin(
            sequenceNumber,
            data,
            delayedMessagesRead,
            IGasRefunder(address(0)),
            subMessageCount,
            subMessageCount + 1
        );
    }

    /* solhint-disable func-name-mixedcase */
    function testConstructor() public {
        SequencerInbox seqInboxLogic =
            new SequencerInbox(MAX_DATA_SIZE, dummyReader4844, false, false);
        assertEq(seqInboxLogic.maxDataSize(), MAX_DATA_SIZE, "Invalid MAX_DATA_SIZE");
        assertEq(seqInboxLogic.isUsingFeeToken(), false, "Invalid isUsingFeeToken");

        SequencerInbox seqInboxProxy = SequencerInbox(TestUtil.deployProxy(address(seqInboxLogic)));
        assertEq(seqInboxProxy.maxDataSize(), MAX_DATA_SIZE, "Invalid MAX_DATA_SIZE");
        assertEq(seqInboxProxy.isUsingFeeToken(), false, "Invalid isUsingFeeToken");

        SequencerInbox seqInboxLogicFeeToken =
            new SequencerInbox(MAX_DATA_SIZE, dummyReader4844, true, false);
        assertEq(seqInboxLogicFeeToken.maxDataSize(), MAX_DATA_SIZE, "Invalid MAX_DATA_SIZE");
        assertEq(seqInboxLogicFeeToken.isUsingFeeToken(), true, "Invalid isUsingFeeToken");

        SequencerInbox seqInboxProxyFeeToken =
            SequencerInbox(TestUtil.deployProxy(address(seqInboxLogicFeeToken)));
        assertEq(seqInboxProxyFeeToken.maxDataSize(), MAX_DATA_SIZE, "Invalid MAX_DATA_SIZE");
        assertEq(seqInboxProxyFeeToken.isUsingFeeToken(), true, "Invalid isUsingFeeToken");
    }

    function testInitialize(
        BufferConfig memory bufferConfig
    ) public {
        Bridge _bridge =
            Bridge(address(new TransparentUpgradeableProxy(address(new Bridge()), proxyAdmin, "")));
        _bridge.initialize(IOwnable(address(new RollupMock(rollupOwner))));

        address seqInboxLogic =
            address(new SequencerInbox(MAX_DATA_SIZE, dummyReader4844, false, false));
        SequencerInbox seqInboxProxy = SequencerInbox(TestUtil.deployProxy(seqInboxLogic));
        seqInboxProxy.initialize(
            IBridge(_bridge), maxTimeVariation, bufferConfig, IFeeTokenPricer(address(0))
        );

        assertEq(seqInboxProxy.isUsingFeeToken(), false, "Invalid isUsingFeeToken");
        assertEq(address(seqInboxProxy.bridge()), address(_bridge), "Invalid bridge");
        assertEq(address(seqInboxProxy.rollup()), address(_bridge.rollup()), "Invalid rollup");
        assertEq(address(seqInboxProxy.feeTokenPricer()), address(0), "Invalid feeTokenPricer");
    }

    function testInitialize_FeeTokenBased(
        BufferConfig memory bufferConfig
    ) public {
        ERC20Bridge _bridge = ERC20Bridge(
            address(new TransparentUpgradeableProxy(address(new ERC20Bridge()), proxyAdmin, ""))
        );
        address nativeToken = address(new ERC20PresetMinterPauser("Appchain Token", "App"));
        _bridge.initialize(IOwnable(address(new RollupMock(rollupOwner))), nativeToken);

        address seqInboxLogic =
            address(new SequencerInbox(MAX_DATA_SIZE, dummyReader4844, true, false));
        SequencerInbox seqInboxProxy = SequencerInbox(TestUtil.deployProxy(seqInboxLogic));
        IFeeTokenPricer feeTokenPricer = IFeeTokenPricer(makeAddr("feeTokenPricer"));
        seqInboxProxy.initialize(IBridge(_bridge), maxTimeVariation, bufferConfig, feeTokenPricer);

        assertEq(seqInboxProxy.isUsingFeeToken(), true, "Invalid isUsingFeeToken");
        assertEq(address(seqInboxProxy.bridge()), address(_bridge), "Invalid bridge");
        assertEq(address(seqInboxProxy.rollup()), address(_bridge.rollup()), "Invalid rollup");
        assertEq(
            address(seqInboxProxy.feeTokenPricer()),
            address(feeTokenPricer),
            "Invalid feeTokenPricer"
        );
    }

    function testInitialize_revert_NativeTokenMismatch_EthFeeToken(
        BufferConfig memory bufferConfig
    ) public {
        Bridge _bridge =
            Bridge(address(new TransparentUpgradeableProxy(address(new Bridge()), proxyAdmin, "")));
        _bridge.initialize(IOwnable(address(new RollupMock(rollupOwner))));

        address seqInboxLogic =
            address(new SequencerInbox(MAX_DATA_SIZE, dummyReader4844, true, false));
        SequencerInbox seqInboxProxy = SequencerInbox(TestUtil.deployProxy(seqInboxLogic));

        vm.expectRevert(abi.encodeWithSelector(NativeTokenMismatch.selector));
        seqInboxProxy.initialize(
            IBridge(_bridge), maxTimeVariation, bufferConfig, IFeeTokenPricer(address(0))
        );
    }

    function testInitialize_revert_NativeTokenMismatch_FeeTokenEth(
        BufferConfig memory bufferConfig
    ) public {
        ERC20Bridge _bridge = ERC20Bridge(
            address(new TransparentUpgradeableProxy(address(new ERC20Bridge()), proxyAdmin, ""))
        );
        address nativeToken = address(new ERC20PresetMinterPauser("Appchain Token", "App"));
        _bridge.initialize(IOwnable(address(new RollupMock(rollupOwner))), nativeToken);

        address seqInboxLogic =
            address(new SequencerInbox(MAX_DATA_SIZE, dummyReader4844, false, false));
        SequencerInbox seqInboxProxy = SequencerInbox(TestUtil.deployProxy(seqInboxLogic));

        vm.expectRevert(abi.encodeWithSelector(NativeTokenMismatch.selector));
        seqInboxProxy.initialize(
            IBridge(_bridge),
            maxTimeVariation,
            bufferConfig,
            IFeeTokenPricer(makeAddr("feeTokenPricer"))
        );
    }

    function testInitialize_revert_CannotSetFeeTokenPricer() public {
        address bridge = address(new Bridge());
        address seqInboxLogic =
            address(new SequencerInbox(MAX_DATA_SIZE, dummyReader4844, false, false));
        SequencerInbox seqInboxProxy = SequencerInbox(TestUtil.deployProxy(seqInboxLogic));
        IFeeTokenPricer pricer = IFeeTokenPricer(makeAddr("feeTokenPricer"));
        vm.expectRevert(abi.encodeWithSelector(CannotSetFeeTokenPricer.selector));
        seqInboxProxy.initialize(IBridge(bridge), maxTimeVariation, bufferConfigDefault, pricer);
    }

    function testAddSequencerL2BatchFromOrigin_ArbitrumHosted(
        BufferConfig memory bufferConfig
    ) public {
        // this will result in 'hostChainIsArbitrum = true'
        vm.mockCall(
            address(100),
            abi.encodeWithSelector(ArbSys.arbOSVersion.selector),
            abi.encode(uint256(11))
        );
        (SequencerInbox seqInbox, Bridge bridge,) = deployRollup(true, false, bufferConfig);

        address delayedInboxSender = address(140);
        uint8 delayedInboxKind = 3;
        bytes32 messageDataHash = RAND.Bytes32();
        bytes memory data = hex"00567890";

        vm.prank(dummyInbox);
        bridge.enqueueDelayedMessage(delayedInboxKind, delayedInboxSender, messageDataHash);

        uint256 subMessageCount = bridge.sequencerReportedSubMessageCount();
        uint256 sequenceNumber = bridge.sequencerMessageCount();
        uint256 delayedMessagesRead = bridge.delayedMessageCount();

        expectEvents(bridge, seqInbox, data, true, false, 0);

        vm.prank(tx.origin);
        seqInbox.addSequencerL2BatchFromOrigin(
            sequenceNumber,
            data,
            delayedMessagesRead,
            IGasRefunder(address(0)),
            subMessageCount,
            subMessageCount + 1
        );
    }

    function testAddSequencerL2BatchFromOrigin_ArbitrumHostedFeeTokenBased() public {
        (SequencerInbox seqInbox, ERC20Bridge bridge) = deployFeeTokenBasedRollup();
        address delayedInboxSender = address(140);
        uint8 delayedInboxKind = 3;
        bytes32 messageDataHash = RAND.Bytes32();
        bytes memory data = hex"80567890";

        vm.prank(dummyInbox);
        bridge.enqueueDelayedMessage(delayedInboxKind, delayedInboxSender, messageDataHash, 0);

        uint256 subMessageCount = bridge.sequencerReportedSubMessageCount();
        uint256 sequenceNumber = bridge.sequencerMessageCount();
        uint256 delayedMessagesRead = bridge.delayedMessageCount();

        // set 40 gwei basefee
        uint256 basefee = 40000000000;
        vm.fee(basefee);

        expectEvents(IBridge(address(bridge)), seqInbox, data, true, true, 1e18);

        address feeTokenPricer = address(seqInbox.feeTokenPricer());
        vm.mockCall(
            feeTokenPricer,
            abi.encodeWithSelector(IFeeTokenPricer.getExchangeRate.selector),
            abi.encode(uint256(1e18))
        );
        vm.prank(tx.origin);
        seqInbox.addSequencerL2BatchFromOrigin(
            sequenceNumber,
            data,
            delayedMessagesRead,
            IGasRefunder(address(0)),
            subMessageCount,
            subMessageCount + 1
        );
    }

    function testAddSequencerL2BatchFromOriginReverts() public {
        (SequencerInbox seqInbox, Bridge bridge,) = deployRollup(false, false, bufferConfigDefault);
        address delayedInboxSender = address(140);
        uint8 delayedInboxKind = 3;
        bytes32 messageDataHash = RAND.Bytes32();
        bytes memory data = biggerData; // 00 is BROTLI_MESSAGE_HEADER_FLAG

        vm.prank(dummyInbox);
        bridge.enqueueDelayedMessage(delayedInboxKind, delayedInboxSender, messageDataHash);

        uint256 subMessageCount = bridge.sequencerReportedSubMessageCount();
        uint256 sequenceNumber = bridge.sequencerMessageCount();
        uint256 delayedMessagesRead = bridge.delayedMessageCount();

        vm.expectRevert(abi.encodeWithSelector(NotCodelessOrigin.selector));
        seqInbox.addSequencerL2BatchFromOrigin(
            sequenceNumber,
            data,
            delayedMessagesRead,
            IGasRefunder(address(0)),
            subMessageCount,
            subMessageCount + 1
        );

        assertEq(rollupOwner.code.length, 0, "rollupOwner is codeless");
        vm.etch(rollupOwner, bytes("some code"));
        vm.prank(rollupOwner, rollupOwner);
        vm.expectRevert(abi.encodeWithSelector(NotCodelessOrigin.selector));
        seqInbox.addSequencerL2BatchFromOrigin(
            sequenceNumber,
            data,
            delayedMessagesRead,
            IGasRefunder(address(0)),
            subMessageCount,
            subMessageCount + 1
        );
        vm.etch(rollupOwner, bytes(""));

        vm.prank(rollupOwner);
        seqInbox.setIsBatchPoster(tx.origin, false);

        vm.expectRevert(abi.encodeWithSelector(NotBatchPoster.selector));
        vm.prank(tx.origin);
        seqInbox.addSequencerL2BatchFromOrigin(
            sequenceNumber,
            data,
            delayedMessagesRead,
            IGasRefunder(address(0)),
            subMessageCount,
            subMessageCount + 1
        );

        vm.prank(rollupOwner);
        seqInbox.setIsBatchPoster(tx.origin, true);

        bytes memory bigData = bytes.concat(
            seqInbox.BROTLI_MESSAGE_HEADER_FLAG(),
            RAND.Bytes(maxDataSize - seqInbox.HEADER_LENGTH())
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                DataTooLarge.selector, bigData.length + seqInbox.HEADER_LENGTH(), maxDataSize
            )
        );
        vm.prank(tx.origin);
        seqInbox.addSequencerL2BatchFromOrigin(
            sequenceNumber,
            bigData,
            delayedMessagesRead,
            IGasRefunder(address(0)),
            subMessageCount,
            subMessageCount + 1
        );

        bytes memory authenticatedData = bytes.concat(seqInbox.DATA_BLOB_HEADER_FLAG(), data);
        vm.expectRevert(abi.encodeWithSelector(InvalidHeaderFlag.selector, authenticatedData[0]));
        vm.prank(tx.origin);
        seqInbox.addSequencerL2BatchFromOrigin(
            sequenceNumber,
            authenticatedData,
            delayedMessagesRead,
            IGasRefunder(address(0)),
            subMessageCount,
            subMessageCount + 1
        );

        vm.expectRevert(
            abi.encodeWithSelector(BadSequencerNumber.selector, sequenceNumber, sequenceNumber + 5)
        );
        vm.prank(tx.origin);
        seqInbox.addSequencerL2BatchFromOrigin(
            sequenceNumber + 5,
            data,
            delayedMessagesRead,
            IGasRefunder(address(0)),
            subMessageCount,
            subMessageCount + 1
        );
    }

    function testFuzz_addSequencerBatch_FeeToken(
        uint256 exchangeRate
    ) public {
        exchangeRate = bound(exchangeRate, 0, 100000000e18);

        (SequencerInbox seqInbox, ERC20Bridge bridge) = deployFeeTokenBasedRollup();
        uint8 delayedInboxKind = 3;
        bytes32 messageDataHash = RAND.Bytes32();
        bytes memory data = hex"80567890";

        vm.prank(dummyInbox);
        bridge.enqueueDelayedMessage(delayedInboxKind, address(140), messageDataHash, 0);

        uint256 subMessageCount = bridge.sequencerReportedSubMessageCount();
        uint256 sequenceNumber = bridge.sequencerMessageCount();
        uint256 delayedMessagesRead = bridge.delayedMessageCount();

        // set 40 gwei basefee
        vm.fee(40000000000);

        // make fee token pricer return specified exchange rate
        vm.mockCall(
            address(seqInbox.feeTokenPricer()),
            abi.encodeWithSelector(IFeeTokenPricer.getExchangeRate.selector),
            abi.encode(exchangeRate)
        );

        // check if call will overflow due to too high exchange rate
        bool expectedToOverflow = false;
        {
            unchecked {
                uint256 mul = block.basefee * exchangeRate;
                if (exchangeRate != 0 && ((mul / exchangeRate) != block.basefee)) {
                    expectedToOverflow = true;
                }
            }
        }

        if (expectedToOverflow) {
            vm.expectRevert(stdError.arithmeticError);
        } else {
            expectEvents(IBridge(address(bridge)), seqInbox, data, true, true, exchangeRate);
        }
        vm.prank(tx.origin);
        seqInbox.addSequencerL2BatchFromOrigin(
            sequenceNumber,
            data,
            delayedMessagesRead,
            IGasRefunder(address(0)),
            subMessageCount,
            subMessageCount + 1
        );
    }

    function testSetFeeTokenPricer() public {
        (SequencerInbox seqInbox,) = deployFeeTokenBasedRollup();
        IFeeTokenPricer newPricer = IFeeTokenPricer(makeAddr("newPricer"));

        vm.expectEmit(true, true, true, true);
        emit OwnerFunctionCalled(6);

        vm.prank(rollupOwner);
        seqInbox.setFeeTokenPricer(newPricer);

        assertEq(address(seqInbox.feeTokenPricer()), address(newPricer));
    }

    function testSetFeeTokenPricer_revert_NotRollupOwner() public {
        (SequencerInbox seqInbox,,) = deployRollup(false, false, bufferConfigDefault);
        IFeeTokenPricer newPricer = IFeeTokenPricer(makeAddr("newPricer"));

        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector, address(this), rollupOwner));
        seqInbox.setFeeTokenPricer(newPricer);
    }

    function testSetFeeTokenPricer_revert_CannotSetFeeTokenPricer() public {
        (SequencerInbox seqInbox,,) = deployRollup(false, false, bufferConfigDefault);
        IFeeTokenPricer newPricer = IFeeTokenPricer(makeAddr("newPricer"));

        vm.expectRevert(abi.encodeWithSelector(CannotSetFeeTokenPricer.selector));
        vm.prank(rollupOwner);
        seqInbox.setFeeTokenPricer(newPricer);
    }

    function testPostUpgradeInitAlreadyInitBuffer(
        BufferConfig memory bufferConfig
    ) public returns (SequencerInbox, SequencerInbox) {
        vm.assume(DelayBuffer.isValidBufferConfig(bufferConfig));
        (SequencerInbox seqInbox,,) = deployRollup(false, false, bufferConfigDefault);
        SequencerInbox seqInboxImpl = new SequencerInbox(maxDataSize, dummyReader4844, false, true);
        vm.prank(proxyAdmin);
        TransparentUpgradeableProxy(payable(address(seqInbox))).upgradeToAndCall(
            address(seqInboxImpl),
            abi.encodeWithSelector(SequencerInbox.postUpgradeInit.selector, bufferConfig)
        );

        vm.expectRevert(abi.encodeWithSelector(AlreadyInit.selector));
        vm.prank(proxyAdmin);
        TransparentUpgradeableProxy(payable(address(seqInbox))).upgradeToAndCall(
            address(seqInboxImpl),
            abi.encodeWithSelector(SequencerInbox.postUpgradeInit.selector, bufferConfig)
        );
        return (seqInbox, seqInboxImpl);
    }

    function testPostUpgradeInitBuffer(
        BufferConfig memory bufferConfig
    ) public {
        vm.assume(DelayBuffer.isValidBufferConfig(bufferConfig));

        (SequencerInbox seqInbox, SequencerInbox seqInboxImpl) =
            testPostUpgradeInitAlreadyInitBuffer(bufferConfig);

        vm.expectRevert(abi.encodeWithSelector(AlreadyInit.selector));
        vm.prank(proxyAdmin);
        TransparentUpgradeableProxy(payable(address(seqInbox))).upgradeToAndCall(
            address(seqInboxImpl),
            abi.encodeWithSelector(SequencerInbox.postUpgradeInit.selector, bufferConfig)
        );

        // reset buffer and config
        vm.store(address(seqInbox), bytes32(uint256(12)), bytes32(0));
        vm.store(address(seqInbox), bytes32(uint256(13)), bytes32(0));
        vm.store(address(seqInbox), bytes32(uint256(14)), bytes32(0));
        vm.store(address(seqInbox), bytes32(uint256(15)), bytes32(0));
        vm.store(address(seqInbox), bytes32(uint256(16)), bytes32(0));

        vm.prank(proxyAdmin);
        TransparentUpgradeableProxy(payable(address(seqInbox))).upgradeToAndCall(
            address(seqInboxImpl),
            abi.encodeWithSelector(SequencerInbox.postUpgradeInit.selector, bufferConfig)
        );
        {
            (uint64 bufferBlocks, uint64 max, uint64 threshold,, uint64 replenishRateInBasis,) =
                seqInbox.buffer();
            assertEq(max, bufferConfig.max);
            assertEq(threshold, bufferConfig.threshold);
            assertEq(replenishRateInBasis, bufferConfig.replenishRateInBasis);
            assertEq(bufferBlocks, bufferConfig.max);
        }
        vm.expectRevert(abi.encodeWithSelector(AlreadyInit.selector));
        vm.prank(proxyAdmin);
        TransparentUpgradeableProxy(payable(address(seqInbox))).upgradeToAndCall(
            address(seqInboxImpl),
            abi.encodeWithSelector(SequencerInbox.postUpgradeInit.selector, bufferConfig)
        );
    }

    function testPostUpgradeInitBadInitBuffer(
        BufferConfig memory config,
        BufferConfig memory configInvalid
    ) public {
        vm.assume(DelayBuffer.isValidBufferConfig(config));
        vm.assume(!DelayBuffer.isValidBufferConfig(configInvalid));

        (SequencerInbox seqInbox, SequencerInbox seqInboxImpl) =
            testPostUpgradeInitAlreadyInitBuffer(config);

        // reset buffer and config
        vm.store(address(seqInbox), bytes32(uint256(12)), bytes32(0));
        vm.store(address(seqInbox), bytes32(uint256(13)), bytes32(0));
        vm.store(address(seqInbox), bytes32(uint256(14)), bytes32(0));
        vm.store(address(seqInbox), bytes32(uint256(15)), bytes32(0));
        vm.store(address(seqInbox), bytes32(uint256(16)), bytes32(0));

        vm.expectRevert(abi.encodeWithSelector(BadBufferConfig.selector));
        vm.prank(proxyAdmin);
        TransparentUpgradeableProxy(payable(address(seqInbox))).upgradeToAndCall(
            address(seqInboxImpl),
            abi.encodeWithSelector(SequencerInbox.postUpgradeInit.selector, configInvalid)
        );
    }

    function testSetBufferConfig(
        BufferConfig memory bufferConfig
    ) public {
        vm.assume(DelayBuffer.isValidBufferConfig(bufferConfig));
        (SequencerInbox seqInbox,,) = deployRollup(false, true, bufferConfig);
        vm.prank(rollupOwner);
        seqInbox.setBufferConfig(bufferConfig);
    }

    function testSetBufferConfigInvalid(
        BufferConfig memory bufferConfigInvalid
    ) public {
        vm.assume(!DelayBuffer.isValidBufferConfig(bufferConfigInvalid));
        (SequencerInbox seqInbox,,) = deployRollup(false, true, bufferConfigDefault);
        vm.expectRevert(abi.encodeWithSelector(BadBufferConfig.selector));
        vm.prank(rollupOwner);
        seqInbox.setBufferConfig(bufferConfigInvalid);
    }

    function testSetMaxTimeVariation(
        uint256 delayBlocks,
        uint256 futureBlocks,
        uint256 delaySeconds,
        uint256 futureSeconds
    ) public {
        (SequencerInbox seqInbox,,) = deployRollup(false, false, bufferConfigDefault);
        bool checkValue = true;
        if (
            delayBlocks > uint256(type(uint64).max) || futureBlocks > uint256(type(uint64).max)
                || delaySeconds > uint256(type(uint64).max) || futureSeconds > uint256(type(uint64).max)
        ) {
            vm.expectRevert(abi.encodeWithSelector(BadMaxTimeVariation.selector));
            checkValue = false;
        }
        vm.prank(rollupOwner);
        seqInbox.setMaxTimeVariation(
            ISequencerInbox.MaxTimeVariation({
                delayBlocks: delayBlocks,
                futureBlocks: futureBlocks,
                delaySeconds: delaySeconds,
                futureSeconds: futureSeconds
            })
        );
        (uint256 _delayBlocks, uint256 _futureBlocks, uint256 _delaySeconds, uint256 _futureSeconds)
        = seqInbox.maxTimeVariation();
        if (checkValue) {
            assertEq(_delayBlocks, delayBlocks);
            assertEq(_futureBlocks, futureBlocks);
            assertEq(_delaySeconds, delaySeconds);
            assertEq(_futureSeconds, futureSeconds);
        }
    }

    function test_updateRollupAddress() public {
        (SequencerInbox seqInbox, Bridge bridge,) = deployRollup(false, true, bufferConfigDefault);
        address rollup = address(bridge.rollup());
        vm.prank(rollup);
        bridge.updateRollupAddress(IOwnable(address(1337)));
        vm.mockCall(
            address(rollup),
            0,
            abi.encodeWithSelector(IOwnable.owner.selector),
            abi.encode(address(this))
        );
        seqInbox.updateRollupAddress();
        assertEq(address(seqInbox.rollup()), address(1337), "Invalid rollup");
    }

    function test_updateRollupAddress_revert_NotOwner() public {
        (SequencerInbox seqInbox, Bridge bridge,) = deployRollup(false, true, bufferConfigDefault);
        address rollup = address(bridge.rollup());
        vm.mockCall(
            address(rollup),
            0,
            abi.encodeWithSelector(IOwnable.owner.selector),
            abi.encode(address(1337))
        );
        vm.expectRevert(abi.encodeWithSelector(NotOwner.selector, address(this), address(1337)));
        seqInbox.updateRollupAddress();
    }

    function test_postUpgradeInit_revert_NotDelayBufferable() public {
        (SequencerInbox seqInbox,, address seqInboxImpl) =
            deployRollup(false, false, bufferConfigDefault);
        vm.expectRevert(abi.encodeWithSelector(NotDelayBufferable.selector));
        vm.prank(proxyAdmin);
        TransparentUpgradeableProxy(payable(address(seqInbox))).upgradeToAndCall(
            address(seqInboxImpl),
            abi.encodeWithSelector(SequencerInbox.postUpgradeInit.selector, bufferConfigDefault)
        );
    }

    function test_postUpgradeInit_revert_AlreadyInit() public {
        (SequencerInbox seqInbox,, address seqInboxImpl) =
            deployRollup(false, true, bufferConfigDefault);
        vm.expectRevert(abi.encodeWithSelector(AlreadyInit.selector));
        vm.prank(proxyAdmin);
        TransparentUpgradeableProxy(payable(address(seqInbox))).upgradeToAndCall(
            address(seqInboxImpl),
            abi.encodeWithSelector(SequencerInbox.postUpgradeInit.selector, bufferConfigDefault)
        );
    }
}
