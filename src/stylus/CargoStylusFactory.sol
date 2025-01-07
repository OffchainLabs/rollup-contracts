// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

interface IArbWasm {
    function activateProgram(
        address program
    ) external payable returns (uint16 version, uint256 dataFee);
}

contract CargoStylusFactory {
    // Constants
    address constant ARB_WASM = 0x0000000000000000000000000000000000000071;

    // Events
    event ContractDeployed(address indexed deployedContract, address indexed deployer);
    event ContractActivated(address indexed activatedContract);
    event ContractInitialized(address indexed initializedContract);

    // Errors
    error ContractDeploymentError(bytes bytecode);
    error ContractInitializationError(address newContract);
    error RefundExcessValueError(uint256 excessValue);
    error ExecutionFailed(address target, bytes data);

    // Deploys, activate and inits a new contract
    function deployActivateInit(
        bytes calldata _bytecode,
        bytes calldata _constructorCalldata,
        uint256 _constructorValue
    ) public payable returns (address) {
        uint256 activationValue = msg.value - _constructorValue;

        // Deploy the contract
        address newContractAddress = deployContract(_bytecode);

        // Activate the contract
        uint256 activationFee = activateContract(newContractAddress, activationValue);

        // Initialize the contract
        initializeContract(newContractAddress, _constructorCalldata, _constructorValue);

        refundExcessValue(activationFee, _constructorValue);

        return newContractAddress;
    }

    // Function to deploy and init a new contract
    // NOTE: This function should only be invoked if
    // ArbWasm's codehashVersion(bytes32 codehash) method returns the
    // current stylusVersion(), verify this locally before invoking
    function deployInit(
        bytes calldata _bytecode,
        bytes calldata _constructorCalldata
    ) public payable returns (address) {
        // Deploy the contract
        address newContractAddress = deployContract(_bytecode);

        // Initialize the contract
        initializeContract(newContractAddress, _constructorCalldata, msg.value);

        return newContractAddress;
    }

    // Computes amount to refund and sends it to msg.sender
    function refundExcessValue(uint256 _activationFee, uint256 _constructorValue) internal {
        // Calculate value to forward to constructor
        uint256 excessValue = msg.value - _activationFee - _constructorValue;

        // Refund excess value
        (bool sent, ) = payable(msg.sender).call{value: excessValue}("");

        if (!sent) {
            revert RefundExcessValueError(excessValue);
        }
    }

    // Internal function to deploy a new contract
    function deployContract(bytes memory _bytecode) internal returns (address) {
        address newContractAddress;

        assembly {
            newContractAddress := create(0, add(_bytecode, 0x20), mload(_bytecode))
        }

        if (newContractAddress == address(0)) {
            revert ContractDeploymentError(_bytecode);
        }

        emit ContractDeployed(newContractAddress, msg.sender);

        return newContractAddress;
    }

    // Internal function to activate a Stylus contract
    function activateContract(
        address _contract,
        uint256 _activationValue
    ) internal returns (uint256) {
        (, uint256 dataFee) = IArbWasm(ARB_WASM).activateProgram{value: _activationValue}(
            _contract
        );

        emit ContractActivated(_contract);

        return dataFee;
    }

    // Internal function to initialize a Stylus contract by
    // invoking its constructor
    function initializeContract(
        address _contract,
        bytes calldata _constructorCalldata,
        uint256 _constructorValue
    ) internal {
        (bool success, ) = address(_contract).call{value: _constructorValue}(_constructorCalldata);

        if (!success) {
            revert ContractInitializationError(_contract);
        }

        emit ContractInitialized(_contract);
    }
}
