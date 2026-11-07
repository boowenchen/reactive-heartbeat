// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vault} from "../src/Vault.sol";
import {Pulse} from "../src/Pulse.sol";
import {TestToken} from "../src/TestToken.sol";
import {HeartbeatReactive} from "../src/HeartbeatReactive.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

contract MockSystem {
    uint256 public count;
    bytes public payload;
    uint256 public subscriptions;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscriptions++;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscriptions--;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
        count++;
        payload = c.payload;
    }
}

contract HeartbeatTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address constant PROXY = address(0x100);
    address constant BENEFICIARY = address(0x200);
    address constant CRON = address(0x300);
    TestToken token;
    Vault vault;
    HeartbeatReactive rc;
    MockSystem system;

    function setUp() public {
        vm.warp(1000);
        MockSystem mock = new MockSystem();
        vm.etch(SYSTEM, address(mock).code);
        system = MockSystem(SYSTEM);
        uint256[] memory chains = new uint256[](3);
        address[] memory sources = new address[](3);
        for (uint256 i; i < 3; i++) {
            chains[i] = i + 10;
            sources[i] = address(new Pulse());
        }
        rc = new HeartbeatReactive(address(this), chains, sources, 10, CRON, 123, 500000);
        token = new TestToken("Test", "T", 100 ether, address(this));
        vault = new Vault(PROXY, address(rc), address(this), token, BENEFICIARY, 60, 120, 30);
        token.transfer(address(vault), 100 ether);
        rc.setVault(address(vault));
        config();
    }

    function config() internal {
        IReactive.LogRecord memory l;
        l.chainId = 10;
        l.contractAddress = address(vault);
        l.topic0 = rc.CONFIG();
        l.data = abi.encode(vault.epoch(), vault.warnAfter(), vault.releaseAfter(), vault.grace(), vault.active());
        vm.prank(SYSTEM);
        rc.react(l);
    }

    function testTwoOrigins() public {
        uint256[] memory chains = new uint256[](2);
        address[] memory sources = new address[](2);
        chains[0] = 84532; chains[1] = 11155111;
        sources[0] = address(new Pulse()); sources[1] = address(new Pulse());
        HeartbeatReactive two = new HeartbeatReactive(address(this), chains, sources, 84532, CRON, 123, 500000);
        assertEq(two.pulses(84532), sources[0]);
        assertEq(two.pulses(11155111), sources[1]);
        assertEq(two.pulses(1301), address(0));
        sources[1] = address(0);
        vm.expectRevert("source");
        new HeartbeatReactive(address(this), chains, sources, 84532, CRON, 123, 500000);
    }

    function tick() internal {
        IReactive.LogRecord memory l;
        l.chainId = block.chainid;
        l.contractAddress = CRON;
        l.topic0 = 123;
        vm.prank(SYSTEM);
        rc.react(l);
    }

    function pulse(uint256 chain, uint256 txid) internal {
        IReactive.LogRecord memory l;
        l.chainId = chain;
        l.contractAddress = rc.pulses(chain);
        l.topic0 = rc.PING();
        l.topic1 = uint256(uint160(address(this)));
        l.txHash = txid;
        vm.prank(SYSTEM);
        rc.react(l);
    }

    function warn() internal {
        uint256 e = vault.epoch();
        vm.prank(PROXY);
        vault.warn(address(rc), e, 0);
    }

    function release() internal {
        uint256 e = vault.epoch();
        vm.prank(PROXY);
        vault.release(address(rc), e, 0);
    }

    function testRejectsDirectCallbackAndWrongReactiveId() public {
        vm.expectRevert();
        vault.warn(address(rc), 1, 0);
        vm.prank(PROXY);
        vm.expectRevert();
        vault.warn(address(99), 1, 0);
        IReactive.LogRecord memory l;
        vm.expectRevert();
        rc.react(l);
    }

    function testTimestampThresholdsAcrossThreeChainsAndDedup() public {
        for (uint256 chain = 10; chain < 13; chain++) {
            vm.warp(block.timestamp + 50);
            pulse(chain, chain);
            assertEq(rc.lastActivity(chain), block.timestamp);
            tick();
        }
        assertEq(rc.version(), 3);
        pulse(12, 12);
        assertEq(rc.version(), 3);
        uint256 count = system.count();
        vm.warp(block.timestamp + 59);
        tick();
        assertEq(system.count(), count);
        vm.warp(block.timestamp + 1);
        tick();
        assertEq(system.count(), count + 1);
        vm.warp(block.timestamp + 60);
        tick();
        assertEq(system.count(), count + 3);
    }

    function testGraceReleaseAndIdempotency() public {
        vm.warp(1120);
        warn();
        vm.prank(PROXY);
        vm.expectRevert();
        vault.release(address(rc), 1, 0);
        vm.warp(1150);
        release();
        assertEq(token.balanceOf(BENEFICIARY), 100 ether);
        release();
        assertEq(token.balanceOf(BENEFICIARY), 100 ether);
    }

    function testCancelAndReconfigureInvalidateQueuedCallbacks() public {
        vm.warp(1200);
        warn();
        uint256 old = vault.epoch();
        vault.cancel();
        vm.prank(PROXY);
        vault.release(address(rc), old, 0);
        assertFalse(vault.released());
        vault.configure(address(44), 80, 160, 40);
        vm.prank(PROXY);
        vault.warn(address(rc), old, 0);
        assertEq(vault.warnedAt(), 0);
        config();
        assertEq(rc.epoch(), vault.epoch());
    }

    function testHeartbeatInvalidatesWarningAndStaleDelivery() public {
        vm.warp(1120);
        warn();
        vm.prank(PROXY);
        vault.heartbeat(address(rc), 1, 2);
        assertEq(vault.warnedAt(), 0);
        vm.prank(PROXY);
        vault.warn(address(rc), 1, 1);
        assertEq(vault.warnedAt(), 0);
        vm.prank(PROXY);
        vm.expectRevert();
        vault.release(address(rc), 1, 1);
    }

    function testWrongOriginIgnoredAndCronCanStop() public {
        IReactive.LogRecord memory l;
        l.chainId = 10;
        l.contractAddress = address(999);
        l.topic0 = rc.PING();
        l.topic1 = uint256(uint160(address(this)));
        vm.prank(SYSTEM);
        rc.react(l);
        assertEq(rc.version(), 0);
        rc.setCronEnabled(false);
        vm.warp(10000);
        tick();
        assertEq(system.count(), 0);
    }

    function testGasBillingCannotSpendTokenPrincipal() public {
        vm.deal(address(vault), 1 ether);
        vm.prank(PROXY);
        vault.pay(0.1 ether);
        assertEq(token.balanceOf(address(vault)), 100 ether);
    }

    function testReleaseAcknowledgementUnsubscribesCron() public {
        IReactive.LogRecord memory l;
        l.chainId = 10;
        l.contractAddress = address(vault);
        l.topic0 = rc.RELEASED();
        l.topic1 = 1;
        vm.prank(SYSTEM);
        rc.react(l);
        assertFalse(rc.active());
        assertFalse(rc.cronEnabled());
        vm.warp(10000);
        tick();
        assertEq(system.count(), 0);
    }

    function testFuzzUnauthorizedCannotRelease(address caller) public {
        vm.assume(caller != PROXY);
        vm.prank(caller);
        vm.expectRevert();
        vault.release(address(rc), 1, 0);
    }
}

contract EarlyReleaseHandler is Test {
    Vault public vault;
    TestToken public token;
    address constant PROXY = address(0x100);
    address constant RC = address(0x500);

    constructor() {
        token = new TestToken("Test", "T", 100 ether, address(this));
        vault = new Vault(PROXY, RC, address(this), token, address(0xBEEF), 10, 20, 10);
        token.transfer(address(vault), 100 ether);
    }

    function premature(uint8 delta) external {
        // Every sequence starts a new policy; no valid release is ever authorized.
        if (vault.released()) return;
        vault.configure(address(0xBEEF), 10, 20, 10);
        uint256 e = vault.epoch();
        vm.warp(block.timestamp + 20);
        vm.prank(PROXY);
        vault.warn(RC, e, 0);
        vm.warp(block.timestamp + uint256(delta) % 10);
        vm.prank(PROXY);
        try vault.release(RC, e, 0) {} catch {}
    }
}

contract HeartbeatInvariantTest is StdInvariant, Test {
    EarlyReleaseHandler handler;

    function setUp() public {
        vm.warp(1000);
        handler = new EarlyReleaseHandler();
        targetContract(address(handler));
    }

    function invariant_PrincipalCannotLeaveBeforeGrace() public {
        assertFalse(handler.vault().released());
        assertEq(handler.token().balanceOf(address(handler.vault())), 100 ether);
    }
}
