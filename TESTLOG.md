# Test log

Local EVM tests, not testnet acceptance. The local suite configures three origin chains (including Unichain Sepolia) to test multi-origin deduplication; the live testnet deployment used two (Base Sepolia and Ethereum Sepolia). Foundry 1.8.6; Solidity 0.8.30.
Run: `forge test -vv`. Stateful invariants: 128 runs x 64 calls; fuzz: 256 cases.

Mutation executed by `tools/mutation_check.py` in the build workspace:
- File: `src/Vault.sol`
- Original: `require(block.timestamp >= warnedAt + grace && block.timestamp >= resetAt + releaseAfter, "early");`
- Mutant: `/* MUTANT: time guard removed */`
- Command: `forge test --match-contract HeartbeatInvariantTest -vv`
- Result: nonzero exit; invariant failed. [Raw failure](test-results/mutation-failed.txt).
- Original bytes restored; SHA256 `bf3b7b25c9e157c1ccde6f31a391e87e9db1c0292ccee4ef42eee752f201a3c5`.
- Complete restored suite: exit 0. [Raw pass](test-results/restored-pass.txt).

The system caller is a local test double; these tests do not prove subscriptions,
signer delivery, gas billing, reorg handling or latency on the live network.

Standalone reproduction: `python tools/mutation_check.py`. This mutates source temporarily and restores exact original bytes in a finally block. Do not edit the target source concurrently.

Earlier harness failures were corrected: a one-shot prank/expected revert was consumed by a getter before the intended call. Final invariant handlers use fail_on_revert=true and record zero handler reverts. The deploy scripts needed via-IR for stack depth; both compile with the configured compiler.

## v2 (2026-11-08)

`forge test -vv`: **28 passed, 0 failed** across `Heartbeat.t.sol`, `Review.t.sol` and the invariant suite ([raw output](test-results/restored-pass.txt)).

- New unit tests: tracked-token transfers count, untracked / incoming / Transfer-shaped logs from other contracts are ignored, token allowlist validation, cancel unsubscribes cron and reconfigure resubscribes, `status()`/`deadlines()`, owner withdrawals only while inactive.
- `test/Review.t.sol` holds the counterexamples from a pre-deployment review, kept as regression tests for the fixes (zero-value `transferFrom` spoofing, grace mirrored on the reactive side, lost-warning recovery, resync after a lost Released acknowledgement, unsubscribe on release, estimates in `deadlines()`), plus one test documenting a residual (retries after a lost first warning with long grace).
- Mutation: removing the `value > 0` check on tracked-token transfers makes `testC1_StrangerZeroValueTransferFromIsNotActivity` fail ([raw](test-results/mutation-zero-value.txt)); the original source was restored and the full suite passes.

The live behaviour that local mocks cannot show (subscribe/unsubscribe inside `react()`, delivery, billing) was exercised on testnet; see the v2 table in the README.
