# Deployment runbook — not executed

All commands below are for a later funded testnet session. No account or wallet is
created by this project. Use a dedicated project wallet; export `PRIVATE_KEY` in the
process environment through your secret manager. Never paste it into command arguments,
logs, this README, or version control. `OWNER` must match that key.

## Setup and configuration

```powershell
python tools/bootstrap.py
./tools/test.ps1
$env:OWNER = '<project-wallet-address>'
# Set PRIVATE_KEY securely in this process, without echoing it.
$env:REACTIVE_FUND_WEI = '1000000000000000000' # 1 lREACT starting balance
$env:CALLBACK_FUND_WEI = '20000000000000000'  # 0.02 destination test ETH
```

The wrapper reads chain IDs/RPCs/proxies from `config/networks.json` and checks
the connected chain before starting a broadcast. RPC overrides are `BASE_RPC`,
`LASNA_RPC`, `UNICHAIN_RPC`, `SEPOLIA_RPC`. There are no mainnet configurations.
Without `-Broadcast`, the wrapper performs Foundry simulation only. The commands
below explicitly show `-Broadcast` to make the future transaction steps unambiguous.

After **every** stage, copy deployed addresses from Foundry's receipt into the named
environment variables and your local `config/deployed.json`; retain its transaction
hash, chain ID, block hash, constructor arguments and contract address. `broadcast/`
contains public deployment receipts but is ignored by default. For interrupted
broadcasts, inspect receipts/nonces first; use Foundry `--resume` for a known pending
broadcast. Do not blindly start a second creation. Once receipts are reconciled,
setting each existing address lets its stage skip creation. Partial stages require
setting *all* addresses already created. Address checks are consistency checks, not
bytecode attestation: verify bytecode/constructor parameters before reusing an address.

## Gas and fee funding

These are starting allocations, not measured quotes. Read gas prices and estimate
each deployment before sending. Keep both reactive contract and callback recipient
funded. A positive debt stops new delivery even if the balance appears adequate.

Read-only checks (PowerShell; use `cast` from the same Foundry bin directory):

```powershell
cast chain-id --rpc-url $env:LASNA_RPC
cast gas-price --rpc-url $env:LASNA_RPC
cast call $env:SYSTEM '_gasPriceCoeffPer1000()(uint256)' --rpc-url $env:LASNA_RPC
cast call $env:SYSTEM '_extraGas()(uint256)' --rpc-url $env:LASNA_RPC
cast call $env:SYSTEM 'debt(address)(uint256)' $env:REACTIVE --rpc-url $env:LASNA_RPC
cast call $env:PROXY 'debt(address)(uint256)' $env:RECIPIENT --rpc-url $env:BASE_RPC
```

Set `SYSTEM` to `lasna.callbackProxy`, `PROXY` to `base.callbackProxy`, and RPC env
variables from the checked-in config. `RECIPIENT` means VAULT or EXECUTOR below.
The fee model and live coefficient reads are documented in [SOURCES.md](SOURCES.md).
The source-native balance funds payer callbacks; token principal stays separate.
For later fee top-ups, `depositTo(address)` on the appropriate system/proxy credits
reserves and clears debt. Record each top-up hash. Do not send fee ETH to the token.

If test lREACT is needed, the official faucet exchanges test ETH at 1:100;
0.02–0.1 test ETH yields 2–10 lREACT. See the official faucet instructions linked
from SOURCES; funding is not performed here. Cron costs accumulate while subscribed.

## Evidence acceptance

Record deployment, linking, seed/funding, source stimulus, Reactive decision, callback,
and any pause/unsubscribe transaction hashes. Fill three complete rows in README and
`config/evidence.json` with real explorer links. Verify receipt success and emitted
application events, not merely a successful outer proxy transaction: callbacks can
fail internally while the outer transaction succeeds. Read balances/state afterwards.
No unfilled row is evidence, and local mock tests do not count as a live loop.

## Heartbeat stages

Suggested wallet allocations: Base Sepolia **0.05 ETH** (deployment, 0.02 callback
balance, pings); Unichain Sepolia **0.01 ETH**; Ethereum Sepolia **0.03 ETH**;
Lasna **2–5 lREACT** (deployment, 1 lREACT initial payer balance and cron margin).
These exclude the optional faucet conversion. Test principal is a locally deployed
fixed-supply token, not ETH and not a bridged asset.

1. Deploy Pulse on Base Sepolia and Ethereum Sepolia only. After each command, record the Pulse address;
   set `PULSE` only when rerunning that same network, and unset it before switching.

```powershell
./tools/deploy.ps1 -Step pulse -Network base -Broadcast
$env:BASE_PULSE = '<address from Base receipt>'
./tools/deploy.ps1 -Step pulse -Network sepolia -Broadcast
$env:SEPOLIA_PULSE = '<address from Sepolia receipt>'
```

2. Deploy Reactive first; it initially has no vault and cannot release anything.

```powershell
./tools/deploy.ps1 -Step reactive -Network lasna -Broadcast
$env:REACTIVE = '<reactive contract address>'
$env:BENEFICIARY = '<separate project beneficiary address>'
$env:WARN_SECONDS = '120'
$env:RELEASE_SECONDS = '240'
$env:GRACE_SECONDS = '45'
./tools/deploy.ps1 -Step vault -Network base -Broadcast
$env:TOKEN = '<TestToken address>'
$env:VAULT = '<Vault address>'
./tools/deploy.ps1 -Step link -Network lasna -Broadcast
$env:PRINCIPAL_WEI = '100000000000000000000' # 100 demo tokens
./tools/deploy.ps1 -Step activate -Network base -Broadcast
```

3. Confirm `rc.epoch()` equals `vault.epoch()` and `rc.active()` is true before
   starting the demo. The activation event is replayable via
   `Vault.publishConfiguration()` if its initial event was missed. Repeated events
   for the same epoch do not reset the inactivity clock. All timing is seconds.

4. Send `ping()` from OWNER on each origin; record source tx, `Observed` reactive
   tx and `Heartbeat` callback tx. Use Foundry's environment key support:

```powershell
# cast reads ETH_PRIVATE_KEY; never include the key as a literal argument.
$env:ETH_PRIVATE_KEY = $env:PRIVATE_KEY
cast send $env:BASE_PULSE 'ping()' --rpc-url $env:BASE_RPC
cast send $env:SEPOLIA_PULSE 'ping()' --rpc-url $env:SEPOLIA_RPC
```

After silence: observe Warning, then Released after both the release threshold and
destination-side warning grace have elapsed. Cron10 is nominally ~10 seconds, not a
wall-clock guarantee. The callback may initially fail the destination grace check;
subsequent ticks retry. Preserve failure receipts alongside eventual success.

5. Cancellation/change demonstration (before release):

```powershell
cast send $env:VAULT 'cancel()' --rpc-url $env:BASE_RPC
cast send $env:VAULT 'recoverCancelled()' --rpc-url $env:BASE_RPC
# Or configure a fresh policy; this increments epoch and invalidates queued callbacks.
cast send $env:VAULT 'configure(address,uint256,uint256,uint256)' $env:BENEFICIARY 60 120 30 --rpc-url $env:BASE_RPC
```

Reactivation after cancellation requires principal funding if recovered. A released
vault is terminal: use a new vault/reactive pair for a new demo. On receipt of Released,
Reactive unsubscribes cron. After cancellation or when ending an unfinished demo, stop
cron explicitly (receipt hash required); cancel stops callbacks but not tick billing:

```powershell
cast send $env:REACTIVE 'setCronEnabled(bool)' false --rpc-url $env:LASNA_RPC
```

Use `true` when resuming an unreleased policy. A late remote ping that has not yet
reached Reactive cannot veto a transaction already executing on Base; local cancel
is the immediate control. Never describe this as a trustless proof of death.
