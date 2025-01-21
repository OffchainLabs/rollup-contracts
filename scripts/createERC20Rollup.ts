import { ethers } from 'hardhat'
import '@nomiclabs/hardhat-ethers'
import { Signer } from 'ethers'
import { createRollup } from './rollupCreation'
import { TestToken__factory } from '../build/types'

async function deployERC20Token(deployer: Signer): Promise<string> {
  const factory = await new TestToken__factory(deployer).deploy(
    ethers.utils.parseEther('1000000000')
  )
  const feeToken = await factory.deployed()

  return feeToken.address
}

async function main() {
  const [deployer] = await ethers.getSigners()

  let customFeeTokenAddress = process.env.FEE_TOKEN_ADDRESS
  if (!customFeeTokenAddress) {
    console.log(
      'FEE_TOKEN_ADDRESS env var not provided, deploying new ERC20 token'
    )
    customFeeTokenAddress = await deployERC20Token(deployer)
  }
  if (!ethers.utils.isAddress(customFeeTokenAddress)) {
    throw new Error(
      'Fee token address ' + customFeeTokenAddress + ' is not a valid address!'
    )
  }

  const rollupCreatorAddress = process.env.ROLLUP_CREATOR_ADDRESS
  if (!rollupCreatorAddress) {
    throw new Error('ROLLUP_CREATOR_ADDRESS not set')
  }
  const stakeTokenAddress = process.env.STAKE_TOKEN_ADDRESS
  if (!stakeTokenAddress) {
    throw new Error('STAKE_TOKEN_ADDRESS not set')
  }

  let feeTokenPricer = process.env.FEE_TOKEN_PRICER_ADDRESS
  if (!feeTokenPricer) {
    feeTokenPricer = ethers.constants.AddressZero
  }

  console.log(
    'Creating new rollup with',
    customFeeTokenAddress,
    'as fee token and',
    feeTokenPricer,
    'as fee token pricer'
  )
  await createRollup(
    deployer,
    false,
    rollupCreatorAddress,
    customFeeTokenAddress,
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
