// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// Explicit activity opt-in; arbitrary token transfers cannot prove wallet liveness.
contract Pulse {
    event Ping(address indexed owner, uint256 timestamp);

    function ping() external {
        emit Ping(msg.sender, block.timestamp);
    }
}
