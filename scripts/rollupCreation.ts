import { ethers } from 'hardhat'
import '@nomiclabs/hardhat-ethers'
import { run } from 'hardhat'
import { abi as rollupCreatorAbi } from '../build/contracts/src/rollup/RollupCreator.sol/RollupCreator.json'
import { config, maxDataSize } from './config'
import { BigNumber, Event, Signer } from 'ethers'
import {
  ERC20,
  ERC20__factory,
  IERC20__factory,
  RollupCreator,
} from '../build/types'
import { sleep } from './testSetup'
import { promises as fs } from 'fs'
import { _isRunningOnArbitrum, verifyContract } from './deploymentUtils'
import {
  AssertionStateStruct,
  ConfigStruct,
} from '../build/types/src/rollup/RollupCreator'
import { constants } from 'buffer'

// 1 gwei
const MAX_FER_PER_GAS = BigNumber.from('1000000000')

interface RollupCreatedEvent {
  event: string
  address: string
  args?: {
    rollupAddress: string
    nativeToken: string
    inboxAddress: string
    outbox: string
    rollupEventInbox: string
    challengeManager: string
    adminProxy: string
    sequencerInbox: string
    bridge: string
    upgradeExecutor: string
    validatorWalletCreator: string
  }
}

interface RollupCreationResult {
  bridge: string
  inbox: string
  'sequencer-inbox': string
  'deployed-at': number
  rollup: string
  'native-token': string
  'upgrade-executor': string
  'validator-wallet-creator': string
}

interface ChainInfo {
  'chain-name': string
  'parent-chain-id': number
  'parent-chain-is-arbitrum': boolean
  'chain-config': any
  rollup: RollupCreationResult
  'sequencer-url': string
  'secondary-forwarding-target': string
  'feed-url': string
  'secondary-feed-url': string
  'das-index-url': string
  'has-genesis-state': boolean
}

export async function createRollup(
  signer: Signer,
  isDevDeployment: boolean,
  rollupCreatorAddress: string,
  feeToken: string,
  feeTokenPricer: string,
  stakeToken: string
): Promise<{
  rollupCreationResult: RollupCreationResult
  chainInfo: ChainInfo
} | null> {
  if (!rollupCreatorAbi) {
    throw new Error(
      'You need to first run <deployment.ts> script to deploy and compile the contracts first'
    )
  }

  const rollupCreator = new ethers.Contract(
    rollupCreatorAddress,
    rollupCreatorAbi,
    signer
  ) as RollupCreator
  const validatorWalletCreator = await rollupCreator.validatorWalletCreator()

  try {
    //// funds for deploying L2 factories
    // 0.13 ETH is enough to deploy L2 factories via retryables. Excess is refunded
    let feeCost = ethers.utils.parseEther('0.13')
    if (feeToken != ethers.constants.AddressZero) {
      // in case fees are paid via fee token, then approve rollup cretor to spend required amount
      feeCost = await _getPrescaledAmount(
        ERC20__factory.connect(feeToken, signer),
        feeCost
      )
      await (
        await IERC20__factory.connect(feeToken, signer).approve(
          rollupCreator.address,
          feeCost
        )
      ).wait()
      feeCost = BigNumber.from(0)
    }

    // Call the createRollup function
    console.log('Calling createRollup to generate a new rollup ...')
    const deployParams = isDevDeployment
      ? await _getDevRollupConfig(
          feeToken,
          feeTokenPricer,
          validatorWalletCreator,
          stakeToken
        )
      : {
          config: config.rollupConfig,
          validators: config.validators,
          maxDataSize: ethers.BigNumber.from(maxDataSize),
          nativeToken: feeToken,
          deployFactoriesToL2: true,
          maxFeePerGasForRetryables: MAX_FER_PER_GAS,
          batchPosters: config.batchPosters,
          batchPosterManager: config.batchPosterManager,
          feeTokenPricer: feeTokenPricer,
        }

    const createRollupTx = await rollupCreator.createRollup(deployParams, {
      value: feeCost,
    })
    const createRollupReceipt = await createRollupTx.wait()

    const rollupCreatedEvent = createRollupReceipt.events?.find(
      (event: Event): event is Event =>
        event.event === 'RollupCreated' &&
        event.address.toLowerCase() === rollupCreatorAddress.toLowerCase()
    )

    // Checking for RollupCreated event for new rollup address
    if (rollupCreatedEvent) {
      const rollupAddress = rollupCreatedEvent.args?.rollupAddress
      const nativeToken = rollupCreatedEvent.args?.nativeToken
      const inboxAddress = rollupCreatedEvent.args?.inboxAddress
      const outbox = rollupCreatedEvent.args?.outbox
      const rollupEventInbox = rollupCreatedEvent.args?.rollupEventInbox
      const challengeManager = rollupCreatedEvent.args?.challengeManager
      const adminProxy = rollupCreatedEvent.args?.adminProxy
      const sequencerInbox = rollupCreatedEvent.args?.sequencerInbox
      const bridge = rollupCreatedEvent.args?.bridge
      const upgradeExecutor = rollupCreatedEvent.args?.upgradeExecutor
      const validatorWalletCreator =
        rollupCreatedEvent.args?.validatorWalletCreator

      console.log("Congratulations! 🎉🎉🎉 All DONE! Here's your addresses:")
      console.log('RollupProxy Contract created at address:', rollupAddress)

      if (!isDevDeployment) {
        console.log('Wait a minute before starting the contract verification')
        await sleep(1 * 60 * 1000)
        console.log(
          `Attempting to verify Rollup contract at address ${rollupAddress}...`
        )

        await verifyContract(
          'RollupProxy',
          rollupAddress,
          [],
          'src/rollup/RollupProxy.sol:RollupProxy'
        )
      }

      console.log('Inbox (proxy) Contract created at address:', inboxAddress)
      console.log('Outbox (proxy) Contract created at address:', outbox)
      console.log(
        'rollupEventInbox (proxy) Contract created at address:',
        rollupEventInbox
      )
      console.log(
        'challengeManager (proxy) Contract created at address:',
        challengeManager
      )
      console.log('AdminProxy Contract created at address:', adminProxy)
      console.log('SequencerInbox (proxy) created at address:', sequencerInbox)
      console.log('Bridge (proxy) Contract created at address:', bridge)
      console.log(
        'ValidatorWalletCreator Contract created at address:',
        validatorWalletCreator
      )

      const blockNumber = createRollupReceipt.blockNumber
      console.log('All deployed at block number:', blockNumber)

      const rollupCreationResult: RollupCreationResult = {
        bridge: bridge,
        inbox: inboxAddress,
        'sequencer-inbox': sequencerInbox,
        'deployed-at': blockNumber,
        rollup: rollupAddress,
        'native-token': nativeToken,
        'upgrade-executor': upgradeExecutor,
        'validator-wallet-creator': validatorWalletCreator,
      }

      const chainInfo: ChainInfo = {
        'chain-name': 'dev-chain',
        'parent-chain-id': +process.env.PARENT_CHAIN_ID!,
        'parent-chain-is-arbitrum': await _isRunningOnArbitrum(signer),
        'sequencer-url': '',
        'secondary-forwarding-target': '',
        'feed-url': '',
        'secondary-feed-url': '',
        'das-index-url': '',
        'has-genesis-state': false,
        'chain-config': JSON.parse(deployParams.config.chainConfig),
        rollup: rollupCreationResult,
      }

      return { rollupCreationResult, chainInfo }
    } else {
      console.error('RollupCreated event not found')
    }
  } catch (error) {
    console.error(
      'Deployment failed:',
      error instanceof Error ? error.message : error
    )
  }

  return null
}

async function _getDevRollupConfig(
  feeToken: string,
  feeTokenPricer: string,
  validatorWalletCreator: string,
  stakeToken: string
): Promise<RollupCreator.RollupDeploymentParamsStruct> {
  // set up owner address
  const ownerAddress =
    process.env.OWNER_ADDRESS !== undefined ? process.env.OWNER_ADDRESS : ''

  // set up max data size
  const _maxDataSize =
    process.env.MAX_DATA_SIZE !== undefined
      ? ethers.BigNumber.from(process.env.MAX_DATA_SIZE)
      : ethers.BigNumber.from(117964)

  // set up validators
  const authorizeValidators: number =
    parseInt(process.env.AUTHORIZE_VALIDATORS as string, 0) || 0
  const validators: string[] = []
  for (let i = 1; i <= authorizeValidators; i++) {
    validators.push(_createValidatorAddress(validatorWalletCreator, i))
  }

  // get chain config
  const childChainConfigPath =
    process.env.CHILD_CHAIN_CONFIG_PATH !== undefined
      ? process.env.CHILD_CHAIN_CONFIG_PATH
      : 'l2_chain_config.json'

  const chainConfig = await fs.readFile(childChainConfigPath, {
    encoding: 'utf8',
  })

  // get wasmModuleRoot
  const wasmModuleRoot =
    process.env.WASM_MODULE_ROOT !== undefined
      ? process.env.WASM_MODULE_ROOT
      : ''

  // set up batch posters
  const sequencerAddress =
    process.env.SEQUENCER_ADDRESS !== undefined
      ? process.env.SEQUENCER_ADDRESS
      : ''
  const batchPostersString =
    process.env.BATCH_POSTERS !== undefined ? process.env.BATCH_POSTERS : ''
  let batchPosters: string[] = []
  if (batchPostersString.length == 0) {
    batchPosters.push(sequencerAddress)
  } else {
    const batchPostesArr = batchPostersString.split(',')
    for (let i = 0; i < batchPostesArr.length; i++) {
      if (ethers.utils.isAddress(batchPostesArr[i])) {
        batchPosters.push(batchPostesArr[i])
      } else {
        throw new Error('Invalid address in batch posters array')
      }
    }
  }

  // set up batch poster manager
  const batchPosterManagerEnv =
    process.env.BATCH_POSTER_MANAGER !== undefined
      ? process.env.BATCH_POSTER_MANAGER
      : ''
  let batchPosterManager = ''
  if (ethers.utils.isAddress(batchPosterManagerEnv)) {
    batchPosterManager = batchPosterManagerEnv
  } else {
    if (batchPosterManagerEnv.length == 0) {
      batchPosterManager = ownerAddress
    } else {
      throw new Error('Invalid address for batch poster manager')
    }
  }

  const genesisAssertionState: AssertionStateStruct = {
    globalState: {
      bytes32Vals: [ethers.constants.HashZero, ethers.constants.HashZero],
      u64Vals: [ethers.BigNumber.from('0'), ethers.BigNumber.from('0')],
    },
    machineStatus: 0,
    endHistoryRoot: ethers.constants.HashZero,
  }

  const config: ConfigStruct = {
    confirmPeriodBlocks: ethers.BigNumber.from('20'),
    stakeToken: stakeToken,
    baseStake: ethers.utils.parseEther('1'),
    wasmModuleRoot: wasmModuleRoot,
    owner: ownerAddress,
    loserStakeEscrow: ownerAddress,
    chainId: JSON.parse(chainConfig)['chainId'],
    chainConfig: chainConfig,
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
    numBigStepLevel: 1,
    challengeGracePeriodBlocks: 10,
    bufferConfig: { threshold: 600, max: 14400, replenishRateInBasis: 500 },
    sequencerInboxMaxTimeVariation: {
      delayBlocks: ethers.BigNumber.from('5760'),
      futureBlocks: ethers.BigNumber.from('12'),
      delaySeconds: ethers.BigNumber.from('86400'),
      futureSeconds: ethers.BigNumber.from('3600'),
    },
    anyTrustFastConfirmer: ethers.constants.AddressZero,
  }

  return {
    config: config,
    validators: validators,
    maxDataSize: _maxDataSize,
    nativeToken: feeToken,
    deployFactoriesToL2: true,
    maxFeePerGasForRetryables: MAX_FER_PER_GAS,
    batchPosters: batchPosters,
    batchPosterManager: batchPosterManager,
    feeTokenPricer: feeTokenPricer,
  }

  function _createValidatorAddress(
    deployerAddress: string,
    nonce: number
  ): string {
    const nonceHex = BigNumber.from(nonce).toHexString()
    return ethers.utils.getContractAddress({
      from: deployerAddress,
      nonce: nonceHex,
    })
  }
}

async function _getPrescaledAmount(
  nativeToken: ERC20,
  amount: BigNumber
): Promise<BigNumber> {
  const decimals = BigNumber.from(await nativeToken.decimals())
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
