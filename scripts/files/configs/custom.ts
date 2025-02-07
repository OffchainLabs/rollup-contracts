import { parseEther } from 'ethers/lib/utils'
import { Config } from '../../boldUpgradeCommon'
import { hoursToBlocks } from './utils'

export const custom: Config = {
  contracts: {
    bridge: '',
    inbox: '',
    outbox: '',
    rollup: '',
    sequencerInbox: '',
    excessStakeReceiver: '', // receives losers' stake
    rollupEventInbox: '',
    upgradeExecutor: '',
  },
  proxyAdmins: {
    outbox: '', // e.g. the address of the proxy admin for the outbox
    inbox: '',
    bridge: '',
    rei: '',
    seqInbox: '',
  },
  settings: {
    challengeGracePeriodBlocks: hoursToBlocks(48), // 2 days for the chain owner to intervene in case of challenge
    confirmPeriodBlocks: 45818, // ~6.4 days
    challengePeriodBlocks: 45818, // same as confirm period
    stakeToken: '', // rollup stake token
    stakeAmt: parseEther('3600'), // assertion stake amount
    miniStakeAmounts: [parseEther('0'), parseEther('555'), parseEther('79')], // subchallenge stake amounts (0 first level recommended)
    chainId: 42161, // child chain id
    minimumAssertionPeriod: 75, // minimum number of blocks between assertions
    validatorAfkBlocks: 201600, // number of blocks before validator whitelist is dropped due to inactivity
    disableValidatorWhitelist: true, // keep or disable validator whitelist
    blockLeafSize: 2 ** 26, // do not change unless you know what you're doing
    bigStepLeafSize: 2 ** 19, // do not change unless you know what you're doing
    smallStepLeafSize: 2 ** 23, // do not change unless you know what you're doing
    numBigStepLevel: 1, // do not change unless you know what you're doing
    maxDataSize: 117964, // do not change unless you know what you're doing
    isDelayBufferable: true, // whether to enable the delay buffer feature
    bufferConfig: {
      max: hoursToBlocks(48), // 2 days
      threshold: hoursToBlocks(0.5), // keep above typical posting frequency
      replenishRateInBasis: 500, // 5% replenishment rate
    },
  },
  // validators to be whitelisted on the new rollup
  validators: [],
}
