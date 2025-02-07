import { BigNumber, Contract, ContractFactory, ethers, Signer } from 'ethers'
import {
  BOLDUpgradeAction__factory,
  Bridge__factory,
  EdgeChallengeManager__factory,
  OneStepProofEntry__factory,
  OneStepProver0__factory,
  OneStepProverHostIo__factory,
  OneStepProverMath__factory,
  OneStepProverMemory__factory,
  Outbox__factory,
  RollupAdminLogic__factory,
  RollupEventInbox__factory,
  RollupUserLogic__factory,
  SequencerInbox__factory,
  Inbox__factory,
  StateHashPreImageLookup__factory,
  IReader4844__factory,
  IOldRollup__factory,
  ERC20Bridge__factory,
  ERC20Outbox__factory,
  ERC20Inbox__factory,
} from '../build/types'
import { bytecode as Reader4844Bytecode } from '../out/yul/Reader4844.yul/Reader4844.json'
import { DeployedContracts, Config } from './boldUpgradeCommon'
import { AssertionStateStruct } from '../build/types/src/challengeV2/IAssertionChain'
import { verifyContract } from './deploymentUtils'

export const deployDependencies = async (
  signer: Signer,
  maxDataSize: number,
  isUsingFeeToken: boolean,
  isDelayBufferable: boolean,
  isUsing4844Reader: boolean,
  log: boolean = false,
  verify: boolean = true
): Promise<Omit<DeployedContracts, 'boldAction' | 'preImageHashLookup'>> => {
  const bridgeFac = isUsingFeeToken
    ? new ERC20Bridge__factory(signer)
    : new Bridge__factory(signer)
  const bridge = await bridgeFac.deploy()
  await bridge.deployed()
  if (log) {
    console.log(`Bridge implementation deployed at: ${bridge.address}`)
  }
  if (verify) {
    await bridge.deployTransaction.wait(5)
    await verifyContract(
      isUsingFeeToken ? 'ERC20Bridge' : 'Bridge',
      bridge.address,
      [],
      isUsingFeeToken ? 'src/bridge/ERC20Bridge.sol:ERC20Bridge' : 'src/bridge/Bridge.sol:Bridge'
    )
  }

  const contractFactory = new ContractFactory(
    IReader4844__factory.abi,
    Reader4844Bytecode,
    signer
  )

  let reader4844Addr = ethers.constants.AddressZero;
  if (isUsing4844Reader) {
    const reader4844 = await contractFactory.deploy()
    await reader4844.deployed()
    reader4844Addr = reader4844.address
    console.log(`Reader4844 deployed at ${reader4844Addr}`)
  }
  const seqInboxFac = new SequencerInbox__factory(signer)
  const seqInbox = await seqInboxFac.deploy(
    maxDataSize,
    reader4844Addr,
    isUsingFeeToken,
    isDelayBufferable
  )
  await seqInbox.deployed()
  if (log) {
    console.log(
      `Sequencer inbox implementation deployed at: ${seqInbox.address}`
    )
  }
  if (verify) {
    await seqInbox.deployTransaction.wait(5)
    await verifyContract('SequencerInbox', seqInbox.address, [
      maxDataSize,
      reader4844Addr,
      isUsingFeeToken,
      isDelayBufferable,
    ])
  }

  const reiFac = new RollupEventInbox__factory(signer)
  const rei = await reiFac.deploy()
  await rei.deployed()
  if (log) {
    console.log(`Rollup event inbox implementation deployed at: ${rei.address}`)
  }
  if (verify) {
    await rei.deployTransaction.wait(5)
    await verifyContract('RollupEventInbox', rei.address, [])
  }

  const outboxFac = isUsingFeeToken 
    ? new ERC20Outbox__factory(signer)
    : new Outbox__factory(signer)
  const outbox = await outboxFac.deploy()
  await outbox.deployed()
  if (log) {
    console.log(`Outbox implementation deployed at: ${outbox.address}`)
  }
  if (verify) {
    await outbox.deployTransaction.wait(5)
    await verifyContract(isUsingFeeToken ? 'ERC20Outbox' : 'Outbox', outbox.address, [])
  }

  const inboxFac = isUsingFeeToken
    ? new ERC20Inbox__factory(signer)
    : new Inbox__factory(signer)
  const inbox = await inboxFac.deploy(maxDataSize)
  await inbox.deployed()
  if (log) {
    console.log(`Inbox implementation deployed at: ${inbox.address}`)
  }
  if (verify) {
    await inbox.deployTransaction.wait(5)
    await verifyContract('Inbox', inbox.address, [maxDataSize])
  }

  const newRollupUserFac = new RollupUserLogic__factory(signer)
  const newRollupUser = await newRollupUserFac.deploy()
  await newRollupUser.deployed()
  if (log) {
    console.log(`New rollup user logic deployed at: ${newRollupUser.address}`)
  }
  if (verify) {
    await newRollupUser.deployTransaction.wait(5)
    await verifyContract('RollupUserLogic', newRollupUser.address, [])
  }

  const newRollupAdminFac = new RollupAdminLogic__factory(signer)
  const newRollupAdmin = await newRollupAdminFac.deploy()
  await newRollupAdmin.deployed()
  if (log) {
    console.log(`New rollup admin logic deployed at: ${newRollupAdmin.address}`)
  }
  if (verify) {
    await newRollupAdmin.deployTransaction.wait(5)
    await verifyContract('RollupAdminLogic', newRollupAdmin.address, [])
  }

  const challengeManagerFac = new EdgeChallengeManager__factory(signer)
  const challengeManager = await challengeManagerFac.deploy()
  await challengeManager.deployed()
  if (log) {
    console.log(`Challenge manager deployed at: ${challengeManager.address}`)
  }
  if (verify) {
    await challengeManager.deployTransaction.wait(5)
    await verifyContract('EdgeChallengeManager', challengeManager.address, [])
  }

  const prover0Fac = new OneStepProver0__factory(signer)
  const prover0 = await prover0Fac.deploy()
  await prover0.deployed()
  if (log) {
    console.log(`Prover0 deployed at: ${prover0.address}`)
  }
  if (verify) {
    await prover0.deployTransaction.wait(5)
    await verifyContract('OneStepProver0', prover0.address, [])
  }

  const proverMemFac = new OneStepProverMemory__factory(signer)
  const proverMem = await proverMemFac.deploy()
  await proverMem.deployed()
  if (log) {
    console.log(`Prover mem deployed at: ${proverMem.address}`)
  }
  if (verify) {
    await proverMem.deployTransaction.wait(5)
    await verifyContract('OneStepProverMemory', proverMem.address, [])
  }

  const proverMathFac = new OneStepProverMath__factory(signer)
  const proverMath = await proverMathFac.deploy()
  await proverMath.deployed()
  if (log) {
    console.log(`Prover math deployed at: ${proverMath.address}`)
  }
  if (verify) {
    await proverMath.deployTransaction.wait(5)
    await verifyContract('OneStepProverMath', proverMath.address, [])
  }

  const proverHostIoFac = new OneStepProverHostIo__factory(signer)
  const proverHostIo = await proverHostIoFac.deploy()
  await proverHostIo.deployed()
  if (log) {
    console.log(`Prover host io deployed at: ${proverHostIo.address}`)
  }
  if (verify) {
    await proverHostIo.deployTransaction.wait(5)
    await verifyContract('OneStepProverHostIo', proverHostIo.address, [])
  }

  const proofEntryFac = new OneStepProofEntry__factory(signer)
  const proofEntry = await proofEntryFac.deploy(
    prover0.address,
    proverMem.address,
    proverMath.address,
    proverHostIo.address
  )
  await proofEntry.deployed()
  if (log) {
    console.log(`Proof entry deployed at: ${proofEntry.address}`)
  }
  if (verify) {
    await proofEntry.deployTransaction.wait(5)
    await verifyContract('OneStepProofEntry', proofEntry.address, [
      prover0.address,
      proverMem.address,
      proverMath.address,
      proverHostIo.address,
    ])
  }

  return {
    bridge: bridge.address,
    seqInbox: seqInbox.address,
    rei: rei.address,
    outbox: outbox.address,
    inbox: inbox.address,
    newRollupUser: newRollupUser.address,
    newRollupAdmin: newRollupAdmin.address,
    challengeManager: challengeManager.address,
    prover0: prover0.address,
    proverMem: proverMem.address,
    proverMath: proverMath.address,
    proverHostIo: proverHostIo.address,
    osp: proofEntry.address,
  }
}

export const deployBoldUpgrade = async (
  wallet: Signer,
  config: Config,
  log: boolean = false,
  verify: boolean = true
): Promise<DeployedContracts> => {
  const sequencerInbox = SequencerInbox__factory.connect(
    config.contracts.sequencerInbox,
    wallet
  )
  const isUsingFeeToken = await sequencerInbox.isUsingFeeToken()
  const has4844Reader = await sequencerInbox.reader4844() != ethers.constants.AddressZero
  const deployed = await deployDependencies(
    wallet,
    config.settings.maxDataSize,
    isUsingFeeToken,
    config.settings.isDelayBufferable,
    has4844Reader,
    log,
    verify
  )
  const fac = new BOLDUpgradeAction__factory(wallet)
  const boldUpgradeAction = await fac.deploy(
    { ...config.contracts, osp: deployed.osp },
    config.proxyAdmins,
    deployed,
    config.settings
  )
  if (log) {
    console.log(`BOLD upgrade action deployed at: ${boldUpgradeAction.address}`)
  }
  if (verify) {
    await boldUpgradeAction.deployTransaction.wait(5)
    await verifyContract('BOLDUpgradeAction', boldUpgradeAction.address, [
      { ...config.contracts, osp: deployed.osp },
      config.proxyAdmins,
      deployed,
      config.settings,
    ])
  }
  const deployedAndBold = {
    ...deployed,
    boldAction: boldUpgradeAction.address,
    preImageHashLookup: await boldUpgradeAction.PREIMAGE_LOOKUP(),
  }

  return deployedAndBold
}

export const populateLookup = async (
  wallet: Signer,
  rollupAddr: string,
  preImageHashLookupAddr: string
) => {
  const oldRollup = IOldRollup__factory.connect(rollupAddr, wallet)

  const latestConfirmed = await oldRollup.latestConfirmed()
  let latestConfirmedLog
  let toBlock = await wallet.provider!.getBlockNumber()
  for (let i = 0; i < 100; i++) {
    latestConfirmedLog = await wallet.provider!.getLogs({
      address: rollupAddr,
      fromBlock: toBlock >= 1000 ? toBlock - 1000 : 0,
      toBlock: toBlock,
      topics: [
        oldRollup.interface.getEventTopic('NodeCreated'),
        ethers.utils.hexZeroPad(ethers.utils.hexlify(latestConfirmed), 32),
      ],
    })
    if (latestConfirmedLog.length == 1) break
    if (toBlock == 0) {
      throw new Error('Could not find latest confirmed node')
    }
    toBlock -= 1000
    if (toBlock < 0) {
      toBlock = 0
    }
  }

  if (!latestConfirmedLog || latestConfirmedLog.length != 1) {
    throw new Error('Could not find latest confirmed node')
  }
  const latestConfirmedEvent = oldRollup.interface.parseLog(
    latestConfirmedLog[0]
  ).args
  const afterState: AssertionStateStruct =
    latestConfirmedEvent.assertion.afterState
  const inboxCount: BigNumber = latestConfirmedEvent.inboxMaxCount

  const lookup = StateHashPreImageLookup__factory.connect(
    preImageHashLookupAddr,
    wallet
  )

  const node = await oldRollup.getNode(latestConfirmed)
  const stateHash = await lookup.stateHash(afterState, inboxCount)
  if (node.stateHash != stateHash) {
    throw new Error(`State hash mismatch ${node.stateHash} != ${stateHash}}`)
  }

  await lookup.set(stateHash, afterState, inboxCount)
}
