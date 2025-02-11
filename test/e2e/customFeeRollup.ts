import { L2Network, addCustomNetwork } from '@arbitrum/sdk'
import { wait } from '@arbitrum/sdk/dist/lib/utils/lib'
import { JsonRpcProvider } from '@ethersproject/providers'
import { expect } from 'chai'
import {
  ArbGasInfo__factory,
  ArbOwner__factory,
  ERC20,
  ERC20__factory,
  IERC20Bridge__factory,
  IFeeTokenPricer__factory,
  IInbox__factory,
  SequencerInbox__factory,
} from '../../build/types'
import { getLocalNetworks } from '../../scripts/testSetup'
import { BigNumber, Wallet, ethers } from 'ethers'
import { ARB_GAS_INFO } from '@arbitrum/sdk/dist/lib/dataEntities/constants'
import {
  l1Networks,
  l2Networks,
} from '@arbitrum/sdk/dist/lib/dataEntities/networks'

const LOCALHOST_L2_RPC = 'http://127.0.0.1:8547'
const LOCALHOST_L3_RPC = 'http://127.0.0.1:3347'

let l2Provider: JsonRpcProvider
let l3Provider: JsonRpcProvider

let l2Network: L2Network
let userL2Wallet: Wallet
let userL3Wallet: Wallet
let nativeToken: ERC20 | undefined

describe('Custom fee token orbit rollup', () => {
  async function _getFeeToken(
    inbox: string,
    l1Provider: ethers.providers.Provider
  ): Promise<string> {
    const bridge = await IInbox__factory.connect(inbox, l1Provider).bridge()
    let feeToken = ethers.constants.AddressZero
    try {
      feeToken = await IERC20Bridge__factory.connect(
        bridge,
        l1Provider
      ).nativeToken()
    } catch {
      feeToken = ethers.constants.AddressZero
    }
    return feeToken
  }

  // setup providers and connect deployed contracts
  before(async function () {
    const { l1Network, l2Network: coreL2Network } = await getLocalNetworks(
      LOCALHOST_L2_RPC,
      LOCALHOST_L3_RPC
    )
    l2Network = {
      ...coreL2Network,
      tokenBridge: {
        l1CustomGateway: '',
        l1ERC20Gateway: '',
        l1GatewayRouter: '',
        l1MultiCall: '',
        l1ProxyAdmin: '',
        l1Weth: '',
        l1WethGateway: '',

        l2CustomGateway: '',
        l2ERC20Gateway: '',
        l2GatewayRouter: '',
        l2Multicall: '',
        l2ProxyAdmin: '',
        l2Weth: '',
        l2WethGateway: '',
      },
    }
    if (!l2Networks[l2Network.chainID.toString()]) {
      if (!l1Networks[l2Network.chainID.toString()]) {
        addCustomNetwork({
          customL1Network: l1Network,
          customL2Network: l2Network,
        })
      } else {
        addCustomNetwork({
          customL2Network: l2Network,
        })
      }
    }

    l2Provider = new JsonRpcProvider(LOCALHOST_L2_RPC)
    l3Provider = new JsonRpcProvider(LOCALHOST_L3_RPC)
    userL2Wallet = new Wallet(
      ethers.utils.sha256(ethers.utils.toUtf8Bytes('user_fee_token_deployer')),
      l2Provider
    )
    userL3Wallet = new ethers.Wallet(userL2Wallet.privateKey, l3Provider)
    console.log((await userL3Wallet.getBalance()).toString())
    const nativeTokenAddress = await _getFeeToken(
      l2Network.ethBridge.inbox,
      l2Provider
    )
    nativeToken =
      nativeTokenAddress === ethers.constants.AddressZero
        ? undefined
        : ERC20__factory.connect(nativeTokenAddress, l2Provider)
    expect(nativeToken, 'native token undefined').to.not.eq(
      ethers.constants.AddressZero
    )
  })

  const batchPosterAddr = '0x3E6134aAD4C4d422FF2A4391Dc315c4DDf98D1a5'

  const sendTxAndWaitForBatch = async () => {
    const batchPosterNonceBefore = await l2Provider.getTransactionCount(
      batchPosterAddr,
      'latest'
    )
    const batchPosterL3BalanceBefore = await l3Provider.getBalance(
      batchPosterAddr
    )

    await (
      await userL3Wallet.sendTransaction({
        to: '0x00000000000000000000000000000000000000dd',
        value: 0,
      })
    ).wait()

    // wait for the batch poster to send their tx, we wait for their nonce to increase
    // eslint-disable-next-line no-constant-condition
    while (true) {
      const currentNonce = await l2Provider.getTransactionCount(
        batchPosterAddr,
        'latest'
      )
      if (currentNonce == batchPosterNonceBefore + 1) {
        break
      }
      await wait(1000)
    }

    // batch submission reports occur via delayed messages
    // wait until we see a change in the batch poster balance
    let batchPosterL3BalanceAfter = BigNumber.from('0')
    // eslint-disable-next-line no-constant-condition
    while (true) {
      batchPosterL3BalanceAfter = await l3Provider.getBalance(batchPosterAddr)
      if (!batchPosterL3BalanceAfter.eq(batchPosterL3BalanceBefore)) {
        break
      }
      await wait(1000)
    }

    return batchPosterL3BalanceAfter.sub(batchPosterL3BalanceBefore)
  }

  const getLatestBatchExpectedCost = async () => {
    const seqInbox = SequencerInbox__factory.connect(
      l2Network.ethBridge.sequencerInbox,
      l2Provider
    )
    const feeTokenPricerAddr = await seqInbox.callStatic.feeTokenPricer()
    const feeTokenPricer = IFeeTokenPricer__factory.connect(
      feeTokenPricerAddr,
      l2Provider
    )

    const batchSpendingReportEvents = await l2Provider.getLogs({
      address: seqInbox.address,
      fromBlock: 0,
      toBlock: 'latest',
      topics: seqInbox.interface.encodeFilterTopics(
        'InboxMessageDelivered',
        []
      ),
    })
    const batchSpendingReportEvent =
      batchSpendingReportEvents[batchSpendingReportEvents.length - 1]
    const batchSpendingReportData = seqInbox.interface.decodeEventLog(
      'InboxMessageDelivered',
      batchSpendingReportEvent.data,
      batchSpendingReportEvent.topics
    ).data as string

    const bp = batchSpendingReportData.substring(66, 106)
    const gasPrice = BigNumber.from(
      '0x' + batchSpendingReportData.substring(236, 298)
    )
    const extraGas = BigNumber.from(
      '0x' + batchSpendingReportData.substring(298)
    )
    expect('0x' + bp.toLowerCase(), 'batch poster from message').to.eq(
      batchPosterAddr.toLowerCase()
    )
    expect(extraGas.toNumber(), 'batch poster extra gas').to.eq(0)
    const l2GasPrice = await l2Provider.getGasPrice()
    const exchangeRate = await feeTokenPricer.callStatic.getExchangeRate()
    expect(
      l2GasPrice
        .mul(exchangeRate)
        .div(ethers.constants.WeiPerEther)
        .eq(gasPrice),
      'unexpected gas price'
    ).to.be.true
    const txData = (
      await l2Provider.getTransaction(batchSpendingReportEvent.transactionHash)
    ).data
    const batchtxData = seqInbox.interface.decodeFunctionData(
      seqInbox.interface.functions[
        'addSequencerL2BatchFromOrigin(uint256,bytes,uint256,address,uint256,uint256)'
      ],
      txData
    )
    const computeBatchCost = (batchData: string) => {
      const zeroBytes = batchData
        .substring(2)
        .split('')
        .reduce(
          (count, char, index, array) =>
            index % 2 === 0 && char === '0' && array[index + 1] === '0'
              ? count + 1
              : count,
          0
        )
      const nonZeroBytes = batchData
        .substring(2)
        .split('')
        .reduce(
          (count, char, index, array) =>
            index % 2 === 0 && (char !== '0' || array[index + 1] !== '0')
              ? count + 1
              : count,
          0
        )
      const dataGas = zeroBytes * 4 + nonZeroBytes * 16
      const words = Math.ceil(batchData.substring(2).length / 64)
      const keccakGas = words * 6 + 30
      const storageGas = 2 * 20000
      return dataGas + keccakGas + storageGas
    }
    const txReceipt = await l2Provider.getTransactionReceipt(
      batchSpendingReportEvent.transactionHash
    )
    const seqBatchDeliveredEvent = seqInbox.interface.decodeEventLog(
      'SequencerBatchDelivered',
      txReceipt.logs[txReceipt.logs.length - 1].data
    )

    const padTo8Byte = (b: BigNumber) => {
      return ethers.utils.hexZeroPad(b.toHexString(), 8).substring(2)
    }
    const headerVals =
      '0x' +
      padTo8Byte(seqBatchDeliveredEvent['timeBounds'].minTimestamp) +
      padTo8Byte(seqBatchDeliveredEvent['timeBounds'].maxTimestamp) +
      padTo8Byte(seqBatchDeliveredEvent['timeBounds'].minBlockNumber) +
      padTo8Byte(seqBatchDeliveredEvent['timeBounds'].maxBlockNumber) +
      padTo8Byte(seqBatchDeliveredEvent['afterDelayedMessagesRead'])

    const batchGas = computeBatchCost(
      headerVals + batchtxData['data'].substring(2)
    )
    const arbGasInfo = ArbGasInfo__factory.connect(ARB_GAS_INFO, l3Provider)
    const reimbursedGas =
      batchGas + (await arbGasInfo.getPerBatchGasCharge()).toNumber()
    return gasPrice.mul(reimbursedGas)
  }

  const prepareBatchPostingTest = async () => {
    // set some parameters to make the test easier to verify
    const l3Owner = ethers.Wallet.fromMnemonic(
      'indoor dish desk flag debris potato excuse depart ticket judge file exit',
      "m/44'/60'/0'/0/" + '3'
    ).connect(l3Provider)
    const arbOwner = ArbOwner__factory.connect(
      '0x0000000000000000000000000000000000000070',
      l3Owner
    )
    // set the l1 fees to be very high
    const arbGasInfo = ArbGasInfo__factory.connect(ARB_GAS_INFO, l3Provider)
    const l1BaseFeeEstimate = await arbGasInfo.getL1BaseFeeEstimate()
    if (l1BaseFeeEstimate.gt(BigNumber.from('15000000000'))) return

    const higherL1Price = l1BaseFeeEstimate.mul(1000)
    // set a higher l1 price per unit. Since we only send a single small transaction, the per batch
    // cost is over 100x greater than the data cost. This means that we need to set a much higher gas price
    // to cover these per batch costs. In a normal orbit chain we would expect the batch poster not to post
    // too frequently and this would keep per batch values a small percentage of the overall cost. We would expect
    // the l1 base fee estimate to increase by this small percentage.
    await (await arbOwner.setL1PricePerUnit(higherL1Price)).wait()
    // we want to ensure the batch poster is full refunded in this test, so we dont cap the amount
    // of amortized gas the batch poster should receive
    await (await arbOwner.setAmortizedCostCapBips(10000000)).wait()
    // it's possible to configure the batch poster or another address to receive a reward
    // we disable this to simplify this test
    await (await arbOwner.setL1PricingRewardRate(0)).wait()
  }

  it('batch poster can get refunded on L2', async function () {
    await prepareBatchPostingTest()

    // send 1 tx. We start out with a small negative surpluss, which will cause an over-refund
    // in the first batch. So we just send one to clear it
    await sendTxAndWaitForBatch()

    // now send a tx and batch and measure that the gas reimbursed is correct
    const reimbursedTokens = await sendTxAndWaitForBatch()
    const expectedReimbursedTokens = await getLatestBatchExpectedCost()

    // check that the balance diff is as expected
    expect(reimbursedTokens.toString(), 'reimbursed tokens').to.eq(
      expectedReimbursedTokens
    )
  })
})
