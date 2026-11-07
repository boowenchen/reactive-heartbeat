// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
/// Offline digest signer; Python validates the EIP-1559 chain before invoking.
contract Sign is Script {
    function run() external view {
        uint256 key = vm.envUint("PRIVATE_KEY");
        require(vm.addr(key) == vm.envAddress("OWNER"), "owner/key mismatch");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, vm.envBytes32("TX_DIGEST"));
        console2.log("SIGNATURE");
        console2.logBytes32(r);
        console2.logBytes32(s);
        console2.logUint(v);
    }
}
