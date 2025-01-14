// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {TradeTracker, IERC20} from "./TradeTracker.sol";
import "../../../../src/bridge/SequencerInbox.sol";
import {ERC20Bridge} from "../../../../src/bridge/ERC20Bridge.sol";
import "@openzeppelin/contracts/token/ERC20/presets/ERC20PresetMinterPauser.sol";

import "../../util/TestUtil.sol";

contract SimpleTradeTracker is TradeTracker {
    constructor(
        address _sequencerInbox
    ) TradeTracker(6, 16, _sequencerInbox) {}

    function trade(uint256 thisChainTokens, uint256 childChainTokens) public {
        recordTrade(thisChainTokens, childChainTokens);
    }
}

contract TrackerTest is Test {
    address public batchPoster = makeAddr("batchPoster");
    address public seqInbox = makeAddr("seqInbox");

    function testExchangeRate() public {
        SimpleTradeTracker tradeTracker = new SimpleTradeTracker(seqInbox);

        uint256 thisChainReserve = 10e18;
        uint256 childChainReserve = 100e6;

        vm.startPrank(address(this), batchPoster);
        assertEq(tradeTracker.getExchangeRate(), 0);

        // do a trade and set the exchange rate
        uint256 exRate1 = (childChainReserve * 1e18 / thisChainReserve) * 1e12;
        tradeTracker.trade(thisChainReserve, childChainReserve);
        assertEq(tradeTracker.getExchangeRate(), exRate1);

        // trade again at the same rate
        tradeTracker.trade(thisChainReserve, childChainReserve);
        assertEq(tradeTracker.getExchangeRate(), exRate1);

        // trade again at different rate
        tradeTracker.trade(thisChainReserve / 2, childChainReserve);
        uint256 exRate2 = (childChainReserve * 3 * 1e18 / (thisChainReserve * 5 / 2)) * 1e12;
        assertEq(tradeTracker.getExchangeRate(), exRate2);

        vm.stopPrank();
    }

    function testOnGasSpent() public {
        vm.fee(1 gwei);

        SimpleTradeTracker tradeTracker = new SimpleTradeTracker(seqInbox);

        uint256 gasUsed = 300_000;
        uint256 calldataSize = 10_000;

        vm.startPrank(address(seqInbox), batchPoster);
        vm.expectRevert(
            abi.encodeWithSelector(
                TradeTracker.InsufficientThisChainTokenReserve.selector, batchPoster
            )
        );
        tradeTracker.onGasSpent(payable(batchPoster), gasUsed, calldataSize);

        // trade some, but not enough
        tradeTracker.trade(
            (gasUsed - 1000 + calldataSize * tradeTracker.calldataCost()) * block.basefee,
            10 * 10 ** tradeTracker.childTokenDecimals()
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                TradeTracker.InsufficientThisChainTokenReserve.selector, batchPoster
            )
        );
        tradeTracker.onGasSpent(payable(batchPoster), gasUsed, calldataSize);

        // trade some more
        tradeTracker.trade(10000 * block.basefee, 10 * 10 ** tradeTracker.childTokenDecimals());
        uint256 exchangeRateBefore = tradeTracker.getExchangeRate();
        tradeTracker.onGasSpent(payable(batchPoster), gasUsed, calldataSize);

        uint256 thisChainTokensUsed =
            (gasUsed + calldataSize * tradeTracker.calldataCost()) * block.basefee;
        uint256 childChainTokensUsed = thisChainTokensUsed * exchangeRateBefore / 1e18;
        uint256 thisChainReserveAfter = (
            (10000 + gasUsed - 1000 + calldataSize * tradeTracker.calldataCost()) * block.basefee
                - thisChainTokensUsed
        );
        uint256 childChainReserveAfter =
            (20 * 10 ** tradeTracker.childTokenDecimals() * 1e12) - childChainTokensUsed;
        uint256 exchangeRateAfter = childChainReserveAfter * 1e18 / thisChainReserveAfter;
        assertEq(tradeTracker.getExchangeRate(), exchangeRateAfter);
    }
}
