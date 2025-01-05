// Copyright 2023-2024, Offchain Labs, Inc.
// For license information, see https://github.com/OffchainLabs/nitro-contracts/blob/main/LICENSE
// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.7;

import "../libraries/IGasRefunder.sol";

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @notice Optimized version of GasRefunder intended especially for use by sequencer inbox batch posters.
 * @dev This contract allows any refundee as long as the caller is the allowedContract.
 */
contract GasRefunderOpt is IGasRefunder, Ownable {
    address public immutable allowedContract;
    uint256 public immutable maxRefundeeBalance;
    uint256 public immutable extraGasMargin;
    uint256 public immutable calldataCost;
    uint256 public immutable maxGasTip;
    uint256 public immutable maxGasCost;
    uint256 public immutable maxSingleGasUsage;

    enum RefundDenyReason {
        CONTRACT_NOT_ALLOWED,
        REFUNDEE_NOT_ALLOWED,
        REFUNDEE_ABOVE_MAX_BALANCE,
        OUT_OF_FUNDS
    }

    event SuccessfulRefundedGasCosts(uint256 gas, uint256 gasPrice, uint256 amountPaid);

    event FailedRefundedGasCosts(uint256 gas, uint256 gasPrice, uint256 amountPaid);

    event RefundGasCostsDenied(
        address indexed refundee,
        address indexed contractAddress,
        RefundDenyReason indexed reason,
        uint256 gas
    );
    event Deposited(address sender, uint256 amount);
    event Withdrawn(address initiator, address destination, uint256 amount);

    constructor(
        address _allowedContract,
        uint256 _maxRefundeeBalance,
        uint256 _extraGasMargin,
        uint256 _calldataCost,
        uint256 _maxGasTip,
        uint256 _maxGasCost,
        uint256 _maxSingleGasUsage
    ) Ownable() {
        allowedContract = _allowedContract;
        maxRefundeeBalance = _maxRefundeeBalance;
        extraGasMargin = _extraGasMargin;
        calldataCost = _calldataCost;
        maxGasTip = _maxGasTip;
        maxGasCost = _maxGasCost;
        maxSingleGasUsage = _maxSingleGasUsage;
    }

    receive() external payable {
        emit Deposited(msg.sender, msg.value);
    }

    function withdraw(address payable destination, uint256 amount) external onlyOwner {
        // It's expected that destination is an EOA
        (bool success, ) = destination.call{value: amount}("");
        require(success, "WITHDRAW_FAILED");
        emit Withdrawn(msg.sender, destination, amount);
    }

    function onGasSpent(
        address payable refundee,
        uint256 gasUsed,
        uint256 calldataSize
    ) external override returns (bool success) {
        uint256 startGasLeft = gasleft();

        uint256 ownBalance = address(this).balance;

        if (ownBalance == 0) {
            emit RefundGasCostsDenied(refundee, msg.sender, RefundDenyReason.OUT_OF_FUNDS, gasUsed);
            return false;
        }

        if (allowedContract != msg.sender) {
            emit RefundGasCostsDenied(
                refundee,
                msg.sender,
                RefundDenyReason.CONTRACT_NOT_ALLOWED,
                gasUsed
            );
            return false;
        }

        uint256 estGasPrice = block.basefee + maxGasTip;
        if (tx.gasprice < estGasPrice) {
            estGasPrice = tx.gasprice;
        }
        if (maxGasCost != 0 && estGasPrice > maxGasCost) {
            estGasPrice = maxGasCost;
        }

        uint256 refundeeBalance = refundee.balance;

        // Add in a bit of a buffer for the tx costs not measured with gasleft
        gasUsed += startGasLeft + extraGasMargin + (calldataSize * calldataCost);
        // Split this up into two statements so that gasleft() comes after the extra arithmetic
        gasUsed -= gasleft();

        if (maxSingleGasUsage != 0 && gasUsed > maxSingleGasUsage) {
            gasUsed = maxSingleGasUsage;
        }

        uint256 refundAmount = estGasPrice * gasUsed;
        if (maxRefundeeBalance != 0 && refundeeBalance + refundAmount > maxRefundeeBalance) {
            if (refundeeBalance > maxRefundeeBalance) {
                // The refundee is already above their max balance
                // emit RefundGasCostsDenied(
                //     refundee,
                //     msg.sender,
                //     RefundDenyReason.REFUNDEE_ABOVE_MAX_BALANCE,
                //     gasUsed
                // );
                return false;
            } else {
                refundAmount = maxRefundeeBalance - refundeeBalance;
            }
        }

        if (refundAmount > ownBalance) {
            refundAmount = ownBalance;
        }

        // It's expected that refundee is an EOA
        // solhint-disable-next-line avoid-low-level-calls
        (success, ) = refundee.call{value: refundAmount}("");

        if (success) {
            emit SuccessfulRefundedGasCosts(gasUsed, estGasPrice, refundAmount);
        } else {
            emit FailedRefundedGasCosts(gasUsed, estGasPrice, refundAmount);
        }
    }
}
