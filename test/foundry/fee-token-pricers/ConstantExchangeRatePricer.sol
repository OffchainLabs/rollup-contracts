// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IFeeTokenPricer} from "../../../src/bridge/ISequencerInbox.sol";

// NOTICE: This contract has not been audited or properly tested. It is for example purposes only

/// @title A constant price fee token pricer
/// @notice The most simple kind of fee token pricer, does not account for any change in exchange rate
contract ConstantExchangeRatePricer is IFeeTokenPricer {
    uint256 immutable exchangeRate;

    constructor(
        uint256 _exchangeRate
    ) {
        exchangeRate = _exchangeRate;
    }

    // @inheritdoc IFeeTokenPricer
    function getExchangeRate() external view returns (uint256) {
        return exchangeRate;
    }
}
