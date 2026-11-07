// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {Script} from "forge-std/Script.sol";
contract Send is Script {
    function run() external {
        uint256 expected = vm.envUint("EXPECTED_CHAIN_ID");
        require(block.chainid == expected && (expected == 84532 || expected == 11155111 || expected == 5318007), "testnet only");
        uint256 key = vm.envUint("PRIVATE_KEY");
        require(vm.addr(key) == vm.envAddress("OWNER"), "owner/key mismatch");
        address target = vm.envAddress("SEND_TARGET");
        bytes memory data = vm.envBytes("SEND_DATA");
        uint256 value = vm.envUint("SEND_VALUE");
        vm.startBroadcast(key);
        (bool ok,) = target.call{value:value}(data);
        require(ok, "call failed");
        vm.stopBroadcast();
    }
}
