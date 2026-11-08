# Heartbeat status page

A static page (no build step, no backend). It reads the vault directly from public RPC nodes and
lets the owner act through an injected wallet (EIP-1193, for example MetaMask).

```sh
cd app
python -m http.server 8080      # then open http://localhost:8080
```

Any static host works (GitHub Pages, Netlify, an S3 bucket). Serve the contents of `app/` as the site root.
GitHub Pages serves only the repository root or `/docs`, so publish `app/` with a Pages workflow or copy it to
`docs/`.

External resources: ethers v6.13.4 from cdnjs (pinned, with an integrity hash). Everything else is local.

## Configure (`config.json`)

| Field | Meaning |
|---|---|
| `deployment` | Label shown under the title. |
| `vault.chain` / `address` / `deployBlock` | Vault and the key of its chain in `chains`. `deployBlock` is where event history starts. |
| `reactive.chain` / `address` / `deployBlock` | Reactive contract on Lasna. Optional; `deployBlock` may be `null` (then only the most recent ~180k blocks are searched). |
| `chains.<key>.chainId`, `name`, `rpc` | Used to read state and, for the wallet, to switch or add the network. |
| `chains.<key>.explorer` | Base URL for transaction and address links. |
| `chains.<key>.explorerApi` | Optional Blockscout-style API; used only if the RPC log query fails (it is rate-limited). |
| `chains.<key>.logRpc`, `logChunk` | RPC used for `eth_getLogs` and the largest block range it accepts. `https://sepolia.base.org` allows 200 blocks, publicnode 50000. |
| `chains.<key>.pulse.address` / `deployBlock` | Pulse contract on that chain (ping target). |
| `chains.<key>.trackedTokens[]` | `{ "address", "symbol", "deployBlock" }` tokens whose transfers from the owner count (v2). Use `[]` for v1. |
| `chains.lasna.maxLogRange` | Largest `eth_getLogs` range the Lasna RPC accepts (30000). |

## What the page does

- Shows Alive / Warning / Released / Cancelled, the last activity time, live countdowns, the beneficiary,
  vault balance, policy, activity sources and the recent event history.
- State is computed from the vault getters (`resetAt`, `warnedAt`, `warnAfter`, `releaseAfter`, `grace`,
  `active`, `released`), so it works with both the v1 and v2 vaults.
- Owner actions: Send ping (on either chain), Cancel, Reconfigure, and Recover tokens after a cancel.
  Cancel, Reconfigure and Recover are disabled unless the connected address is the vault owner.
- The Reactive network status line and its history are optional; if Lasna is unreachable the rest still works.
