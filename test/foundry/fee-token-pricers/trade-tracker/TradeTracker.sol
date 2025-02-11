// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IFeeTokenPricer} from "../../../../src/bridge/ISequencerInbox.sol";
import {IGasRefunder} from "../../../../src/libraries/IGasRefunder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

abstract contract TradeTracker is IFeeTokenPricer, IGasRefunder {
    using SafeERC20 for IERC20;

    uint8 public immutable childTokenDecimals;
    uint256 public immutable calldataCost;
    address public immutable sequencerInbox;

    uint256 public thisChainTokenReserve;
    uint256 public childChainTokenReserve;

    error NotSequencerInbox(address caller);
    error InsufficientThisChainTokenReserve(address batchPoster);
    error InsufficientChildChainTokenReserve(address batchPoster);

    constructor(uint8 _childTokenDecimals, uint256 _calldataCost, address _sequencerInbox) {
        childTokenDecimals = _childTokenDecimals;
        calldataCost = _calldataCost;
        sequencerInbox = _sequencerInbox;
    }

    // @inheritdoc IFeeTokenPricer
    function getExchangeRate() public view returns (uint256) {
        uint256 thisChainTokens = thisChainTokenReserve;
        uint256 childChainTokens = childChainTokenReserve;
        // if either of the reserves is empty the spender will receive no reimbursement
        if (thisChainTokens == 0 || childChainTokens == 0) {
            return 0;
        }

        // gas tokens on this chain always have 18 decimals
        return (childChainTokens * 1e18) / thisChainTokens;
    }

    /// @notice Record that a trade occurred. The sub contract can choose how and when trades can be recorded
    ///         but it is likely that the batchposter will be trusted to report the correct trade price.
    /// @param thisChainTokensPurchased The number of this chain tokens purchased
    /// @param childChainTokensPaid The number of child chain tokens purchased
    function recordTrade(uint256 thisChainTokensPurchased, uint256 childChainTokensPaid) internal {
        thisChainTokenReserve += thisChainTokensPurchased;
        childChainTokenReserve += scaleTo18Decimals(childChainTokensPaid);
    }

    /// @notice A hook to record when gas is spent by the batch poster
    ///         Matches the interface used in GasRefundEnable so can be used by the caller as a gas refunder
    /// @param batchPoster The address spending the gas
    /// @param gasUsed The amount of gas used
    /// @param calldataSize The calldata size - will be added to the gas used at some predetermined rate
    function onGasSpent(
        address payable batchPoster,
        uint256 gasUsed,
        uint256 calldataSize
    ) external returns (bool) {
        if (msg.sender != sequencerInbox) revert NotSequencerInbox(msg.sender);

        // each time gas is spent we reduce the reserves
        // to represent what will have been refunded on the child chain

        gasUsed += calldataSize * calldataCost;
        uint256 thisTokenSpent = gasUsed * block.basefee;
        uint256 exchangeRateUsed = getExchangeRate();
        uint256 childTokenReceived = exchangeRateUsed * thisTokenSpent / 1e18;

        if (thisTokenSpent > thisChainTokenReserve) {
            revert InsufficientThisChainTokenReserve(batchPoster);
        }
        thisChainTokenReserve -= thisTokenSpent;

        if (childTokenReceived > childChainTokenReserve) {
            // it shouldn't be possible to hit this revert if the maths of calculating an exchange rate are correct
            revert InsufficientChildChainTokenReserve(batchPoster);
        }
        childChainTokenReserve -= childTokenReceived;

        return true;
    }

    function scaleTo18Decimals(
        uint256 amount
    ) internal view returns (uint256) {
        if (childTokenDecimals == 18) {
            return amount;
        } else if (childTokenDecimals < 18) {
            return amount * 10 ** (18 - childTokenDecimals);
        } else {
            return amount / 10 ** (childTokenDecimals - 18);
        }
    }
}
