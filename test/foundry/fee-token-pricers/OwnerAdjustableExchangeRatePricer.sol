// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IFeeTokenPricer} from "../../../src/bridge/ISequencerInbox.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title A uniswap twap pricer
/// @notice An example of a type 1 fee token pricer. The owner can adjust the exchange rate at any time
///         to ensure the batch poster is reimbursed an appropriate amount on the child chain
contract OwnerAdjustableExchangeRatePricer is IFeeTokenPricer, Ownable {
    uint256 public exchangeRate;

    event ExchangeRateSet(uint256 newExchangeRate);

    constructor(
        uint256 initialExchangeRate
    ) Ownable() {
        exchangeRate = initialExchangeRate;
        emit ExchangeRateSet(initialExchangeRate);
    }

    function setExchangeRate(
        uint256 _exchangeRate
    ) external onlyOwner {
        exchangeRate = _exchangeRate;
        emit ExchangeRateSet(_exchangeRate);
    }

    // @inheritdoc IFeeTokenPricer
    function getExchangeRate() external view returns (uint256) {
        return exchangeRate;
    }
}
