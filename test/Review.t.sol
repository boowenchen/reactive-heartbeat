// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;
import {Test, Vm} from "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {Pulse} from "../src/Pulse.sol";
import {TestToken} from "../src/TestToken.sol";
import {HeartbeatReactive} from "../src/HeartbeatReactive.sol";
import {IReactive} from "@reactive/src/interfaces/IReactive.sol";
import {ISystemContract} from "@reactive/src/interfaces/ISystemContract.sol";

/// Records every requested callback payload so tests can count by action and deliver them.
contract RecordingSystem {
    bytes[] public payloads;
    uint256 public subscriptions;

    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscriptions++;
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {
        subscriptions--;
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory c) external {
        payloads.push(c.payload);
    }

    function count() external view returns (uint256) {
        return payloads.length;
    }

    function all() external view returns (bytes[] memory) {
        return payloads;
    }
}

/// Pre-deployment review counterexamples, kept as regression tests for the fixes.
contract ReviewTest is Test {
    address constant SYSTEM = 0x8888888888888888888888888888888888888888;
    address constant PROXY = address(0x100);
    address constant BENEFICIARY = address(0x200);
    address constant CRON = address(0x300);
    address constant STRANGER = address(0xBAD);
    uint256 constant DEST = 10; // destination (Base) chain id used in logs
    bytes4 constant HEARTBEAT = bytes4(keccak256("heartbeat(address,uint256,uint256)"));
    bytes4 constant WARN = bytes4(keccak256("warn(address,uint256,uint256)"));
    bytes4 constant RELEASE = bytes4(keccak256("release(address,uint256,uint256)"));

    TestToken token;
    Vault vault;
    HeartbeatReactive rc;
    RecordingSystem system;
    uint256 txid = 1;

    function deploy(uint256 w, uint256 r, uint256 g) internal {
        vm.warp(1000);
        vm.etch(SYSTEM, address(new RecordingSystem()).code);
        system = RecordingSystem(SYSTEM);
        token = new TestToken("Test", "T", 1000 ether, address(this));
        uint256[] memory chains = new uint256[](2);
        address[] memory sources = new address[](2);
        chains[0] = DEST;
        chains[1] = 11;
        sources[0] = address(new Pulse());
        sources[1] = address(new Pulse());
        // The owner's everyday token on the destination chain is allowlisted as activity.
        uint256[] memory tokenChains = new uint256[](1);
        address[] memory tokens = new address[](1);
        tokenChains[0] = DEST;
        tokens[0] = address(token);
        rc = new HeartbeatReactive(address(this), chains, sources, tokenChains, tokens, DEST, CRON, 123, 500000);
        vault = new Vault(PROXY, address(rc), address(this), token, BENEFICIARY, w, r, g);
        token.transfer(address(vault), 100 ether);
        rc.setVault(address(vault));
        vm.recordLogs();
        vault.publishConfiguration();
        feedRecorded();
    }

    // ---- helpers -------------------------------------------------------------------------

    /// Feeds every log emitted since the last vm.recordLogs() to the reactive contract,
    /// as the network would deliver it from the destination chain.
    function feedRecorded() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            IReactive.LogRecord memory l;
            l.chainId = DEST;
            l.contractAddress = logs[i].emitter;
            l.topic0 = uint256(logs[i].topics[0]);
            if (logs[i].topics.length > 1) l.topic1 = uint256(logs[i].topics[1]);
            if (logs[i].topics.length > 2) l.topic2 = uint256(logs[i].topics[2]);
            l.data = logs[i].data;
            l.txHash = txid++;
            vm.prank(SYSTEM);
            rc.react(l);
        }
    }

    function tick() internal {
        IReactive.LogRecord memory l;
        l.chainId = block.chainid;
        l.contractAddress = CRON;
        l.topic0 = 123;
        vm.prank(SYSTEM);
        rc.react(l);
    }

    function split(bytes memory p) internal pure returns (bytes4 sel, uint256 e, uint256 v) {
        assembly {
            sel := mload(add(p, 32))
            e := mload(add(p, 68))
            v := mload(add(p, 100))
        }
    }

    function countSince(uint256 from, bytes4 want) internal view returns (uint256 n) {
        bytes[] memory p = system.all();
        for (uint256 i = from; i < p.length; i++) {
            (bytes4 sel,,) = split(p[i]);
            if (sel == want) n++;
        }
    }

    /// Delivers payload i through the proxy with the reactive id injected; returns success.
    function deliver(uint256 i) internal returns (bool ok) {
        (bytes4 sel, uint256 e, uint256 v) = split(system.payloads(i));
        vm.prank(PROXY);
        (ok,) = address(vault).call(abi.encodeWithSelector(sel, address(rc), e, v));
    }

    // ---- C-1: anyone could keep the vault alive forever ----------------------------------

    /// A zero-value transferFrom needs no allowance on this token (and on WETH9, OZ ERC20,
    /// FiatToken...) and emits Transfer(from = owner). It must not count as owner activity.
    function testC1_StrangerZeroValueTransferFromIsNotActivity() public {
        deploy(60, 120, 30);
        uint256 start = system.count();
        for (uint256 i; i < 100; i++) {
            vm.warp(block.timestamp + 50);
            vm.recordLogs();
            vm.prank(STRANGER);
            token.transferFrom(address(this), STRANGER, 0); // no approval exists
            feedRecorded();
            tick();
        }
        assertEq(rc.version(), 0);
        assertEq(countSince(start, HEARTBEAT), 0, "spam costs no destination callback");
        assertGe(countSince(start, WARN), 1);
        assertGe(countSince(start, RELEASE), 1);
    }

    /// Variant: a non-zero transferFrom by a stranger reverts without allowance, while a spender the
    /// owner approved can move tokens and does count (documented residual risk).
    function testC1_NonZeroTransferFromNeedsAllowanceAndApprovedSpenderCounts() public {
        deploy(60, 120, 30);
        vm.prank(STRANGER);
        vm.expectRevert();
        token.transferFrom(address(this), STRANGER, 1);
        token.approve(STRANGER, 1);
        vm.recordLogs();
        vm.prank(STRANGER);
        token.transferFrom(address(this), STRANGER, 1);
        feedRecorded();
        assertEq(rc.version(), 1);
    }

    /// Variant: heartbeat callbacks are throttled to one per quarter warning window for busy owners,
    /// but a heartbeat right after a warning request is always sent.
    function testC1_HeartbeatCallbacksThrottledExceptAfterWarning() public {
        deploy(60, 120, 30);
        uint256 start = system.count();
        for (uint256 i; i < 10; i++) {
            vm.warp(block.timestamp + 1);
            vm.recordLogs();
            token.transfer(STRANGER, 1);
            feedRecorded();
        }
        assertEq(rc.version(), 10);
        assertEq(countSince(start, HEARTBEAT), 1);
        vm.warp(block.timestamp + 60);
        tick();
        assertEq(countSince(start, WARN), 1);
        vm.recordLogs();
        token.transfer(STRANGER, 1);
        feedRecorded();
        assertEq(countSince(start, HEARTBEAT), 2);
    }

    // ---- M-1: grace is mirrored on the reactive side -------------------------------------

    /// With grace longer than releaseAfter - warnAfter, release is requested only once grace has
    /// elapsed since the warning request: no reverted release callbacks, no redundant warnings,
    /// and deadlines() no longer understates the release time.
    function testM1_LongGraceSendsNoRevertingReleases() public {
        deploy(60, 120, 3600);
        uint256 t0 = block.timestamp;
        (, uint256 promised) = vault.deadlines();
        assertEq(promised, t0 + 60 + 3600);
        uint256 reverted;
        uint256 firstPayload = system.count();
        bool done;
        for (uint256 t = t0 + 10; t <= t0 + 4000 && !done; t += 10) {
            vm.warp(t);
            uint256 from = system.count();
            tick();
            for (uint256 i = from; i < system.count(); i++) {
                (bytes4 sel,,) = split(system.payloads(i));
                bool ok = deliver(i);
                if (sel == RELEASE && !ok) reverted++;
                if (sel == RELEASE && ok) done = true;
            }
        }
        assertTrue(vault.released());
        assertEq(reverted, 0);
        assertEq(countSince(firstPayload, WARN), 2, "one warning plus one resent with the release");
        assertGe(block.timestamp, promised);
    }

    /// Variant: if the first warning is lost, the resend with the release recovers; release then
    /// succeeds one grace later and nothing is released early.
    function testM1_LostWarningRecoversWithoutEarlyRelease() public {
        deploy(60, 120, 30);
        uint256 t0 = 1000; // deploy() warps here; avoid re-reading block.timestamp after warps
        vm.warp(t0 + 60);
        tick(); // warning requested, never delivered
        assertEq(vault.warnedAt(), 0);
        uint256 from = system.count();
        vm.warp(t0 + 130);
        tick();
        for (uint256 i = from; i < system.count(); i++) deliver(i);
        assertFalse(vault.released(), "grace runs from the delivered warning");
        assertEq(vault.warnedAt(), t0 + 130);
        from = system.count();
        vm.warp(t0 + 170);
        tick();
        for (uint256 i = from; i < system.count(); i++) deliver(i);
        assertTrue(vault.released());
    }

    /// Residual (fix review): when the first warning is lost and grace is long, the warning is only
    /// resent together with the first release attempt, so grace restarts there and every tick for a
    /// whole grace period sends warn + a release that reverts "early".
    function testResidual_LostWarningWithLongGraceRespamsForAWholeGrace() public {
        deploy(60, 120, 3600);
        uint256 t0 = 1000;
        vm.warp(t0 + 60);
        tick(); // warning requested, never delivered
        uint256 reverted;
        bool done;
        for (uint256 t = t0 + 70; t <= t0 + 9000 && !done; t += 10) {
            vm.warp(t);
            uint256 from = system.count();
            tick();
            for (uint256 i = from; i < system.count(); i++) {
                (bytes4 sel,,) = split(system.payloads(i));
                bool ok = deliver(i);
                if (sel == RELEASE && !ok) reverted++;
                if (sel == RELEASE && ok) done = true;
            }
        }
        assertTrue(vault.released());
        assertGt(reverted, 350, "~360 reverted release callbacks");
        assertGt(block.timestamp, t0 + 60 + 2 * 3600, "release ~2 x grace after warnAt");
    }

    // ---- L-1: a lost Released ack can be resynced -----------------------------------------

    /// If the Released log never reaches the reactive, anyone can call publishConfiguration(); the
    /// same-epoch active = false switches the reactive off and stops cron billing.
    function testL1_PublishConfigurationResyncsLostReleasedAck() public {
        deploy(60, 120, 30);
        vm.warp(block.timestamp + 60);
        tick();
        assertTrue(deliver(system.count() - 1)); // warn
        vm.warp(block.timestamp + 100);
        tick();
        assertTrue(deliver(system.count() - 1)); // release succeeds, Released log dropped
        assertTrue(vault.released());
        vm.recordLogs();
        vm.prank(STRANGER);
        vault.publishConfiguration();
        feedRecorded();
        assertFalse(rc.active());
        assertFalse(rc.cronEnabled());
        uint256 before = system.count();
        for (uint256 i; i < 10; i++) {
            vm.warp(block.timestamp + 10);
            tick();
        }
        assertEq(system.count(), before);
    }

    /// Variant: a delivered Released ack also unsubscribes every activity source, and later
    /// activity is ignored.
    function testL1_ReleasedAckUnsubscribesEverything() public {
        deploy(60, 120, 30);
        uint256 subs = system.subscriptions();
        IReactive.LogRecord memory r;
        r.chainId = DEST;
        r.contractAddress = address(vault);
        r.topic0 = rc.RELEASED();
        r.topic1 = vault.epoch();
        vm.prank(SYSTEM);
        rc.react(r);
        assertTrue(rc.released());
        assertEq(system.subscriptions(), subs - 4, "cron + two pulses + one token");
        vm.recordLogs();
        token.transfer(STRANGER, 1);
        feedRecorded();
        assertEq(rc.version(), 0);
    }

    // ---- L-2: status()/deadlines() estimates ----------------------------------------------

    /// When a heartbeat is not delivered, the destination keeps the old resetAt. The estimate no
    /// longer shows a release in the past: release needs a delivered warning plus grace.
    function testL2_UndeliveredHeartbeatDoesNotShowOverdueRelease() public {
        deploy(60, 120, 30);
        vm.warp(block.timestamp + 100);
        IReactive.LogRecord memory l;
        l.chainId = DEST;
        l.contractAddress = rc.pulses(DEST);
        l.topic0 = rc.PING();
        l.topic1 = uint256(uint160(address(this)));
        l.txHash = 999;
        vm.prank(SYSTEM);
        rc.react(l); // owner pinged; heartbeat callback requested but not delivered
        vm.warp(block.timestamp + 50);
        (,,, uint256 lastHeartbeat,,, uint256 releaseAt,,) = vault.status();
        assertEq(lastHeartbeat, 1000);
        assertGe(releaseAt, block.timestamp + 30);
        tick();
        assertEq(countSince(0, RELEASE), 0, "reactive correctly does not release");
    }

    /// The destination trusts the reactive contract for timing; warn() itself has no time gate
    /// (documented), so warnAt is an estimate, not an enforcement point.
    function testL2_WarnHasNoDestinationTimeGate() public {
        deploy(60, 120, 30);
        (uint256 warnAt,) = vault.deadlines();
        uint256 e = vault.epoch();
        vm.prank(PROXY);
        vault.warn(address(rc), e, 0);
        assertEq(vault.warnedAt(), block.timestamp);
        assertLt(block.timestamp, warnAt);
    }

    // ---- confirmations (no finding) ---------------------------------------------------------

    /// Duplicated / out-of-order Configuration logs and stale Released logs resolve to the
    /// newest epoch; the warning dedup key (epoch, version) never suppresses a new epoch.
    function testOK_ConfigReorderDuplicateAndDedupKeyAcrossEpochs() public {
        deploy(60, 120, 30);
        vm.warp(block.timestamp + 60);
        tick();
        assertEq(countSince(0, WARN), 1);
        vm.recordLogs();
        vault.cancel(); // epoch 2, inactive
        vault.configure(BENEFICIARY, 60, 120, 30); // epoch 3, active
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Deliver epoch 3 first, then epoch 2, then epoch 3 again.
        uint256[3] memory order = [uint256(1), 0, 1];
        for (uint256 k; k < 3; k++) {
            IReactive.LogRecord memory l;
            l.chainId = DEST;
            l.contractAddress = address(vault);
            l.topic0 = rc.CONFIG();
            l.data = logs[order[k]].data;
            l.txHash = 5000 + k;
            vm.prank(SYSTEM);
            rc.react(l);
        }
        assertEq(rc.epoch(), vault.epoch());
        assertTrue(rc.active());
        assertTrue(rc.cronEnabled());
        // A Released for an old epoch is ignored.
        IReactive.LogRecord memory r;
        r.chainId = DEST;
        r.contractAddress = address(vault);
        r.topic0 = rc.RELEASED();
        r.topic1 = 1;
        vm.prank(SYSTEM);
        rc.react(r);
        assertTrue(rc.active());
        uint256 before = countSince(0, WARN);
        vm.warp(block.timestamp + 60);
        tick();
        assertEq(countSince(0, WARN), before + 1, "new epoch gets its own warning");
    }
}
