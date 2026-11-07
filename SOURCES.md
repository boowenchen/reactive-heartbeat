# Official source verification

Checked 2026-11-08; addresses are configuration, not a claim of live deployment.

| Source | Decision |
|---|---|
| https://dev.reactive.network/ | Omni, no RVM or legacy Callback emission |
| https://dev.reactive.network/reactive-contracts | onlySystem, LogRecord, subscriptions; cron emitter remains legacy system address |
| https://dev.reactive.network/callback-contracts | Proxy plus injected reactive contract address authentication |
| https://dev.reactive.network/origins-and-destinations | Four testnet chain IDs and callback proxies in networks.json |
| https://dev.reactive.network/economy | Native fee reserves on both chains; debt blocks delivery; callback minimum gas 100,000 |
| https://dev.reactive.network/reactive-mainnet | Lasna RPC; test REACT funding |
| https://docs.base.org/get-started/connect-to-base | Base Sepolia public RPC |
| https://developers.uniswap.org/docs/unichain | Unichain Sepolia public RPC |
| https://github.com/eth-clients/sepolia/blob/main/README.md | Ethereum Sepolia public RPC |

Code was checked directly against reactive-lib-omni commit
`3ade0dcf1d27e67e5783ef807e73a1b9e0c0cce8`:
https://github.com/Reactive-Network/reactive-lib-omni/tree/3ade0dcf1d27e67e5783ef807e73a1b9e0c0cce8

The official demo repo at `6fd02ce56d110762b9cecbacbf4374aa5951d491`
(https://github.com/Reactive-Network/reactive-smart-contract-demos/tree/6fd02ce56d110762b9cecbacbf4374aa5951d491)
was reviewed: Basic and Cron still use legacy `vmOnly` / `emit Callback`.
We follow the current documentation and linked Omni library instead.
`LogRecord` has no timestamp; Heartbeat uses Reactive receipt time conservatively.
The library's system address is an upstream protocol constant, the only inherited
network address compiled into our contracts. Application addresses/IDs come from configuration.

Base 200 ms Flashblocks must not be interpreted as a guaranteed final block interval.
All deadlines use timestamps; benchmark wall-clock observation is separately labeled.

## Dependency licensing

Our src/test/script/tools/docs are MIT. Upstream dependencies retain their own terms.
At this pin, reactive-lib-omni Solidity files declare `UNLICENSED` and no root LICENSE
was found. We do not relicense or include lib/ in the open-source package. Bootstrap
downloads it from upstream for local builds; upstream licensing permission remains
a publication/distribution question for the main session. forge-std uses its upstream
MIT/Apache-2.0 terms. No upstream demo code is copied into our MIT sources.

## Read-only endpoint checks

See `config/rpc-verification.json`: Base, Unichain and Lasna returned the expected chain ID and nonempty proxy code. Ethereum Sepolia rpc.sepolia.org timed out in this environment; additional officially listed rpc.sepolia.online and rpc.bordel.wtf/sepolia probes also failed. Its documented chain ID/proxy/RPC are retained, but live reachability remains unverified. Use a working Sepolia RPC override before deployment. Nonempty code does not attest proxy implementation or end-to-end delivery.
