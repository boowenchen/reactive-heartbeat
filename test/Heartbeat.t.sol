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
    address constant WETH = address(0x4200);

    function noTokens() internal pure returns (uint256[] memory c, address[] memory t) {
        c = new uint256[](0);
        t = new address[](0);
    }

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
        uint256[] memory tokenChains = new uint256[](1);
        address[] memory tokens = new address[](1);
        tokenChains[0] = 11;
        tokens[0] = WETH;
        rc = new HeartbeatReactive(address(this), chains, sources, tokenChains, tokens, 10, CRON, 123, 500000);
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
        (uint256[] memory tc, address[] memory tk) = noTokens();
        HeartbeatReactive two = new HeartbeatReactive(address(this), chains, sources, tc, tk, 84532, CRON, 123, 500000);
        assertEq(two.pulses(84532), sources[0]);
        assertEq(two.pulses(11155111), sources[1]);
        assertEq(two.pulses(1301), address(0));
        sources[1] = address(0);
        vm.expectRevert("source");
        new HeartbeatReactive(address(this), chains, sources, tc, tk, 84532, CRON, 123, 500000);
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

    function transferLog(uint256 chain, address tokenAddr, address from, address to, uint256 txid) internal {
        IReactive.LogRecord memory l;
        l.chainId = chain;
        l.contractAddress = tokenAddr;
        l.topic0 = rc.TRANSFER();
        l.topic1 = uint256(uint160(from));
        l.topic2 = uint256(uint160(to));
        l.data = abi.encode(uint256(1 ether));
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
        uint256 t0 = rc.latestActivity();
        vm.warp(t0 + 59);
        tick();
        assertEq(system.count(), count);
        vm.warp(t0 + 60);
        tick();
        assertEq(system.count(), count + 1);
        // The warning for this activity version is requested once, not on every tick.
        vm.warp(t0 + 90);
        tick();
        assertEq(system.count(), count + 1);
        vm.warp(t0 + 120);
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

    function testTrackedTokenTransferFromOwnerCountsAsActivity() public {
        uint256 count = system.count();
        vm.warp(block.timestamp + 10);
        transferLog(11, WETH, address(this), address(0xCAFE), 77);
        assertEq(rc.version(), 1);
        assertEq(rc.lastActivity(11), block.timestamp);
        assertEq(system.count(), count + 1);
        // Same log replayed is a no-op.
        transferLog(11, WETH, address(this), address(0xCAFE), 77);
        assertEq(rc.version(), 1);
    }

    function testUntrackedOrIncomingTransfersAreIgnored() public {
        // Untracked token contract, even naming the owner as sender.
        transferLog(11, address(0xBAD), address(this), address(0xCAFE), 1);
        // Tracked token on a chain where it is not tracked.
        transferLog(10, WETH, address(this), address(0xCAFE), 2);
        // Incoming transfer: anyone can send tokens to the owner.
        transferLog(11, WETH, address(0xCAFE), address(this), 3);
        // A Transfer-shaped log from the Pulse contract does not count as a ping.
        IReactive.LogRecord memory l;
        l.chainId = 10;
        l.contractAddress = rc.pulses(10);
        l.topic0 = rc.TRANSFER();
        l.topic1 = uint256(uint160(address(this)));
        vm.prank(SYSTEM);
        rc.react(l);
        assertEq(rc.version(), 0);
    }

    function testTokenConfigValidation() public {
        uint256[] memory chains = new uint256[](2);
        address[] memory sources = new address[](2);
        chains[0] = 1; chains[1] = 2;
        sources[0] = address(new Pulse()); sources[1] = address(new Pulse());
        uint256[] memory tc = new uint256[](2);
        address[] memory tk = new address[](2);
        tc[0] = 1; tc[1] = 1; tk[0] = WETH; tk[1] = WETH;
        vm.expectRevert("token");
        new HeartbeatReactive(address(this), chains, sources, tc, tk, 1, CRON, 123, 500000);
        uint256[] memory tc7 = new uint256[](7);
        address[] memory tk7 = new address[](7);
        vm.expectRevert("config");
        new HeartbeatReactive(address(this), chains, sources, tc7, tk7, 1, CRON, 123, 500000);
    }

    function testCancelStopsCronAndReconfigureRestartsIt() public {
        uint256 subs = system.subscriptions();
        vault.cancel();
        config();
        assertFalse(rc.active());
        assertFalse(rc.cronEnabled());
        assertEq(system.subscriptions(), subs - 1);
        vm.warp(block.timestamp + 10000);
        tick();
        assertEq(system.count(), 0);
        vault.configure(BENEFICIARY, 60, 120, 30);
        config();
        assertTrue(rc.active());
        assertTrue(rc.cronEnabled());
        assertEq(system.subscriptions(), subs);
        vm.warp(block.timestamp + 60);
        tick();
        assertEq(system.count(), 1);
    }

    function testStatusAndDeadlines() public {
        (bool a, bool r, uint256 e, uint256 last, uint256 warned, uint256 warnAt, uint256 releaseAt, address b, uint256 bal)
        = vault.status();
        assertTrue(a);
        assertFalse(r);
        assertEq(e, 1);
        assertEq(last, 1000);
        assertEq(warned, 0);
        assertEq(warnAt, 1060);
        assertEq(releaseAt, 1120);
        assertEq(b, BENEFICIARY);
        assertEq(bal, 100 ether);
        // A late warning pushes release to warning + grace.
        vm.warp(1100);
        warn();
        (warnAt, releaseAt) = vault.deadlines();
        assertEq(releaseAt, 1130);
        vault.cancel();
        (warnAt, releaseAt) = vault.deadlines();
        assertEq(warnAt + releaseAt, 0);
    }

    function testOwnerCanWithdrawUnusedFundsOnly() public {
        vm.deal(address(rc), 1 ether);
        vm.deal(address(vault), 1 ether);
        vm.expectRevert("active");
        rc.withdraw(payable(address(0xD00D)), 1);
        vm.expectRevert("active");
        vault.withdrawGasFunds(payable(address(0xD00D)), 1);
        vault.cancel();
        config();
        rc.withdraw(payable(address(0xD00D)), 0.4 ether);
        vault.withdrawGasFunds(payable(address(0xD00D)), 0.5 ether);
        assertEq(address(0xD00D).balance, 0.9 ether);
        assertEq(token.balanceOf(address(vault)), 100 ether);
        vm.prank(address(0xBAD));
        vm.expectRevert("owner");
        rc.withdraw(payable(address(0xBAD)), 1);
        vm.prank(address(0xBAD));
        vm.expectRevert("owner");
        vault.withdrawGasFunds(payable(address(0xBAD)), 1);
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
