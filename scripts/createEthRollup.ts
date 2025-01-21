import { ethers } from 'hardhat'
import '@nomiclabs/hardhat-ethers'
import { createRollup } from './rollupCreation'

async function main() {
  const feeToken = ethers.constants.AddressZero
  const feeTokenPricer = ethers.constants.AddressZero
  const rollupCreatorAddress = process.env.ROLLUP_CREATOR_ADDRESS
  if (!rollupCreatorAddress) {
    throw new Error('ROLLUP_CREATOR_ADDRESS not set')
  }

  const stakeTokenAddress = process.env.STAKE_TOKEN_ADDRESS
  if (!stakeTokenAddress) {
    throw new Error('STAKE_TOKEN_ADDRESS not set')
  }

  const [signer] = await ethers.getSigners()

  await createRollup(
    signer,
    false,
    rollupCreatorAddress,
    feeToken,
    feeTokenPricer,
    stakeTokenAddress
  )
}

main()
  .then(() => process.exit(0))
  .catch((error: Error) => {
    console.error(error)
    process.exit(1)
  })
