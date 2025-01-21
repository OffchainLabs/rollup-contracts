// Copyright 2021-2022, Offchain Labs, Inc.
// For license information, see https://github.com/OffchainLabs/nitro-contracts/blob/main/LICENSE
// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "./AbsRollupEventInbox.sol";
import "../bridge/IERC20Bridge.sol";
import "../bridge/ISequencerInbox.sol";
import {INITIALIZATION_MSG_TYPE} from "../libraries/MessageTypes.sol";

/**
 * @title The inbox for rollup protocol events
 */
contract ERC20RollupEventInbox is AbsRollupEventInbox {
    constructor() AbsRollupEventInbox() {}

    function _enqueueInitializationMsg(
        bytes memory initMsg
    ) internal override returns (uint256) {
        uint256 tokenAmount = 0;
        return IERC20Bridge(address(bridge)).enqueueDelayedMessage(
            INITIALIZATION_MSG_TYPE, address(0), keccak256(initMsg), tokenAmount
        );
    }

    function _currentDataCostToReport() internal override returns (uint256) {
        // if a fee token pricer is configured then it can be used to charge for data posting fees
        ISequencerInbox seqInbox = ISequencerInbox(bridge.sequencerInbox());
        IFeeTokenPricer feeTokenPricer = seqInbox.feeTokenPricer();
        if (address(feeTokenPricer) != address(0)) {
            uint256 gasPrice = block.basefee;
            if (ArbitrumChecker.runningOnArbitrum()) {
                gasPrice += ArbGasInfo(address(0x6c)).getL1BaseFeeEstimate();
            }
            // scale the current gas price to the child chain gas price
            uint256 exchangeRate = feeTokenPricer.getExchangeRate();
            return (gasPrice * exchangeRate) / 1e18;
        }

        // if no fee token pricer is configured then data costs cant be reimbursed, and l1 price is set to 0
        return 0;
    }
}
