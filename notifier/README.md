# Heartbeat notifier

Sends you a message when your Heartbeat vault emits `Warning`, `Released` or `Configuration`
(cancel or reconfigure), and optionally on every `Heartbeat` (activity registered).

**Alert delivery is a convenience. Release safety does not depend on it.** The vault, the
Reactive contract and the owner's `cancel()` work whether or not this script is running.
If the notifier is down, nothing is released earlier or later; you just do not get the message.
Messages also lag the chain: a warning only exists once the Reactive network has delivered it to
the vault, and the notifier polls (default every 30 s).

Node 18 or newer. No npm install, no dependencies, one file: `notify.mjs`.

## Quick start

```sh
# 1. See what it would send. Sends nothing, writes nothing.
node notifier/notify.mjs --dry-run --once --vault 0xYourVault --from-block 55816257

# 2. Pick a channel (any subset) and run it for real.
export NTFY_URL=https://ntfy.sh/pick-a-long-random-topic
node notifier/notify.mjs --vault 0xYourVault
```

Without a saved cursor and without `--from-block`, it starts from "now" and will not replay history.

## Channels

Configured only through environment variables. Secrets are never printed; errors show an HTTP
status, not a URL.

| Channel | Variables | Notes |
|---|---|---|
| ntfy | `NTFY_URL` (for example `https://ntfy.sh/<topic>`), optional `NTFY_TOKEN` | Sends Title, Priority, Tags and a Click link to the transaction. Anyone who knows the topic name can read it, so use a long random one or a protected topic. |
| Telegram | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | Create a bot with @BotFather, send it a message, then read your chat id. |
| Webhook | `WEBHOOK_URL`, optional `WEBHOOK_FORMAT=discord\|slack\|json` | Discord and Slack incoming-webhook URLs are detected. Anything else receives JSON: `event`, `title`, `text`, `url`, `tx`, `block`, `timestamp`. |

If a channel fails, the cursor stays on that event and it is retried on the next poll. Channels that
already received it are not sent a duplicate.

## Options

| Flag | Environment | Meaning |
|---|---|---|
| `--vault <address>` | `HEARTBEAT_VAULT` | Required. |
| `--network base-sepolia` | `HEARTBEAT_NETWORK` | Preset for RPC, explorer and chain name (default, and only preset). |
| `--rpc <url[,url]>` | `HEARTBEAT_RPC` | One or more JSON-RPC endpoints, tried in order. Default: publicnode, then `https://sepolia.base.org`. |
| `--explorer <url>` | `HEARTBEAT_EXPLORER` | Base URL for the links in messages. |
| `--from-block <n>` | `HEARTBEAT_FROM_BLOCK` | First block to scan if there is no saved cursor. Use the vault's deployment block to replay everything. |
| `--to-block <n>` | | Stop at this block. For testing. |
| `--interval <s>` | `POLL_SECONDS` | Poll interval, default 30, minimum 5. |
| `--confirmations <n>` | `HEARTBEAT_CONFIRMATIONS` | Stay this many blocks behind the head, default 2. |
| `--chunk <n>` | `HEARTBEAT_CHUNK` | Blocks per `eth_getLogs`, default 50000. It shrinks automatically if the node refuses (`https://sepolia.base.org` allows 200). |
| `--once` | | Scan once and exit (for cron and schedulers). |
| `--dry-run` | | Print the messages instead of sending; reads and writes no cursor file. |
| `--notify-heartbeat` | `NOTIFY_HEARTBEAT=1` | Also notify on each registered activity. Off by default (it can be noisy). |
| `--pings-only` | | Warning text mentions pings only. Use for the v1 vault, which does not track token transfers. |
| `--state <file>` | | Cursor file. Default: `notifier/.state/<chain>-<vault>.json`. |
| `--reset` | | Ignore the saved cursor. |

The cursor file holds the next block to scan, which events were delivered to which channel, and the
vault policy as last seen (used to word the warning). Do not commit it; add `notifier/.state/` to
`.gitignore`.

## Running it

**Locally, in a terminal.** The command above. Stop with Ctrl+C. Close the laptop and it stops.

**As a scheduled job.** Use `--once` and let the scheduler repeat it. The cursor makes each run pick up
where the last one ended.

```cron
# every 2 minutes (Linux/macOS crontab)
*/2 * * * * NTFY_URL=https://ntfy.sh/<topic> /usr/bin/node /path/to/heartbeat/notifier/notify.mjs --once --vault 0xYourVault >> /var/log/heartbeat-notify.log 2>&1
```

On Windows use Task Scheduler with an action `node.exe` and arguments
`C:\path\notifier\notify.mjs --once --vault 0xYourVault`, repeating every 2 minutes, with the channel
variables set as user environment variables.

**On a small always-on server.** Run it without `--once` under a supervisor, for example systemd:

```ini
# /etc/systemd/system/heartbeat-notify.service
[Unit]
Description=Heartbeat notifier
After=network-online.target

[Service]
Environment=NTFY_URL=https://ntfy.sh/<topic>
ExecStart=/usr/bin/node /opt/heartbeat/notifier/notify.mjs --vault 0xYourVault
Restart=always
RestartSec=30
User=heartbeat

[Install]
WantedBy=multi-user.target
```

A free VPS, a Raspberry Pi or any always-on machine is enough: the load is a few small requests per poll.

## What it does and does not do

- It reads the vault's own events on its home chain (Base Sepolia for the current deployment). It does not
  read the Reactive network or the Pulse contracts, so it can tell you a heartbeat was registered but not
  that a ping was sent and has not arrived yet.
- Works with the v1 and v2 vaults (same events and getters).
- `Configuration` events are worded as cancelled (inactive), configured (first policy) or changed. A repeat
  publication of identical settings is ignored.
- It is not a monitoring system: if the RPC endpoints are down it logs the error and retries with backoff.

## Check it against the v1 vault

`dry-run-v1.txt` is the output of

```sh
node notifier/notify.mjs --dry-run --once --pings-only \
  --vault 0x7509221859d2984ed941f671b616c6a77d07c95b --from-block 55816257
```

It finds the real v1 Warning (callback transaction `0xae8326a1...9b8f`) and Released
(`0xae95a2c7...61b9`) events.
