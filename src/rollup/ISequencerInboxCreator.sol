// Copyright 2021-2022, Offchain Labs, Inc.
// For license information, see https://github.com/OffchainLabs/nitro-contracts/blob/main/LICENSE
// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "../bridge/ISequencerInbox.sol";
import "../bridge/IDelayBufferable.sol";

interface ISequencerInboxCreator {
    function createSequencerInbox(
        IBridge bridge,
        ISequencerInbox.MaxTimeVariation calldata maxTimeVariation,
        IDelayBufferable.ReplenishRate calldata replenishRate,
        IDelayBufferable.Config calldata config,
        uint256 maxDataSize,
        bool isUsingFeeToken
    ) external returns (ISequencerInbox);
}
