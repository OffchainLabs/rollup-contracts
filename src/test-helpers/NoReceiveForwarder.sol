// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice A call forward that doesnt implement the receive or fallback functions, so cant receive value
contract NoReceiveForwarder {
    function forward(address to, bytes calldata data) public payable {
        (bool success, ) = address(to).call{value: msg.value}(data);
        require(success, "call forward failed");
    }
}

/// @notice A call forward that does implement the receive or fallback functions, so cant receive value
contract ReceivingForwarder {
    function forward(address to, bytes calldata data) public payable {
        (bool success, ) = address(to).call{value: msg.value}(data);
        require(success, "call forward failed");
    }

    receive() external payable {}
}
