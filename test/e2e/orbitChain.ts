import {
  L1ToL2MessageGasEstimator,
  L1ToL2MessageStatus,
  L1TransactionReceipt,
  L2Network,
  L2TransactionReceipt,
  addCustomNetwork,
} from '@arbitrum/sdk'
import { getBaseFee } from '@arbitrum/sdk/dist/lib/utils/lib'
import { Filter, JsonRpcProvider } from '@ethersproject/providers'
import { expect } from 'chai'
import {
  ArbSys__factory,
  DeployHelper__factory,
  ERC20,
  ERC20Inbox__factory,
  ERC20__factory,
  EthVault__factory,
  IERC20Bridge__factory,
  IInbox__factory,
  Inbox__factory,
  RollupCore__factory,
  RollupCreator,
  RollupCreator__factory,
} from '../../build/types'
import { AssertionStateStruct } from '../../build/types/src/challengeV2/IAssertionChain'
import { getLocalNetworks } from '../../scripts/testSetup'
import { applyAlias } from '../contract/utils'
import { BigNumber, ContractTransaction, Wallet, ethers } from 'ethers'
import {
  l1Networks,
  l2Networks,
} from '@arbitrum/sdk/dist/lib/dataEntities/networks'
import { ConfigStruct } from '../../build/types/src/rollup/RollupCreator'

const LOCALHOST_L2_RPC = 'http://127.0.0.1:8547'
const LOCALHOST_L3_RPC = 'http://127.0.0.1:3347'

// when code at address is empty, ethers.js returns '0x'
const EMPTY_CODE_LENGTH = 2

let l1Provider: JsonRpcProvider
let l2Provider: JsonRpcProvider

let l2Network: L2Network
let userL1Wallet: Wallet
let userL2Wallet: Wallet
let nativeToken: ERC20 | undefined
const excessFeeRefundAddress = Wallet.createRandom().address
const callValueRefundAddress = Wallet.createRandom().address

describe('Orbit Chain', () => {
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

    l1Provider = new JsonRpcProvider(LOCALHOST_L2_RPC)
    l2Provider = new JsonRpcProvider(LOCALHOST_L3_RPC)
    userL1Wallet = new Wallet(
      ethers.utils.sha256(
        ethers.utils.toUtf8Bytes('user_token_bridge_deployer')
      ),
      l1Provider
    )
    userL2Wallet = new ethers.Wallet(userL1Wallet.privateKey, l2Provider)

    const nativeTokenAddress = await _getFeeToken(
      l2Network.ethBridge.inbox,
      l1Provider
    )
    nativeToken =
      nativeTokenAddress === ethers.constants.AddressZero
        ? undefined
        : ERC20__factory.connect(nativeTokenAddress, l1Provider)
  })

  it('should have deployed bridge contracts', async function () {
    // get rollup as entry point
    const rollup = RollupCore__factory.connect(
      l2Network.ethBridge.rollup,
      l1Provider
    )

    // check contract refs are properly set
    expect(rollup.address).to.be.eq(l2Network.ethBridge.rollup)
    expect(await rollup.sequencerInbox()).to.be.eq(
      l2Network.ethBridge.sequencerInbox
    )
    expect(await rollup.outbox()).to.be.eq(l2Network.ethBridge.outbox)
    expect(await rollup.inbox()).to.be.eq(l2Network.ethBridge.inbox)
    expect(await rollup.bridge()).to.be.eq(l2Network.ethBridge.bridge)
  })

  it('can deposit native asset to L2', async function () {
    // snapshot state before deposit
    const userL2Balance = await l2Provider.getBalance(userL2Wallet.address)
    let userL1NativeAssetBalance: BigNumber
    let bridgeL1NativeAssetBalance: BigNumber

    if (nativeToken) {
      userL1NativeAssetBalance = await nativeToken.balanceOf(
        userL1Wallet.address
      )
      bridgeL1NativeAssetBalance = await nativeToken.balanceOf(
        l2Network.ethBridge.bridge
      )
    } else {
      userL1NativeAssetBalance = await l1Provider.getBalance(
        userL1Wallet.address
      )
      bridgeL1NativeAssetBalance = await l1Provider.getBalance(
        l2Network.ethBridge.bridge
      )
    }

    /// bridge native asset
    const amountToDeposit = await _applyDecimalsToAmount('3')

    let depositTx
    if (nativeToken) {
      await (
        await nativeToken
          .connect(userL1Wallet)
          .approve(l2Network.ethBridge.inbox, amountToDeposit)
      ).wait()
      depositTx = await ERC20Inbox__factory.connect(
        l2Network.ethBridge.inbox,
        userL1Wallet
      ).depositERC20(amountToDeposit)
    } else {
      depositTx = await Inbox__factory.connect(
        l2Network.ethBridge.inbox,
        userL1Wallet
      )['depositEth()']({ value: amountToDeposit })
    }

    // wait for deposit to be processed
    const depositRec = await L1TransactionReceipt.monkeyPatchEthDepositWait(
      depositTx
    ).wait()
    const l2Result = await depositRec.waitForL2(l2Provider)
    expect(l2Result.complete).to.be.true

    // check user balance decreased on L1
    let userL1NativeAssetBalanceAfter: BigNumber
    if (nativeToken) {
      userL1NativeAssetBalanceAfter = await nativeToken.balanceOf(
        userL1Wallet.address
      )
      expect(
        userL1NativeAssetBalance.sub(userL1NativeAssetBalanceAfter)
      ).to.be.eq(amountToDeposit)
    } else {
      userL1NativeAssetBalanceAfter = await l1Provider.getBalance(
        userL1Wallet.address
      )
      expect(
        userL1NativeAssetBalance.sub(userL1NativeAssetBalanceAfter)
      ).to.be.gte(amountToDeposit)
    }

    // check user balance increased on L2
    const userL2BalanceAfter = await l2Provider.getBalance(userL2Wallet.address)
    let expectedL2BalanceIncrease = amountToDeposit
    if (nativeToken) {
      expectedL2BalanceIncrease = await _scaleFromNativeTo18(amountToDeposit)
    }
    expect(userL2BalanceAfter.sub(userL2Balance)).to.be.eq(
      expectedL2BalanceIncrease
    )

    // check bridge balance increased
    let bridgeL1NativeAssetBalanceAfter
    if (nativeToken) {
      bridgeL1NativeAssetBalanceAfter = await nativeToken.balanceOf(
        l2Network.ethBridge.bridge
      )
    } else {
      bridgeL1NativeAssetBalanceAfter = await l1Provider.getBalance(
        l2Network.ethBridge.bridge
      )
    }
    expect(
      bridgeL1NativeAssetBalanceAfter.sub(bridgeL1NativeAssetBalance)
    ).to.be.eq(amountToDeposit)
  })

  it('can issue retryable ticket (no calldata)', async function () {
    // snapshot state before deposit
    const userL2Balance = await l2Provider.getBalance(userL2Wallet.address)
    const aliasL2Balance = await l2Provider.getBalance(
      applyAlias(userL2Wallet.address)
    )
    const excessFeeReceiverBalance = await l2Provider.getBalance(
      excessFeeRefundAddress
    )
    const callValueRefundReceiverBalance = await l2Provider.getBalance(
      callValueRefundAddress
    )

    let userL1NativeAssetBalance: BigNumber
    let bridgeL1NativeAssetBalance: BigNumber
    if (nativeToken) {
      userL1NativeAssetBalance = await nativeToken.balanceOf(
        userL1Wallet.address
      )
      bridgeL1NativeAssetBalance = await nativeToken.balanceOf(
        l2Network.ethBridge.bridge
      )
    } else {
      userL1NativeAssetBalance = await l1Provider.getBalance(
        userL1Wallet.address
      )
      bridgeL1NativeAssetBalance = await l1Provider.getBalance(
        l2Network.ethBridge.bridge
      )
    }

    //// retryables params

    const to = userL1Wallet.address
    const l2CallValue = await _applyDecimalsToAmount('2')
    const data = '0x'

    const l1ToL2MessageGasEstimate = new L1ToL2MessageGasEstimator(l2Provider)
    const retryableParams = await l1ToL2MessageGasEstimate.estimateAll(
      {
        from: userL1Wallet.address,
        to: to,
        l2CallValue: l2CallValue,
        excessFeeRefundAddress: excessFeeRefundAddress,
        callValueRefundAddress: callValueRefundAddress,
        data: data,
      },
      await getBaseFee(l1Provider),
      l1Provider
    )

    let tokenTotalFeeAmount = retryableParams.deposit
    const gasLimit = retryableParams.gasLimit
    const maxFeePerGas = retryableParams.maxFeePerGas
    const maxSubmissionCost = retryableParams.maxSubmissionCost

    /// deposit tokens using retryable
    let retryableTx: ContractTransaction
    if (nativeToken) {
      tokenTotalFeeAmount = await _scaleFrom18ToNative(retryableParams.deposit)

      await (
        await nativeToken
          .connect(userL1Wallet)
          .approve(l2Network.ethBridge.inbox, tokenTotalFeeAmount)
      ).wait()

      retryableTx = await ERC20Inbox__factory.connect(
        l2Network.ethBridge.inbox,
        userL1Wallet
      )
        .connect(userL1Wallet)
        .createRetryableTicket(
          to,
          l2CallValue,
          maxSubmissionCost,
          excessFeeRefundAddress,
          callValueRefundAddress,
          gasLimit,
          maxFeePerGas,
          tokenTotalFeeAmount,
          data
        )
    } else {
      retryableTx = await Inbox__factory.connect(
        l2Network.ethBridge.inbox,
        userL1Wallet
      )
        .connect(userL1Wallet)
        .createRetryableTicket(
          to,
          l2CallValue,
          maxSubmissionCost,
          excessFeeRefundAddress,
          callValueRefundAddress,
          gasLimit,
          maxFeePerGas,
          data,
          { value: retryableParams.deposit }
        )
    }

    // wait for L2 msg to be executed
    await waitOnL2Msg(retryableTx)

    // check balances after retryable is processed
    let userL1TokenAfter, bridgeL1TokenAfter: BigNumber
    if (nativeToken) {
      userL1TokenAfter = await nativeToken.balanceOf(userL1Wallet.address)
      bridgeL1TokenAfter = await nativeToken.balanceOf(
        l2Network.ethBridge.bridge
      )

      expect(userL1NativeAssetBalance.sub(userL1TokenAfter)).to.be.eq(
        tokenTotalFeeAmount
      )
      expect(bridgeL1TokenAfter.sub(bridgeL1NativeAssetBalance)).to.be.eq(
        tokenTotalFeeAmount
      )
    } else {
      userL1TokenAfter = await l1Provider.getBalance(userL1Wallet.address)
      bridgeL1TokenAfter = await l1Provider.getBalance(
        l2Network.ethBridge.bridge
      )
      expect(userL1NativeAssetBalance.sub(userL1TokenAfter)).to.be.gte(
        retryableParams.deposit
      )
      expect(bridgeL1TokenAfter.sub(bridgeL1NativeAssetBalance)).to.be.eq(
        retryableParams.deposit
      )
    }

    const userL2After = await l2Provider.getBalance(userL2Wallet.address)
    expect(userL2After.sub(userL2Balance)).to.be.eq(l2CallValue)

    const aliasL2BalanceAfter = await l2Provider.getBalance(
      applyAlias(userL2Wallet.address)
    )
    let expectedAliasL2BalanceExtraFunds = BigNumber.from(0)
    // due to rounding effect there can be some funds left on alias address
    if (nativeToken && (await nativeToken.decimals()) < 18) {
      expectedAliasL2BalanceExtraFunds = (
        await _scaleFromNativeTo18(tokenTotalFeeAmount)
      ).sub(retryableParams.deposit)
    }
    expect(aliasL2BalanceAfter.sub(expectedAliasL2BalanceExtraFunds)).to.be.eq(
      aliasL2Balance
    )

    const excessFeeReceiverBalanceAfter = await l2Provider.getBalance(
      excessFeeRefundAddress
    )
    expect(excessFeeReceiverBalanceAfter).to.be.gte(excessFeeReceiverBalance)

    const callValueRefundReceiverBalanceAfter = await l2Provider.getBalance(
      callValueRefundAddress
    )
    expect(callValueRefundReceiverBalanceAfter).to.be.eq(
      callValueRefundReceiverBalance
    )
  })

  it('can issue retryable ticket', async function () {
    // deploy contract on L2 which will be retryable's target
    const ethVaultContract = await new EthVault__factory(
      userL2Wallet.connect(l2Provider)
    ).deploy()
    await ethVaultContract.deployed()

    // snapshot state before retryable
    let userL1NativeAssetBalance, bridgeL1NativeAssetBalance: BigNumber
    if (nativeToken) {
      userL1NativeAssetBalance = await nativeToken.balanceOf(
        userL1Wallet.address
      )
      bridgeL1NativeAssetBalance = await nativeToken.balanceOf(
        l2Network.ethBridge.bridge
      )
    } else {
      userL1NativeAssetBalance = await l1Provider.getBalance(
        userL1Wallet.address
      )
      bridgeL1NativeAssetBalance = await l1Provider.getBalance(
        l2Network.ethBridge.bridge
      )
    }

    const userL2Balance = await l2Provider.getBalance(userL2Wallet.address)
    const aliasL2Balance = await l2Provider.getBalance(
      applyAlias(userL2Wallet.address)
    )

    const excessFeeReceiverBalance = await l2Provider.getBalance(
      excessFeeRefundAddress
    )
    const callValueRefundReceiverBalance = await l2Provider.getBalance(
      callValueRefundAddress
    )

    //// retryables params

    const to = ethVaultContract.address
    const l2CallValue = await _applyDecimalsToAmount('1')
    // calldata -> change 'version' field to 11
    const newValue = 11
    const data = new ethers.utils.Interface([
      'function setVersion(uint256 _version)',
    ]).encodeFunctionData('setVersion', [newValue])

    const l1ToL2MessageGasEstimate = new L1ToL2MessageGasEstimator(l2Provider)
    const retryableParams = await l1ToL2MessageGasEstimate.estimateAll(
      {
        from: userL1Wallet.address,
        to: to,
        l2CallValue: l2CallValue,
        excessFeeRefundAddress: excessFeeRefundAddress,
        callValueRefundAddress: callValueRefundAddress,
        data: data,
      },
      await getBaseFee(l1Provider),
      l1Provider
    )

    let tokenTotalFeeAmount = retryableParams.deposit
    const gasLimit = retryableParams.gasLimit
    const maxFeePerGas = retryableParams.maxFeePerGas
    const maxSubmissionCost = retryableParams.maxSubmissionCost

    /// execute retryable
    let retryableTx: ContractTransaction
    if (nativeToken) {
      tokenTotalFeeAmount = await _scaleFrom18ToNative(retryableParams.deposit)

      await (
        await nativeToken
          .connect(userL1Wallet)
          .approve(l2Network.ethBridge.inbox, tokenTotalFeeAmount)
      ).wait()

      retryableTx = await ERC20Inbox__factory.connect(
        l2Network.ethBridge.inbox,
        userL1Wallet
      )
        .connect(userL1Wallet)
        .createRetryableTicket(
          to,
          l2CallValue,
          maxSubmissionCost,
          excessFeeRefundAddress,
          callValueRefundAddress,
          gasLimit,
          maxFeePerGas,
          tokenTotalFeeAmount,
          data
        )
    } else {
      retryableTx = await Inbox__factory.connect(
        l2Network.ethBridge.inbox,
        userL1Wallet
      )
        .connect(userL1Wallet)
        .createRetryableTicket(
          to,
          l2CallValue,
          maxSubmissionCost,
          excessFeeRefundAddress,
          callValueRefundAddress,
          gasLimit,
          maxFeePerGas,
          data,
          { value: retryableParams.deposit }
        )
    }

    // wait for L2 msg to be executed
    await waitOnL2Msg(retryableTx)

    // check balances after retryable is processed
    let userL1TokenAfter, bridgeL1TokenAfter: BigNumber
    if (nativeToken) {
      userL1TokenAfter = await nativeToken.balanceOf(userL1Wallet.address)

      bridgeL1TokenAfter = await nativeToken.balanceOf(
        l2Network.ethBridge.bridge
      )
    } else {
      userL1TokenAfter = await l1Provider.getBalance(userL1Wallet.address)

      bridgeL1TokenAfter = await l1Provider.getBalance(
        l2Network.ethBridge.bridge
      )
    }
    expect(userL1NativeAssetBalance.sub(userL1TokenAfter)).to.be.gte(
      tokenTotalFeeAmount
    )
    expect(bridgeL1TokenAfter.sub(bridgeL1NativeAssetBalance)).to.be.eq(
      tokenTotalFeeAmount
    )

    const userL2After = await l2Provider.getBalance(userL2Wallet.address)
    expect(userL2After).to.be.eq(userL2Balance)

    const ethVaultBalanceAfter = await l2Provider.getBalance(
      ethVaultContract.address
    )
    expect(ethVaultBalanceAfter).to.be.eq(l2CallValue)

    const ethVaultVersion = await ethVaultContract.version()
    expect(ethVaultVersion).to.be.eq(newValue)

    const aliasL2BalanceAfter = await l2Provider.getBalance(
      applyAlias(userL1Wallet.address)
    )
    let expectedAliasL2BalanceExtraFunds = BigNumber.from(0)
    // due to rounding effect there can be some funds left on alias address
    if (nativeToken && (await nativeToken.decimals()) < 18) {
      expectedAliasL2BalanceExtraFunds = (
        await _scaleFromNativeTo18(tokenTotalFeeAmount)
      ).sub(retryableParams.deposit)
    }
    expect(aliasL2BalanceAfter.sub(expectedAliasL2BalanceExtraFunds)).to.be.eq(
      aliasL2Balance
    )

    const excessFeeReceiverBalanceAfter = await l2Provider.getBalance(
      excessFeeRefundAddress
    )
    expect(excessFeeReceiverBalanceAfter).to.be.gte(excessFeeReceiverBalance)

    const callValueRefundReceiverBalanceAfter = await l2Provider.getBalance(
      callValueRefundAddress
    )
    expect(callValueRefundReceiverBalanceAfter).to.be.eq(
      callValueRefundReceiverBalance
    )
  })

  it('can withdraw funds from L2 to L1', async function () {
    // snapshot state before issuing retryable
    let userL1NativeAssetBalance: BigNumber
    let bridgeL1NativeAssetBalance: BigNumber
    if (nativeToken) {
      userL1NativeAssetBalance = await nativeToken.balanceOf(
        userL1Wallet.address
      )
      bridgeL1NativeAssetBalance = await nativeToken.balanceOf(
        l2Network.ethBridge.bridge
      )
    } else {
      userL1NativeAssetBalance = await l1Provider.getBalance(
        userL1Wallet.address
      )
      bridgeL1NativeAssetBalance = await l1Provider.getBalance(
        l2Network.ethBridge.bridge
      )
    }

    const userL2Balance = await l2Provider.getBalance(userL2Wallet.address)

    /// send L2 to L1 TX
    const arbSys = ArbSys__factory.connect(
      '0x0000000000000000000000000000000000000064',
      l2Provider
    )
    const withdrawAmount = ethers.utils.parseEther('1')
    const withdrawTx = await arbSys
      .connect(userL2Wallet)
      .sendTxToL1(userL1Wallet.address, '0x', {
        value: withdrawAmount,
      })
    const withdrawReceipt = await withdrawTx.wait()
    const l2Receipt = new L2TransactionReceipt(withdrawReceipt)

    // wait until dispute period passes and withdrawal is ready for execution
    const messages = await l2Receipt.getL2ToL1Messages(userL1Wallet)
    const l2ToL1Msg = messages[0]
    const timeToWaitMs = 60 * 1000
    await l2ToL1Msg.waitUntilReadyToExecute(l2Provider, timeToWaitMs)

    // execute
    await (await l2ToL1Msg.execute(l2Provider)).wait()

    // check balances after withdrawal is processed
    const withdrawAmountInNativeDecimals =
      nativeToken == undefined
        ? withdrawAmount
        : await _scaleFrom18ToNative(withdrawAmount)

    let userL1NativeAssetBalanceAfter,
      bridgeL1NativeAssetBalanceAfter: BigNumber
    if (nativeToken) {
      userL1NativeAssetBalanceAfter = await nativeToken.balanceOf(
        userL1Wallet.address
      )
      bridgeL1NativeAssetBalanceAfter = await nativeToken.balanceOf(
        l2Network.ethBridge.bridge
      )
      expect(
        userL1NativeAssetBalanceAfter.sub(userL1NativeAssetBalance)
      ).to.be.eq(withdrawAmountInNativeDecimals)
    } else {
      userL1NativeAssetBalanceAfter = await l1Provider.getBalance(
        userL1Wallet.address
      )
      bridgeL1NativeAssetBalanceAfter = await l1Provider.getBalance(
        l2Network.ethBridge.bridge
      )
      expect(
        userL1NativeAssetBalanceAfter.sub(userL1NativeAssetBalance)
      ).to.be.lte(withdrawAmount)
      expect(
        userL1NativeAssetBalanceAfter.sub(userL1NativeAssetBalance)
      ).to.be.gt(BigNumber.from(0))
    }

    expect(
      bridgeL1NativeAssetBalance.sub(bridgeL1NativeAssetBalanceAfter)
    ).to.be.eq(withdrawAmountInNativeDecimals)

    const userL2BalanceAfter = await l2Provider.getBalance(userL2Wallet.address)
    expect(userL2BalanceAfter).to.be.lte(
      userL2Balance.sub(withdrawAmountInNativeDecimals)
    )
  })

  it('can deploy deterministic factories to L2', async function () {
    const rollupCreator = RollupCreator__factory.connect(
      await _getRollupCreatorFromLogs(l1Provider),
      l1Provider
    )

    const deployHelper = DeployHelper__factory.connect(
      await rollupCreator.l2FactoriesDeployer(),
      l1Provider
    )

    const inbox = l2Network.ethBridge.inbox
    const maxFeePerGas = BigNumber.from('100000000') // 0.1 gwei
    let fee = await deployHelper.getDeploymentTotalCost(inbox, maxFeePerGas, {
      from: userL1Wallet.address,
      gasPrice: maxFeePerGas,
    })

    if (nativeToken) {
      const decimals = await nativeToken.decimals()
      if (decimals < 18) {
        // if token has less than 18 decimals we need to sum fee costs per each retryable,
        // as there could be rounding effect for each one of them
        fee = BigNumber.from(0)
        fee = fee.add(
          await _scaleFrom18ToNative(
            (
              await deployHelper.NICK_CREATE2_VALUE()
            ).add(maxFeePerGas.mul(BigNumber.from(21000)))
          )
        )
        fee = fee.add(
          await _scaleFrom18ToNative(
            (
              await deployHelper.ERC2470_VALUE()
            ).add(maxFeePerGas.mul(BigNumber.from(21000)))
          )
        )
        fee = fee.add(
          await _scaleFrom18ToNative(
            (
              await deployHelper.ZOLTU_VALUE()
            ).add(maxFeePerGas.mul(BigNumber.from(21000)))
          )
        )
        fee = fee.add(
          await _scaleFrom18ToNative(
            (
              await deployHelper.ERC1820_VALUE()
            ).add(maxFeePerGas.mul(BigNumber.from(21000)))
          )
        )
      } else {
        fee = await _scaleFrom18ToNative(fee)
      }

      await (
        await nativeToken.connect(userL1Wallet).transfer(inbox, fee)
      ).wait()
    }

    const receipt = await (
      await deployHelper
        .connect(userL1Wallet)
        .perform(
          inbox,
          nativeToken ? nativeToken.address : ethers.constants.AddressZero,
          maxFeePerGas,
          { value: nativeToken ? BigNumber.from(0) : fee }
        )
    ).wait()

    const l1TxReceipt = new L1TransactionReceipt(receipt)
    const messages = await l1TxReceipt.getL1ToL2Messages(l2Provider)
    const messageResults = await Promise.all(
      messages.map(message => message.waitForStatus())
    )

    expect(messageResults[0].status).to.be.eq(L1ToL2MessageStatus.REDEEMED)
    expect(messageResults[1].status).to.be.eq(L1ToL2MessageStatus.REDEEMED)
    expect(messageResults[2].status).to.be.eq(L1ToL2MessageStatus.REDEEMED)
    expect(messageResults[3].status).to.be.eq(L1ToL2MessageStatus.REDEEMED)

    const deployedFactories = [
      '0x4e59b44847b379578588920ca78fbf26c0b4956c',
      '0xce0042B868300000d44A59004Da54A005ffdcf9f',
      '0x7A0D94F55792C434d74a40883C6ed8545E406D12',
      '0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24',
    ]
    deployedFactories.forEach(async factory => {
      expect((await l2Provider.getCode(factory)).length).to.be.gt(
        EMPTY_CODE_LENGTH
      )
    })
  })

  it('can deploy deterministic factories to L2 through RollupCreator', async function () {
    const rollupCreator = RollupCreator__factory.connect(
      await _getRollupCreatorFromLogs(l1Provider),
      l1Provider
    )

    const deployHelper = DeployHelper__factory.connect(
      await rollupCreator.l2FactoriesDeployer(),
      l1Provider
    )

    const inbox = l2Network.ethBridge.inbox
    const maxFeePerGas = BigNumber.from('100000000') // 0.1 gwei
    let fee = await deployHelper.getDeploymentTotalCost(inbox, maxFeePerGas, {
      from: userL1Wallet.address,
      gasPrice: maxFeePerGas,
    })
    if (nativeToken) {
      const decimals = await nativeToken.decimals()
      if (decimals < 18) {
        // if token has less than 18 decimals we need to sum fee costs per each retryable,
        // as there could be rounding effect for each one of them
        fee = BigNumber.from(0)
        fee = fee.add(
          await _scaleFrom18ToNative(
            (
              await deployHelper.NICK_CREATE2_VALUE()
            ).add(maxFeePerGas.mul(BigNumber.from(21000)))
          )
        )
        fee = fee.add(
          await _scaleFrom18ToNative(
            (
              await deployHelper.ERC2470_VALUE()
            ).add(maxFeePerGas.mul(BigNumber.from(21000)))
          )
        )
        fee = fee.add(
          await _scaleFrom18ToNative(
            (
              await deployHelper.ZOLTU_VALUE()
            ).add(maxFeePerGas.mul(BigNumber.from(21000)))
          )
        )
        fee = fee.add(
          await _scaleFrom18ToNative(
            (
              await deployHelper.ERC1820_VALUE()
            ).add(maxFeePerGas.mul(BigNumber.from(21000)))
          )
        )
      } else {
        fee = await _scaleFrom18ToNative(fee)
      }

      await (
        await nativeToken
          .connect(userL1Wallet)
          .approve(rollupCreator.address, fee)
      ).wait()
    }

    let userL1NativeAssetBalance: BigNumber
    if (nativeToken) {
      userL1NativeAssetBalance = await nativeToken.balanceOf(
        userL1Wallet.address
      )
    } else {
      userL1NativeAssetBalance = await l1Provider.getBalance(
        userL1Wallet.address
      )
    }

    const genesisAssertionState: AssertionStateStruct = {
      globalState: {
        bytes32Vals: [ethers.constants.HashZero, ethers.constants.HashZero],
        u64Vals: [ethers.BigNumber.from('0'), ethers.BigNumber.from('0')],
      },
      machineStatus: 0,
      endHistoryRoot: ethers.constants.HashZero,
    }

    /// deploy params
    const ownerAddr = '0x72f7EEedF02C522242a4D3Bdc8aE6A8583aD7c5e'
    const config: ConfigStruct = {
      confirmPeriodBlocks: ethers.BigNumber.from('150'),
      stakeToken: ethers.constants.AddressZero,
      baseStake: ethers.utils.parseEther('1'),
      wasmModuleRoot:
        '0xda4e3ad5e7feacb817c21c8d0220da7650fe9051ece68a3f0b1c5d38bbb27b21',
      owner: ownerAddr,
      loserStakeEscrow: ownerAddr,
      chainId: ethers.BigNumber.from('433333'),
      chainConfig:
        '{"chainId":433333,"homesteadBlock":0,"daoForkBlock":null,"daoForkSupport":true,"eip150Block":0,"eip150Hash":"0x0000000000000000000000000000000000000000000000000000000000000000","eip155Block":0,"eip158Block":0,"byzantiumBlock":0,"constantinopleBlock":0,"petersburgBlock":0,"istanbulBlock":0,"muirGlacierBlock":0,"berlinBlock":0,"londonBlock":0,"clique":{"period":0,"epoch":0},"arbitrum":{"EnableArbOS":true,"AllowDebugPrecompiles":false,"DataAvailabilityCommittee":false,"InitialArbOSVersion":10,"InitialChainOwner":"0x72f7EEedF02C522242a4D3Bdc8aE6A8583aD7c5e","GenesisBlockNum":0}}',
      minimumAssertionPeriod: 75,
      validatorAfkBlocks: 201600,
      genesisAssertionState: genesisAssertionState, // AssertionState
      genesisInboxCount: 0,
      miniStakeValues: [
        ethers.utils.parseEther('1'),
        ethers.utils.parseEther('1'),
        ethers.utils.parseEther('1'),
      ],
      layerZeroBlockEdgeHeight: 2 ** 5,
      layerZeroBigStepEdgeHeight: 2 ** 5,
      layerZeroSmallStepEdgeHeight: 2 ** 5,
      anyTrustFastConfirmer: ethers.constants.AddressZero,
      numBigStepLevel: 1,
      challengeGracePeriodBlocks: 10,
      bufferConfig: { threshold: 600, max: 14400, replenishRateInBasis: 500 },
      sequencerInboxMaxTimeVariation: {
        delayBlocks: ethers.BigNumber.from('5760'),
        futureBlocks: ethers.BigNumber.from('12'),
        delaySeconds: ethers.BigNumber.from('86400'),
        futureSeconds: ethers.BigNumber.from('3600'),
      },
    }
    const batchPosters = [ethers.Wallet.createRandom().address]
    const batchPosterManager = ethers.Wallet.createRandom().address
    const validators = [ethers.Wallet.createRandom().address]
    const maxDataSize = 104857
    const nativeTokenAddress = nativeToken
      ? nativeToken.address
      : ethers.constants.AddressZero
    const deployFactoriesToL2 = true
    const maxFeePerGasForRetryables = BigNumber.from('100000000') // 0.1 gwei

    const deployParams: RollupCreator.RollupDeploymentParamsStruct = {
      config,
      batchPosters,
      batchPosterManager,
      validators,
      maxDataSize,
      nativeToken: nativeTokenAddress,
      deployFactoriesToL2,
      maxFeePerGasForRetryables,
      feeTokenPricer: ethers.constants.AddressZero,
    }

    /// deploy it
    const receipt = await (
      await rollupCreator.connect(userL1Wallet).createRollup(deployParams, {
        value: nativeToken ? BigNumber.from(0) : fee,
      })
    ).wait()

    const l1TxReceipt = new L1TransactionReceipt(receipt)

    // 1 init message + 8 msgs for deploying factories
    const events = l1TxReceipt.getMessageEvents()
    expect(events.length).to.be.eq(9)

    // 1st retryable
    expect(events[1].inboxMessageEvent.messageNum.toString()).to.be.eq('1')
    await _verifyInboxMsg(
      events[1].inboxMessageEvent.data,
      await deployHelper.NICK_CREATE2_DEPLOYER(),
      await deployHelper.NICK_CREATE2_VALUE(),
      receipt.effectiveGasPrice,
      rollupCreator.address
    )
    expect(events[2].inboxMessageEvent.messageNum.toString()).to.be.eq('2')
    expect(events[2].inboxMessageEvent.data).to.be.eq(
      await deployHelper.NICK_CREATE2_PAYLOAD()
    )

    // 2nd retryable
    expect(events[3].inboxMessageEvent.messageNum.toString()).to.be.eq('3')
    await _verifyInboxMsg(
      events[3].inboxMessageEvent.data,
      await deployHelper.ERC2470_DEPLOYER(),
      await deployHelper.ERC2470_VALUE(),
      receipt.effectiveGasPrice,
      rollupCreator.address
    )
    expect(events[4].inboxMessageEvent.messageNum.toString()).to.be.eq('4')
    expect(events[4].inboxMessageEvent.data).to.be.eq(
      await deployHelper.ERC2470_PAYLOAD()
    )

    // 3rd retryable
    expect(events[5].inboxMessageEvent.messageNum.toString()).to.be.eq('5')
    await _verifyInboxMsg(
      events[5].inboxMessageEvent.data,
      await deployHelper.ZOLTU_CREATE2_DEPLOYER(),
      await deployHelper.ZOLTU_VALUE(),
      receipt.effectiveGasPrice,
      rollupCreator.address
    )
    expect(events[6].inboxMessageEvent.messageNum.toString()).to.be.eq('6')
    expect(events[6].inboxMessageEvent.data).to.be.eq(
      await deployHelper.ZOLTU_CREATE2_PAYLOAD()
    )

    // 4th retryable
    expect(events[7].inboxMessageEvent.messageNum.toString()).to.be.eq('7')
    await _verifyInboxMsg(
      events[7].inboxMessageEvent.data,
      await deployHelper.ERC1820_DEPLOYER(),
      await deployHelper.ERC1820_VALUE(),
      receipt.effectiveGasPrice,
      rollupCreator.address
    )
    expect(events[8].inboxMessageEvent.messageNum.toString()).to.be.eq('8')
    expect(events[8].inboxMessageEvent.data).to.be.eq(
      await deployHelper.ERC1820_PAYLOAD()
    )

    // check total amount to be minted is correct
    const { amountToBeMintedOnChildChain: amount1 } = await _decodeInboxMessage(
      events[1].inboxMessageEvent.data
    )
    const { amountToBeMintedOnChildChain: amount2 } = await _decodeInboxMessage(
      events[3].inboxMessageEvent.data
    )
    const { amountToBeMintedOnChildChain: amount3 } = await _decodeInboxMessage(
      events[5].inboxMessageEvent.data
    )
    const { amountToBeMintedOnChildChain: amount4 } = await _decodeInboxMessage(
      events[7].inboxMessageEvent.data
    )
    const amountToBeMinted = amount1.add(amount2).add(amount3).add(amount4)
    let expectedAmountToBeMinted = amountToBeMinted
    if (nativeToken && (await nativeToken.decimals()) < 18) {
      // sum up every retryable cost separately due to rounding effect possibly applied to each one
      const gasCost = maxFeePerGas.mul(BigNumber.from(21000))
      expectedAmountToBeMinted = BigNumber.from(0)
      expectedAmountToBeMinted = expectedAmountToBeMinted.add(
        await _scaleFrom18ToNative(
          (await deployHelper.NICK_CREATE2_VALUE()).add(gasCost)
        )
      )
      expectedAmountToBeMinted = expectedAmountToBeMinted.add(
        await _scaleFrom18ToNative(
          (await deployHelper.ERC2470_VALUE()).add(gasCost)
        )
      )
      expectedAmountToBeMinted = expectedAmountToBeMinted.add(
        await _scaleFrom18ToNative(
          (await deployHelper.ZOLTU_VALUE()).add(gasCost)
        )
      )
      expectedAmountToBeMinted = expectedAmountToBeMinted.add(
        await _scaleFrom18ToNative(
          (await deployHelper.ERC1820_VALUE()).add(gasCost)
        )
      )
      expectedAmountToBeMinted = await _scaleFromNativeTo18(
        expectedAmountToBeMinted
      )
    }

    expect(amountToBeMinted).to.be.eq(expectedAmountToBeMinted)

    // check amount locked (taken from deployer) matches total amount to be minted
    let amountTransferedFromDeployer
    if (nativeToken) {
      const transferLogs = receipt.logs.filter(log =>
        log.topics.includes(nativeToken!.interface.getEventTopic('Transfer'))
      )
      const decodedEvents = transferLogs.map(
        log => nativeToken!.interface.parseLog(log).args
      )
      const transferedFromDeployer = decodedEvents.filter(
        log => log.from === userL1Wallet.address
      )
      expect(transferedFromDeployer.length).to.be.eq(1)
      amountTransferedFromDeployer = transferedFromDeployer[0].value
      expect(await _scaleFromNativeTo18(amountTransferedFromDeployer)).to.be.eq(
        amountToBeMinted
      )
    } else {
      amountTransferedFromDeployer = userL1NativeAssetBalance.sub(
        await l1Provider.getBalance(userL1Wallet.address)
      )
      expect(amountTransferedFromDeployer).to.be.gte(amountToBeMinted)
    }

    // check balances after retryable is processed
    let userL1NativeAssetBalanceAfter, bridgeBalanceAfter: BigNumber
    const rollupCreatedEvent = receipt.logs.filter(log =>
      log.topics.includes(
        rollupCreator.interface.getEventTopic('RollupCreated')
      )
    )[0]
    const decodedRollupCreatedEvent =
      rollupCreator.interface.parseLog(rollupCreatedEvent)
    const bridge = decodedRollupCreatedEvent.args.bridge
    if (nativeToken) {
      userL1NativeAssetBalanceAfter = await nativeToken.balanceOf(
        userL1Wallet.address
      )
      expect(
        userL1NativeAssetBalance.sub(userL1NativeAssetBalanceAfter)
      ).to.be.eq(amountTransferedFromDeployer)
      bridgeBalanceAfter = await nativeToken.balanceOf(bridge)
      expect(bridgeBalanceAfter).to.be.eq(amountTransferedFromDeployer)
    } else {
      userL1NativeAssetBalanceAfter = await l1Provider.getBalance(
        userL1Wallet.address
      )
      bridgeBalanceAfter = await l1Provider.getBalance(bridge)
      expect(
        userL1NativeAssetBalance.sub(userL1NativeAssetBalanceAfter)
      ).to.be.eq(amountTransferedFromDeployer)
      expect(bridgeBalanceAfter).to.be.eq(amountToBeMinted)
    }
  })
})

async function _verifyInboxMsg(
  inboxMsg: string,
  create2Deployer: string,
  create2Value: BigNumber,
  gasPrice: BigNumber,
  rollupCreatorAddress: string
) {
  const maxFeePerGasForRetryables = BigNumber.from('100000000') // 0.1 gwei

  const msg1 = await _decodeInboxMessage(inboxMsg)
  expect(msg1.to).to.be.eq(create2Deployer)
  expect(msg1.l2CallValue).to.be.eq(create2Value)

  let expectedAmountToBeMinted = BigNumber.from(create2Value)
    .add(maxFeePerGasForRetryables.mul(21000))
    .add(_submissionCost(gasPrice))
  if (nativeToken && (await nativeToken.decimals()) < 18) {
    expectedAmountToBeMinted = await _scaleFromNativeTo18(
      await _scaleFrom18ToNative(expectedAmountToBeMinted)
    )
  }
  expect(msg1.amountToBeMintedOnChildChain).to.be.eq(expectedAmountToBeMinted)
  expect(msg1.maxSubmissionCost).to.be.eq(_submissionCost(gasPrice))
  expect(msg1.excessFeeRefundAddress).to.be.eq(applyAlias(rollupCreatorAddress))
  expect(msg1.callValueRefundAddress).to.be.eq(applyAlias(rollupCreatorAddress))
  expect(msg1.gasLimit).to.be.eq('21000')
  expect(msg1.maxFeePerGas).to.be.eq(maxFeePerGasForRetryables)
  expect(msg1.dataLength).to.be.eq('0')
}

async function _decodeInboxMessage(encodedMsg: string) {
  const abiCoder = new ethers.utils.AbiCoder()
  const types = [
    'uint256', // uint256(uint160(to))
    'uint256', // l2CallValue
    'uint256', // _fromNativeTo18Decimals(amount)
    'uint256', // maxSubmissionCost
    'uint256', // uint256(uint160(excessFeeRefundAddress))
    'uint256', // uint256(uint160(callValueRefundAddress))
    'uint256', // gasLimit
    'uint256', // maxFeePerGas
    'uint256', // data.length (assuming it's a uint256)
  ]

  const decoded = abiCoder.decode(types, encodedMsg)
  return {
    to: _uint256ToAddress(decoded[0]),
    l2CallValue: decoded[1],
    amountToBeMintedOnChildChain: decoded[2],
    maxSubmissionCost: decoded[3],
    excessFeeRefundAddress: _uint256ToAddress(decoded[4]),
    callValueRefundAddress: _uint256ToAddress(decoded[5]),
    gasLimit: decoded[6],
    maxFeePerGas: decoded[7],
    dataLength: decoded[8],
  }
}

function _uint256ToAddress(uint256: string) {
  return ethers.utils.getAddress(ethers.utils.hexStripZeros(uint256))
}

function _submissionCost(gasPrice: BigNumber) {
  if (nativeToken) {
    return BigNumber.from(0)
  } else {
    return BigNumber.from(1400).mul(gasPrice)
  }
}

async function _applyDecimalsToAmount(amount: string) {
  if (nativeToken) {
    return BigNumber.from(amount).mul(
      BigNumber.from(10).pow(await nativeToken.decimals())
    )
  } else {
    return ethers.utils.parseEther(amount.toString())
  }
}

async function waitOnL2Msg(tx: ethers.ContractTransaction) {
  const retryableReceipt = await tx.wait()
  const l1TxReceipt = new L1TransactionReceipt(retryableReceipt)
  const messages = await l1TxReceipt.getL1ToL2Messages(l2Provider)

  // 1 msg expected
  const messageResult = await messages[0].waitForStatus()
  const status = messageResult.status
  expect(status).to.be.eq(L1ToL2MessageStatus.REDEEMED)
}

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

async function _scaleFromNativeTo18(amount: BigNumber): Promise<BigNumber> {
  const decimals = BigNumber.from(await nativeToken!.decimals())
  if (decimals.lt(BigNumber.from(18))) {
    return amount.mul(BigNumber.from(10).pow(BigNumber.from(18).sub(decimals)))
  } else if (decimals.gt(BigNumber.from(18))) {
    return amount.div(BigNumber.from(10).pow(decimals.sub(BigNumber.from(18))))
  }

  return amount
}

async function _scaleFrom18ToNative(
  amount: ethers.BigNumber
): Promise<BigNumber> {
  const decimals = BigNumber.from(await nativeToken!.decimals())
  if (decimals.lt(BigNumber.from(18))) {
    const scalingFactor = BigNumber.from(10).pow(
      BigNumber.from(18).sub(decimals)
    )
    let prescaledAmount = amount.div(scalingFactor)
    // round up if needed
    if (prescaledAmount.mul(scalingFactor).lt(amount)) {
      prescaledAmount = prescaledAmount.add(BigNumber.from(1))
    }
    return prescaledAmount
  } else if (decimals.gt(BigNumber.from(18))) {
    return amount.mul(BigNumber.from(10).pow(decimals.sub(BigNumber.from(18))))
  }

  return amount
}

async function _getRollupCreatorFromLogs(
  provider: JsonRpcProvider
): Promise<string> {
  const filter: Filter = {
    topics: [
      ethers.utils.id(
        'RollupCreated(address,address,address,address,address,address,address,address,address,address,address,address)'
      ),
    ],
  }

  const logs = await provider.getLogs({
    ...filter,
    fromBlock: '0x1',
    toBlock: 'latest',
  })
  if (logs.length === 0) {
    throw new Error(`Couldn't find any RollupCreated event`)
  }

  return logs[0].address
}
