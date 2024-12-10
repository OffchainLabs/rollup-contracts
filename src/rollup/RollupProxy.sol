// Copyright 2021-2022, Offchain Labs, Inc.
// For license information, see https://github.com/OffchainLabs/nitro-contracts/blob/main/LICENSE
// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.9;

import "../libraries/AdminFallbackProxy.sol";
import "./IRollupAdmin.sol";
import "./Config.sol";

contract RollupProxy is AdminFallbackProxy {
    function initializeProxy(Config memory config, ContractDependencies memory connectedContracts)
        external
    {
        if (
            _getAdmin() == address(0) &&
            _getImplementation() == address(0) &&
            _getSecondaryImplementation() == address(0)
        ) {
            _initialize(
                address(connectedContracts.rollupAdminLogic),
                abi.encodeWithSelector(
                    IRollupAdmin.initialize.selector,
                    config,
                    connectedContracts
                ),
                address(connectedContracts.rollupUserLogic),
                abi.encodeWithSelector(IRollupUserAbs.initialize.selector, config.stakeToken),
                config.owner
            );
        } else {
            _fallback();
        }
    }
}
