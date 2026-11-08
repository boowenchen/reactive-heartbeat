// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {Script} from "forge-std/Script.sol";
import {Pulse} from "../src/Pulse.sol";
import {Vault} from "../src/Vault.sol";
import {TestToken} from "../src/TestToken.sol";
import {HeartbeatReactive} from "../src/HeartbeatReactive.sol";

/// Select STEP; existing address env vars make creation stages restartable.
contract Deploy is Script {
    function run() external {
        string memory cfg = vm.readFile("config/networks.json");
        string memory step = vm.envString("STEP");
        uint256 base = vm.parseJsonUint(cfg, ".base.chainId");
        uint256 lasna = vm.parseJsonUint(cfg, ".lasna.chainId");
        uint256 expected = vm.envUint("EXPECTED_CHAIN_ID");
        require(block.chainid == expected, "wrong chain");
        require(
            expected == base || expected == lasna
                || expected == vm.parseJsonUint(cfg, ".sepolia.chainId"),
            "testnet only"
        );
        address owner = vm.envAddress("OWNER");
        uint256 key = vm.envUint("PRIVATE_KEY");
        require(vm.addr(key) == owner, "owner/key mismatch");
        vm.startBroadcast(key);
        if (eq(step, "pulse")) {
            require(expected != lasna, "origin chain");
            address old = vm.envOr("PULSE", address(0));
            if (old == address(0)) new Pulse();
            else require(old.code.length > 0, "missing pulse");
        } else if (eq(step, "reactive")) {
            require(expected == lasna, "Lasna");
            address old = vm.envOr("REACTIVE", address(0));
            if (old == address(0)) {
                uint256[] memory chains = new uint256[](2);
                address[] memory sources = new address[](2);
                chains[0] = base;
                chains[1] = vm.parseJsonUint(cfg, ".sepolia.chainId");
                sources[0] = vm.envAddress("BASE_PULSE");
                sources[1] = vm.envAddress("SEPOLIA_PULSE");
                // Allowlisted tokens whose Transfer(from = owner) counts as activity, as parallel lists.
                uint256[] memory tokenChains = vm.envOr("TOKEN_CHAINS", ",", new uint256[](0));
                address[] memory tokens = vm.envOr("TRACKED_TOKENS", ",", new address[](0));
                new HeartbeatReactive{value: vm.envUint("REACTIVE_FUND_WEI")}(
                    owner,
                    chains,
                    sources,
                    tokenChains,
                    tokens,
                    base,
                    vm.parseJsonAddress(cfg, ".cron.emitter"),
                    vm.envOr("CRON_TOPIC", vm.parseJsonUint(cfg, ".cron.topic")),
                    500000
                );
            } else {
                require(HeartbeatReactive(payable(old)).owner() == owner, "existing owner");
            }
        } else if (eq(step, "vault")) {
            require(expected == base, "Base");
            address t = vm.envOr("TOKEN", address(0));
            if (t == address(0)) t = address(new TestToken("Heartbeat Demo Asset", "HBA", 1000000 ether, owner));
            address old = vm.envOr("VAULT", address(0));
            if (old == address(0)) {
                new Vault{value: vm.envUint("CALLBACK_FUND_WEI")}(
                    vm.parseJsonAddress(cfg, ".base.callbackProxy"),
                    vm.envAddress("REACTIVE"),
                    owner,
                    TestToken(t),
                    vm.envAddress("BENEFICIARY"),
                    vm.envUint("WARN_SECONDS"),
                    vm.envUint("RELEASE_SECONDS"),
                    vm.envUint("GRACE_SECONDS")
                );
            } else {
                require(
                    Vault(payable(old)).owner() == owner && address(Vault(payable(old)).token()) == t, "existing vault"
                );
            }
        } else if (eq(step, "link")) {
            require(expected == lasna, "Lasna");
            HeartbeatReactive rc = HeartbeatReactive(payable(vm.envAddress("REACTIVE")));
            address v = vm.envAddress("VAULT");
            if (rc.vault() == address(0)) rc.setVault(v);
            else require(rc.vault() == v, "wrong vault");
        } else if (eq(step, "activate")) {
            require(expected == base, "Base");
            Vault v = Vault(payable(vm.envAddress("VAULT")));
            require(v.active() && !v.released(), "vault inactive/released");
            uint256 desired = vm.envUint("PRINCIPAL_WEI");
            uint256 present = v.token().balanceOf(address(v));
            if (present < desired) require(v.token().transfer(address(v), desired - present), "transfer");
            v.publishConfiguration();
        } else {
            revert("unknown STEP");
        }
        vm.stopBroadcast();
    }

    function eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
