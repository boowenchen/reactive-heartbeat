#!/usr/bin/env node
// Heartbeat alert notifier. Polls a Heartbeat Vault for events and pushes them to ntfy, Telegram and/or a webhook.
// Node >= 18, no npm dependencies. Alert delivery is a convenience: release safety does not depend on it.
//
//   node notify.mjs --vault 0x... --from-block 55816257 --dry-run --once
//   NTFY_URL=https://ntfy.sh/my-secret-topic node notify.mjs --vault 0x...
//
// Run with --help for all options.

import { readFileSync, writeFileSync, renameSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

/* ------------------------------------------------------------------ constants */

// keccak256 of the event signatures in src/Vault.sol
const TOPIC = {
  Configuration: "0x466bdd59b34fd98a52a029f3d691cfed4a6da6ab7d1d07ebd0bed6f07d65b258", // Configuration(uint256,uint256,uint256,uint256,bool)
  Warning: "0x193228fa77033256f8bd31b2de00719f82ed68de699c36850717c8d74d40562b", // Warning(uint256,uint256,uint256)
  Heartbeat: "0x32743332e234f6fd3a3a771ae6aa0d8646076870cc1690869f61b83b812553f9", // Heartbeat(uint256,uint256)
  Released: "0x3bfce8de0db7450cc169b94323c210e69a36c6a4a58c9f5d96bec4973adce392", // Released(uint256,address,uint256)
};
const NAME_BY_TOPIC = Object.fromEntries(Object.entries(TOPIC).map(([k, v]) => [v, k]));
// 4-byte selectors of the public getters (identical in the v1 and v2 vaults)
const SEL = {
  beneficiary: "0x38af3eed", warnAfter: "0x583e5516", releaseAfter: "0xbc1ece88", grace: "0x1eefddb1",
  resetAt: "0x014d28b5", token: "0xfc0c546a", symbol: "0x95d89b41", decimals: "0x313ce567",
};

const PRESETS = {
  "base-sepolia": {
    chainName: "Base Sepolia",
    rpc: "https://base-sepolia-rpc.publicnode.com,https://sepolia.base.org",
    explorer: "https://sepolia.basescan.org",
  },
};

/* ------------------------------------------------------------------ options */

const HELP = `Heartbeat notifier

Required:
  --vault <0x..>          Vault address                          (env HEARTBEAT_VAULT)

Chain:
  --network <name>        Preset: base-sepolia (default)         (env HEARTBEAT_NETWORK)
  --rpc <url[,url..]>     JSON-RPC endpoint(s), tried in order   (env HEARTBEAT_RPC)
  --explorer <url>        Block explorer base URL for links      (env HEARTBEAT_EXPLORER)
  --chunk <n>             Max blocks per eth_getLogs (default 50000, shrinks automatically if the node refuses)
  --confirmations <n>     Stay this many blocks behind head (default 2)

Range / loop:
  --from-block <n>        First block to scan. Without a saved cursor, the default is "from now on".
  --to-block <n>          Last block to scan (default: head). Mostly for testing.
  --interval <seconds>    Poll interval (default 30)             (env POLL_SECONDS)
  --once                  Scan once and exit
  --dry-run               Print what would be sent; send nothing, read/write no cursor file
  --state <file>          Cursor file (default notifier/.state/<chain>-<vault>.json)

What to notify:
  --notify-heartbeat      Also notify on each Heartbeat (activity) event; off by default  (env NOTIFY_HEARTBEAT=1)
  --pings-only            Warning text mentions pings only (use for the v1 vault, which has no token tracking)

Channels (any subset, configured by environment only; secrets are never printed):
  NTFY_URL                e.g. https://ntfy.sh/<your-topic>   (optional NTFY_TOKEN for protected topics)
  TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
  WEBHOOK_URL             Discord and Slack incoming webhooks are detected; anything else gets JSON
                          (override with WEBHOOK_FORMAT=discord|slack|json)
`;

function parseArgs(argv) {
  const o = { _: [] };
  const flags = new Set(["once", "dry-run", "notify-heartbeat", "pings-only", "help", "reset"]);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) { o._.push(a); continue; }
    let [k, v] = a.slice(2).split("=");
    if (flags.has(k)) { o[k] = true; continue; }
    if (v === undefined) v = argv[++i];
    if (v === undefined) die(`Missing value for --${k}`);
    o[k] = v;
  }
  return o;
}

function die(msg, code = 2) {
  console.error(`error: ${msg}`);
  process.exit(code);
}

/* ------------------------------------------------------------------ small utils */

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const isAddr = (s) => /^0x[0-9a-fA-F]{40}$/.test(s || "");
const toNum = (hex) => Number(BigInt(hex));
const word = (data, i) => "0x" + data.slice(2 + i * 64, 2 + (i + 1) * 64);
const addrFromWord = (w) => "0x" + w.slice(-40);

function plural(n, w) { return `${n} ${w}${n === 1 ? "" : "s"}`; }
function human(sec) {
  sec = Math.max(0, Math.round(Number(sec)));
  if (sec < 60) return plural(sec, "second");
  const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
  if (d) return h ? `${plural(d, "day")} ${plural(h, "hour")}` : plural(d, "day");
  if (h) return m ? `${plural(h, "hour")} ${plural(m, "minute")}` : plural(h, "hour");
  return s ? `${plural(m, "minute")} ${plural(s, "second")}` : plural(m, "minute");
}
function utc(ts) {
  return new Date(ts * 1000).toISOString().replace("T", " ").replace(/\.\d+Z$/, " UTC");
}
function fmtUnits(raw, decimals) {
  const neg = raw < 0n;
  let s = (neg ? -raw : raw).toString().padStart(decimals + 1, "0");
  const i = s.slice(0, s.length - decimals), f = s.slice(s.length - decimals).replace(/0+$/, "").slice(0, 4);
  return (neg ? "-" : "") + i.replace(/\B(?=(\d{3})+(?!\d))/g, ",") + (f ? "." + f : "");
}
function decodeString(hex) {
  // ABI-encoded `string`: offset, length, bytes
  try {
    const b = hex.slice(2);
    const len = parseInt(b.slice(64, 128), 16);
    return Buffer.from(b.slice(128, 128 + len * 2), "hex").toString("utf8");
  } catch { return null; }
}

/* ------------------------------------------------------------------ JSON-RPC with failover */

class RpcError extends Error {
  constructor(m, code) { super(m); this.code = code; }
}

function makeRpc(urls) {
  let pref = 0;
  let nextId = 1;
  let calls = 0;
  async function call(method, params) {
    let lastErr;
    for (let t = 0; t < urls.length; t++) {
      const idx = (pref + t) % urls.length;
      calls++;
      try {
        const res = await fetch(urls[idx], {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ jsonrpc: "2.0", id: nextId++, method, params }),
          signal: AbortSignal.timeout(25000),
        });
        if (res.status === 429 || res.status >= 500) throw new Error(`HTTP ${res.status}`);
        const j = await res.json();
        if (j.error) throw new RpcError(j.error.message || "rpc error", j.error.code); // not retried on another URL
        pref = idx;
        return j.result;
      } catch (e) {
        if (e instanceof RpcError) throw e;
        lastErr = e; // network/5xx/429: try the next endpoint
      }
    }
    throw new Error(`all RPC endpoints failed (${lastErr && lastErr.message})`);
  }
  return { call, get calls() { return calls; } };
}

/* ------------------------------------------------------------------ chain access */

function makeChain(rpc) {
  const tsCache = new Map();
  return {
    blockNumber: async () => toNum(await rpc.call("eth_blockNumber", [])),
    async timestamp(block) {
      if (!tsCache.has(block)) {
        const b = await rpc.call("eth_getBlockByNumber", ["0x" + block.toString(16), false]);
        tsCache.set(block, toNum(b.timestamp));
      }
      return tsCache.get(block);
    },
    /** eth_call at a block; falls back to latest if the node does not keep that old state. */
    async callAt(to, data, block) {
      if (block != null) {
        try { return await rpc.call("eth_call", [{ to, data }, "0x" + block.toString(16)]); } catch { /* pruned state */ }
      }
      return rpc.call("eth_call", [{ to, data }, "latest"]);
    },
    /** All vault logs in [from,to], in order; shrinks the chunk if the node says the range is too large. */
    async getLogs(address, from, to, ctl) {
      const out = [];
      let f = from;
      while (f <= to) {
        const t = Math.min(to, f + ctl.chunk - 1);
        try {
          const rows = await rpc.call("eth_getLogs", [{ address, fromBlock: "0x" + f.toString(16), toBlock: "0x" + t.toString(16), topics: [Object.values(TOPIC)] }]);
          out.push(...rows);
          f = t + 1;
        } catch (e) {
          if (!(e instanceof RpcError) || ctl.chunk <= 1) throw e;
          const m = /(\d{2,})/.exec(e.message.replace(/0x[0-9a-f]+/gi, ""));
          const hinted = m ? Number(m[1]) : 0;
          const next = hinted > 0 && hinted < ctl.chunk ? hinted : Math.floor(ctl.chunk / 2);
          if (next >= ctl.chunk) throw e;
          ctl.chunk = Math.max(1, next);
        }
      }
      return out;
    },
  };
}

/* ------------------------------------------------------------------ message building */

/** Turns a raw log into a notification, using (and updating a copy of) the tracked vault state. */
async function describe(log, st, ctx) {
  const name = NAME_BY_TOPIC[log.topics[0]];
  const block = toNum(log.blockNumber);
  const ts = await ctx.chain.timestamp(block);
  const link = `${ctx.explorer}/tx/${log.transactionHash}`;
  const next = { ...st };
  const vaultLine = `Vault ${ctx.vault} on ${ctx.chainName}.`;
  let ev;

  const ensurePolicy = async () => {
    if (next.warnAfter != null && next.releaseAfter != null && next.grace != null && next.resetAt != null) return;
    // No Configuration/Heartbeat event seen yet (we started mid-life): read the vault.
    const rd = async (sel) => BigInt(await ctx.chain.callAt(ctx.vault, sel, block));
    next.warnAfter = Number(await rd(SEL.warnAfter));
    next.releaseAfter = Number(await rd(SEL.releaseAfter));
    next.grace = Number(await rd(SEL.grace));
    next.resetAt = Number(await rd(SEL.resetAt));
  };

  switch (name) {
    case "Configuration": {
      const epoch = toNum(word(log.data, 0)), w = toNum(word(log.data, 1)), r = toNum(word(log.data, 2)), g = toNum(word(log.data, 3));
      const active = BigInt(word(log.data, 4)) !== 0n;
      const key = `${epoch}/${w}/${r}/${g}/${active}`;
      const policy = `warn after ${human(w)}, release after ${human(r)}, grace ${human(g)}`;
      Object.assign(next, { warnAfter: w, releaseAfter: r, grace: g, resetAt: ts, warnedAt: 0 });
      const duplicate = st.lastCfgKey === key;
      next.lastCfgKey = key;
      if (duplicate) {
        ev = { kind: "Configuration", skip: "same settings published again" };
      } else if (!active) {
        ev = {
          kind: "Cancelled", title: "Heartbeat cancelled", priority: 3, tags: "no_entry_sign",
          text: `Heartbeat cancelled: the owner turned the release off. Nothing will be sent to the beneficiary until the vault is reconfigured. ${vaultLine}`,
        };
      } else if (epoch === 1) {
        ev = {
          kind: "Configured", title: "Heartbeat vault configured", priority: 3, tags: "heartbeat",
          text: `Heartbeat vault configured: ${policy}. ${vaultLine}`,
        };
      } else {
        ev = {
          kind: "Reconfigured", title: "Heartbeat settings changed", priority: 3, tags: "gear",
          text: `Heartbeat settings changed (version ${epoch}): ${policy}. The countdown restarted from the change. ${vaultLine}`,
        };
      }
      break;
    }
    case "Heartbeat": {
      const version = toNum(log.topics[2]);
      next.resetAt = ts; next.warnedAt = 0;
      ev = {
        kind: "Heartbeat", title: "Heartbeat: activity registered", priority: 1, tags: "green_heart", optional: true,
        text: `Heartbeat: owner activity registered (signal #${version}). The countdown restarted. ${vaultLine}`,
      };
      break;
    }
    case "Warning": {
      await ensurePolicy();
      const warnedAt = toNum(log.data.slice(0, 66)) || ts;
      next.warnedAt = warnedAt;
      let beneficiary = ctx.beneficiary;
      try { beneficiary = addrFromWord(await ctx.chain.callAt(ctx.vault, SEL.beneficiary, block)); } catch { /* keep previous */ }
      const releaseAt = Math.max(next.resetAt + next.releaseAfter, warnedAt + next.grace);
      const stay = ctx.pingsOnly ? "Ping to stay alive." : "Ping or send a tracked-token transfer to stay alive.";
      ev = {
        kind: "Warning", title: "Heartbeat warning", priority: 4, tags: "warning",
        text: `Heartbeat warning: no activity seen for ${human(next.warnAfter)}. Release to ${beneficiary || "the beneficiary"} no earlier than ${utc(releaseAt)}. ${stay} ${vaultLine}`,
      };
      break;
    }
    case "Released": {
      const beneficiary = addrFromWord(log.topics[2]);
      const amount = BigInt(word(log.data, 0));
      const meta = await ctx.tokenMeta();
      ev = {
        kind: "Released", title: "Heartbeat released", priority: 5, tags: "rotating_light",
        text: `Heartbeat released: ${fmtUnits(amount, meta.decimals)} ${meta.symbol} sent to ${beneficiary}. The policy is finished and cannot be undone. ${vaultLine}`,
      };
      next.released = true;
      break;
    }
    default:
      return null;
  }
  return { ev: { ...ev, link, ts, block, tx: log.transactionHash, id: `${log.transactionHash}:${toNum(log.logIndex)}` }, next };
}

/* ------------------------------------------------------------------ channels */

function buildChannels(env) {
  const ch = [];
  const fail = (_name, status) => { throw new Error(status); }; // never include URLs or tokens in errors
  if (env.NTFY_URL) {
    ch.push({
      name: "ntfy",
      async send(ev) {
        const headers = { Title: ev.title, Priority: String(ev.priority), Tags: ev.tags, Click: ev.link };
        if (env.NTFY_TOKEN) headers.Authorization = `Bearer ${env.NTFY_TOKEN}`;
        const r = await fetch(env.NTFY_URL, { method: "POST", headers, body: ev.text, signal: AbortSignal.timeout(20000) });
        if (!r.ok) fail("ntfy", `HTTP ${r.status}`);
      },
    });
  }
  if (env.TELEGRAM_BOT_TOKEN && env.TELEGRAM_CHAT_ID) {
    ch.push({
      name: "telegram",
      async send(ev) {
        const r = await fetch(`https://api.telegram.org/bot${env.TELEGRAM_BOT_TOKEN}/sendMessage`, {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ chat_id: env.TELEGRAM_CHAT_ID, text: `${ev.text}\n${ev.link}`, disable_web_page_preview: true }),
          signal: AbortSignal.timeout(20000),
        });
        if (!r.ok) fail("telegram", `HTTP ${r.status}`);
      },
    });
  } else if (env.TELEGRAM_BOT_TOKEN || env.TELEGRAM_CHAT_ID) {
    console.error("warning: Telegram needs both TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID; skipping Telegram.");
  }
  if (env.WEBHOOK_URL) {
    const fmt = (env.WEBHOOK_FORMAT || (/discord(app)?\.com\/api\/webhooks/.test(env.WEBHOOK_URL) ? "discord" : /hooks\.slack\.com/.test(env.WEBHOOK_URL) ? "slack" : "json")).toLowerCase();
    ch.push({
      name: `webhook(${fmt})`,
      async send(ev) {
        const line = `${ev.text}\n${ev.link}`;
        const body = fmt === "discord" ? { content: line } : fmt === "slack" ? { text: line }
          : { event: ev.kind, title: ev.title, text: ev.text, url: ev.link, tx: ev.tx, block: ev.block, timestamp: ev.ts };
        const r = await fetch(env.WEBHOOK_URL, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal: AbortSignal.timeout(20000) });
        if (!r.ok) fail("webhook", `HTTP ${r.status}`);
      },
    });
  }
  return ch;
}

/* ------------------------------------------------------------------ state file */

function loadState(file) {
  try { return JSON.parse(readFileSync(file, "utf8")); } catch { return null; }
}
function saveState(file, st) {
  mkdirSync(dirname(file), { recursive: true });
  const tmp = `${file}.tmp`;
  writeFileSync(tmp, JSON.stringify(st, null, 2));
  renameSync(tmp, file);
}

/* ------------------------------------------------------------------ main */

async function main() {
  const a = parseArgs(process.argv.slice(2));
  if (a.help) { console.log(HELP); return; }
  const env = process.env;
  const pick = (flag, envName, dflt) => a[flag] ?? env[envName] ?? dflt;

  const vault = pick("vault", "HEARTBEAT_VAULT");
  if (!isAddr(vault)) die("--vault <address> is required (or HEARTBEAT_VAULT). Try --help.");
  const preset = PRESETS[pick("network", "HEARTBEAT_NETWORK", "base-sepolia")];
  if (!preset) die(`Unknown --network. Known: ${Object.keys(PRESETS).join(", ")}`);
  const urls = String(pick("rpc", "HEARTBEAT_RPC", preset.rpc)).split(",").map((s) => s.trim()).filter(Boolean);
  const explorer = String(pick("explorer", "HEARTBEAT_EXPLORER", preset.explorer)).replace(/\/+$/, "");
  const dry = !!a["dry-run"];
  const once = !!a.once;
  const intervalMs = Math.max(5, Number(pick("interval", "POLL_SECONDS", 30))) * 1000;
  const confirmations = Number(pick("confirmations", "HEARTBEAT_CONFIRMATIONS", 2));
  const notifyHeartbeat = !!a["notify-heartbeat"] || env.NOTIFY_HEARTBEAT === "1" || env.NOTIFY_HEARTBEAT === "true";
  const toBlockOpt = a["to-block"] != null ? Number(a["to-block"]) : null;
  const fromBlockOpt = a["from-block"] != null ? Number(a["from-block"]) : env.HEARTBEAT_FROM_BLOCK ? Number(env.HEARTBEAT_FROM_BLOCK) : null;
  for (const [n, v] of [["--from-block", fromBlockOpt], ["--to-block", toBlockOpt]]) if (v != null && (!Number.isInteger(v) || v < 0)) die(`${n} must be a block number`);

  const channels = buildChannels(env);
  if (!dry && !channels.length) die("No channel configured. Set NTFY_URL, TELEGRAM_BOT_TOKEN + TELEGRAM_CHAT_ID, or WEBHOOK_URL (or use --dry-run).");

  const rpc = makeRpc(urls);
  const chain = makeChain(rpc);
  const vaultLc = vault.toLowerCase();
  const stateFile = a.state ? resolve(a.state) : dry ? null : join(HERE, ".state", `${preset.chainName.toLowerCase().replace(/\s+/g, "-")}-${vaultLc.slice(2, 10)}.json`);

  const ctl = { chunk: Number(pick("chunk", "HEARTBEAT_CHUNK", 50000)) };
  const ctx = {
    chain, vault, explorer, chainName: preset.chainName, pingsOnly: !!a["pings-only"], beneficiary: null,
    _meta: null,
    async tokenMeta() {
      if (this._meta) return this._meta;
      let symbol = "tokens", decimals = 18;
      try {
        const tok = addrFromWord(await chain.callAt(vault, SEL.token, null));
        try { symbol = decodeString(await chain.callAt(tok, SEL.symbol, null)) || symbol; } catch { /* keep default */ }
        try { decimals = Number(BigInt(await chain.callAt(tok, SEL.decimals, null))); } catch { /* keep default */ }
      } catch { /* keep defaults */ }
      return (this._meta = { symbol, decimals });
    },
  };

  // sanity: is there code at the vault address?
  const code = await rpc.call("eth_getCode", [vault, "latest"]);
  if (!code || code === "0x") die(`No contract at ${vault} on ${preset.chainName} (RPC ${new URL(urls[0]).host}). Wrong address, network or RPC?`, 1);

  let st = (!dry || a.state) && !a.reset && stateFile ? loadState(stateFile) : null;
  if (!st) {
    const head = await chain.blockNumber();
    st = { nextBlock: fromBlockOpt != null ? fromBlockOpt : head - confirmations + 1, delivered: {} };
    log(fromBlockOpt != null ? `Starting at block ${st.nextBlock}.` : `No cursor yet: watching from block ${st.nextBlock} (use --from-block to look back).`);
  } else {
    log(`Resuming from saved cursor, block ${st.nextBlock}.`);
  }
  st.delivered ||= {};

  log(`${dry ? "[dry-run] " : ""}Heartbeat notifier: vault ${vault} on ${preset.chainName}; RPC ${urls.map((u) => new URL(u).host).join(", ")}; ` +
    `channels: ${channels.length ? channels.map((c) => c.name).join(", ") : "none"}; heartbeat events ${notifyHeartbeat ? "on" : "off"}.`);

  let stop = false;
  process.on("SIGINT", () => { stop = true; log("Stopping."); });
  process.on("SIGTERM", () => { stop = true; });

  const counts = {};
  async function pollOnce() {
    const head = await chain.blockNumber();
    const to = Math.min(toBlockOpt ?? Infinity, head - confirmations);
    const from = st.nextBlock;
    if (from > to) { return { scanned: 0, from, to }; }
    const logs = (await chain.getLogs(vaultLc, from, to, ctl)).sort(
      (x, y) => toNum(x.blockNumber) - toNum(y.blockNumber) || toNum(x.logIndex) - toNum(y.logIndex));
    for (const lg of logs) {
      const built = await describe(lg, st, ctx);
      if (!built) continue;
      const { ev, next } = built;
      counts[ev.kind] = (counts[ev.kind] || 0) + 1;
      if (ev.skip) {
        log(`#${ev.block} ${ev.kind}: skipped (${ev.skip}) tx ${ev.tx}`);
      } else if (ev.optional && !notifyHeartbeat) {
        log(`#${ev.block} ${ev.kind}: not notified (heartbeat notifications are off)`);
      } else {
        const done = new Set(st.delivered[ev.id] || []);
        if (dry) {
          printDry(ev, channels);
        } else {
          let failed = null;
          for (const c of channels) {
            if (done.has(c.name)) continue;
            try { await c.send(ev); done.add(c.name); log(`sent ${ev.kind} (tx ${ev.tx.slice(0, 12)}...) to ${c.name}`); }
            catch (e) { failed = e; log(`FAILED ${ev.kind} to ${c.name}: ${/^HTTP \d+$/.test(e.message) ? e.message : "network error"}`); }
          }
          st.delivered[ev.id] = [...done];
          if (failed) { // stay on this block and retry on the next poll
            st.nextBlock = ev.block;
            if (stateFile) saveState(stateFile, st);
            throw new Error("delivery failed; will retry");
          }
        }
      }
      // commit what this event told us about the vault
      Object.assign(st, next);
      if (!dry && stateFile) saveState(stateFile, st);
    }
    st.nextBlock = to + 1;
    // keep the dedupe map small
    const ids = Object.keys(st.delivered);
    if (ids.length > 200) for (const k of ids.slice(0, ids.length - 200)) delete st.delivered[k];
    if (!dry && stateFile) saveState(stateFile, st);
    return { scanned: to - from + 1, from, to, events: logs.length };
  }

  let backoff = 0;
  for (;;) {
    try {
      const r = await pollOnce();
      backoff = 0;
      if (r.scanned) log(`Scanned blocks ${r.from}-${r.to} (${r.events} vault event${r.events === 1 ? "" : "s"}, ${rpc.calls} RPC calls, chunk ${ctl.chunk}).`);
      if (once) break;
    } catch (e) {
      log(`poll error: ${e.message}`);
      if (once) { summary(counts, dry); process.exit(1); }
      backoff = Math.min(backoff ? backoff * 2 : intervalMs, 10 * 60 * 1000);
    }
    if (stop) break;
    await sleep(Math.max(intervalMs, backoff));
    if (stop) break;
  }
  summary(counts, dry);
}

function printDry(ev, channels) {
  console.log(`\n--- ${ev.kind.toUpperCase()}  ${utc(ev.ts)}  block ${ev.block}`);
  console.log(`title:    ${ev.title}`);
  console.log(`priority: ${ev.priority}`);
  console.log(`message:  ${ev.text}`);
  console.log(`link:     ${ev.link}`);
  console.log(`(dry-run) would send to: ${channels.length ? channels.map((c) => c.name).join(", ") : "no channel configured"}`);
}

function summary(counts, dry) {
  const parts = Object.entries(counts).map(([k, v]) => `${k} x${v}`);
  log(`${dry ? "[dry-run] " : ""}Events seen: ${parts.length ? parts.join(", ") : "none"}.`);
}

function log(msg) {
  console.log(`[${new Date().toISOString().replace("T", " ").slice(0, 19)}Z] ${msg}`);
}

main().catch((e) => { console.error(`fatal: ${e.message}`); process.exit(1); });
