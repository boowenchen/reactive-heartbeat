/* Heartbeat status page. Reads the vault straight from public RPC endpoints; no backend. */
(() => {
  "use strict";
  const E = window.ethers;
  const $ = (id) => document.getElementById(id);

  const VAULT_ABI = [
    "function owner() view returns (address)",
    "function token() view returns (address)",
    "function beneficiary() view returns (address)",
    "function epoch() view returns (uint256)",
    "function warnAfter() view returns (uint256)",
    "function releaseAfter() view returns (uint256)",
    "function grace() view returns (uint256)",
    "function resetAt() view returns (uint256)",
    "function activityVersion() view returns (uint256)",
    "function warnedAt() view returns (uint256)",
    "function active() view returns (bool)",
    "function released() view returns (bool)",
    "function configure(address b, uint256 w, uint256 r, uint256 g)",
    "function cancel()",
    "function recoverCancelled()",
    "event Configuration(uint256 epoch, uint256 warnAfter, uint256 releaseAfter, uint256 grace, bool active)",
    "event Warning(uint256 indexed epoch, uint256 indexed version, uint256 timestamp)",
    "event Heartbeat(uint256 indexed epoch, uint256 indexed version)",
    "event Released(uint256 indexed epoch, address indexed beneficiary, uint256 amount)",
  ];
  const ERC20_ABI = [
    "function symbol() view returns (string)",
    "function decimals() view returns (uint8)",
    "function balanceOf(address) view returns (uint256)",
    "event Transfer(address indexed from, address indexed to, uint256 amount)",
  ];
  const PULSE_ABI = ["function ping()", "event Ping(address indexed owner, uint256 timestamp)"];
  const REACTIVE_ABI = [
    "function active() view returns (bool)",
    "function cronEnabled() view returns (bool)",
    "function epoch() view returns (uint256)",
    "function latestActivity() view returns (uint256)",
    "event Activity(uint256 indexed chainId, address indexed source, uint8 kind, uint256 version)",
  ];
  const vaultIface = new E.Interface(VAULT_ABI);
  const tokenIface = new E.Interface(ERC20_ABI);
  const pulseIface = new E.Interface(PULSE_ABI);
  const reactiveIface = new E.Interface(REACTIVE_ABI);

  const REFRESH_MS = 20000;
  const TIMELINE_EVERY = 3; // timeline reloads on every third refresh
  const UNITS = [
    ["seconds", 1],
    ["minutes", 60],
    ["hours", 3600],
    ["days", 86400],
  ];

  let CFG = null;
  const providers = {};
  const S = { vault: null, token: null, reactive: null, clockOffset: 0, fetchedAt: 0, timeline: [], releasedAmount: null };
  const W = { account: null, chainId: null };
  let refreshCount = 0;
  let busy = false;

  /* ---------- helpers ---------- */
  const chain = (key) => CFG.chains[key];
  const short = (a) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");
  const sameAddr = (a, b) => !!a && !!b && a.toLowerCase() === b.toLowerCase();
  const txUrl = (key, h) => `${chain(key).explorer}/tx/${h}`;
  const addrUrl = (key, a) => `${chain(key).explorer}/address/${a}`;
  const hasTokens = () => Object.values(CFG.chains).some((c) => (c.trackedTokens || []).length);
  const nowSec = () => Math.floor(Date.now() / 1000);
  const chainNow = () => nowSec() + S.clockOffset;

  function el(tag, props, ...kids) {
    const n = document.createElement(tag);
    if (props) for (const [k, v] of Object.entries(props)) {
      if (k === "class") n.className = v;
      else if (k === "text") n.textContent = v;
      else if (k === "href") { n.href = v; n.target = "_blank"; n.rel = "noopener noreferrer"; }
      else n.setAttribute(k, v);
    }
    for (const k of kids) if (k != null) n.append(k);
    return n;
  }
  const link = (text, href, cls) => el("a", { href, text, class: cls || "" });
  const addrLink = (key, a) => el("a", { href: addrUrl(key, a), text: short(a), title: a, class: "mono" });

  function plural(n, w) { return `${n} ${w}${n === 1 ? "" : "s"}`; }
  /** Plain-language duration, two biggest units: "2 days 3 hours". */
  function human(sec) {
    sec = Math.max(0, Math.round(sec));
    if (sec < 60) return plural(sec, "second");
    const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
    if (d) return h ? `${plural(d, "day")} ${plural(h, "hour")}` : plural(d, "day");
    if (h) return m ? `${plural(h, "hour")} ${plural(m, "minute")}` : plural(h, "hour");
    return s && m < 10 ? `${plural(m, "minute")} ${plural(s, "second")}` : plural(m, "minute");
  }
  function clock(sec) {
    sec = Math.max(0, Math.floor(sec));
    const d = Math.floor(sec / 86400), h = Math.floor((sec % 86400) / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60;
    const p = (x) => String(x).padStart(2, "0");
    return `${d ? d + "d " : ""}${d || h ? p(h) + ":" : ""}${p(m)}:${p(s)}`;
  }
  const fmtTime = (ts) => new Date(ts * 1000).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "medium" });
  function ago(ts) {
    const d = chainNow() - ts;
    return d < 5 ? "just now" : `${human(d)} ago`;
  }
  function fmtAmount(raw, decimals, symbol) {
    if (raw == null) return "—";
    const s = E.formatUnits(raw, decimals);
    const [i, f = ""] = s.split(".");
    const frac = f.replace(/0+$/, "").slice(0, 4);
    return `${BigInt(i).toLocaleString()}${frac ? "." + frac : ""} ${symbol || ""}`.trim();
  }
  function bestUnit(sec) {
    for (let i = UNITS.length - 1; i >= 0; i--) if (sec % UNITS[i][1] === 0) return [sec / UNITS[i][1], i];
    return [sec, 0];
  }
  function errText(e) {
    if (!e) return "Unknown error";
    if (e.code === "ACTION_REJECTED" || e.code === 4001) return "You declined the request in your wallet.";
    return e.shortMessage || e.reason || (e.info && e.info.error && e.info.error.message) || e.message || String(e);
  }

  /* ---------- reading chain state ---------- */
  function provider(key) {
    if (!providers[key]) {
      const c = chain(key);
      providers[key] = new E.JsonRpcProvider(c.rpc, c.chainId, { staticNetwork: true });
    }
    return providers[key];
  }

  async function loadVault() {
    const key = CFG.vault.chain;
    const p = provider(key);
    const block = await p.getBlock("latest");
    const tag = { blockTag: block.number };
    const v = new E.Contract(CFG.vault.address, VAULT_ABI, p);
    const [owner, token, beneficiary, epoch, warnAfter, releaseAfter, grace, resetAt, version, warnedAt, active, released] =
      await Promise.all([
        v.owner(tag), v.token(tag), v.beneficiary(tag), v.epoch(tag), v.warnAfter(tag), v.releaseAfter(tag),
        v.grace(tag), v.resetAt(tag), v.activityVersion(tag), v.warnedAt(tag), v.active(tag), v.released(tag),
      ]);
    const n = (x) => Number(x);
    S.vault = {
      owner, token, beneficiary, epoch: n(epoch), warnAfter: n(warnAfter), releaseAfter: n(releaseAfter), grace: n(grace),
      resetAt: n(resetAt), version: n(version), warnedAt: n(warnedAt), active, released, block: block.number,
    };
    S.clockOffset = block.timestamp - nowSec();
    S.fetchedAt = nowSec();

    const t = new E.Contract(token, ERC20_ABI, p);
    const [symbol, decimals, balance] = await Promise.all([
      t.symbol(tag).catch(() => "tokens"),
      t.decimals(tag).catch(() => 18),
      t.balanceOf(CFG.vault.address, tag).catch(() => null),
    ]);
    S.token = { address: token, symbol, decimals: Number(decimals), balance };
  }

  async function loadReactive() {
    if (!CFG.reactive || !CFG.reactive.address) return;
    try {
      const r = new E.Contract(CFG.reactive.address, REACTIVE_ABI, provider(CFG.reactive.chain));
      const [active, cron] = await Promise.all([r.active(), r.cronEnabled()]);
      let latest = null;
      try { latest = Number(await r.latestActivity()); } catch { /* older deployments do not have it */ }
      S.reactive = { active, cron, latest };
    } catch {
      S.reactive = null; // optional: Lasna may be unreachable from this browser
    }
  }

  /* ---------- derived state ---------- */
  function derive(v, now) {
    if (v.released) return { kind: "released" };
    if (!v.active) return { kind: "cancelled" };
    const warnAt = v.resetAt + v.warnAfter;
    let releaseAt = v.resetAt + v.releaseAfter;
    if (v.warnedAt) {
      releaseAt = Math.max(releaseAt, v.warnedAt + v.grace);
      return { kind: now < releaseAt ? "warning" : "release-due", warnAt, releaseAt };
    }
    // Not warned yet. Earliest possible release assumes the warning is delivered at warnAt.
    releaseAt = Math.max(releaseAt, warnAt + v.grace);
    return { kind: now < warnAt ? "alive" : "warning-due", warnAt, releaseAt };
  }

  /* ---------- rendering ---------- */
  function renderStatic() {
    const v = S.vault, t = S.token;
    const c = chain(CFG.vault.chain);
    $("deployment").textContent = CFG.deployment || "";
    $("net-pill").textContent = c.name;
    document.title = "Heartbeat status";

    const facts = $("facts");
    facts.replaceChildren();
    const add = (label, node) => facts.append(el("div", null, el("dt", { text: label }), el("dd", null, node)));
    add("Owner", addrLink(CFG.vault.chain, v.owner));
    add("Beneficiary", addrLink(CFG.vault.chain, v.beneficiary));
    add("Vault holds", document.createTextNode(fmtAmount(t.balance, t.decimals, t.symbol)));
    add("Vault contract", addrLink(CFG.vault.chain, CFG.vault.address));
    add("Last activity the vault saw", el("span", { id: "f-last", text: `${fmtTime(v.resetAt)} (${ago(v.resetAt)})` }));
    add("Policy", document.createTextNode(
      v.active || v.released
        ? `warn after ${human(v.warnAfter)} of silence, release after ${human(v.releaseAfter)}, at least ${human(v.grace)} after the warning`
        : `last settings: warn ${human(v.warnAfter)}, release ${human(v.releaseAfter)}, grace ${human(v.grace)} (not active)`));
    add("Settings version", document.createTextNode(`#${v.epoch} · ${plural(v.version, "activity signal")} counted since`));

    renderSources();
    renderForm();
  }

  function renderSources() {
    const ul = $("sources");
    ul.replaceChildren();
    for (const [key, c] of Object.entries(CFG.chains)) {
      if (!c.pulse) continue;
      ul.append(el("li", null,
        el("span", { class: "tag", text: "ping" }),
        `Pulse contract on ${c.name}: `, addrLink(key, c.pulse.address),
        el("span", { class: "muted", text: " — pressing “Send ping” here records activity." })));
    }
    let tokens = 0;
    for (const [key, c] of Object.entries(CFG.chains)) {
      for (const tk of c.trackedTokens || []) {
        tokens++;
        ul.append(el("li", null,
          el("span", { class: "tag", text: "token" }),
          `${tk.symbol || "Token"} on ${c.name}: `, addrLink(key, tk.address),
          el("span", { class: "muted", text: " — any non-zero transfer of it out of the owner address counts (including one made by a contract the owner approved to spend it)." })));
      }
    }
    if (!tokens) ul.append(el("li", { class: "muted", text: "No token transfers are tracked in this deployment; only pings count." }));
    $("token-note").textContent = tokens
      ? "Sending one of the listed tokens from the owner address also counts as activity."
      : "";

    const w = $("watcher");
    const r = S.reactive;
    if (r) {
      const off = S.vault && S.vault.released ? "stopped (release completed)" : "idle (policy off)";
      const bits = [r.active ? "watching" : off, r.cron ? "timer on" : "timer off"];
      w.replaceChildren("Reactive network watcher ", addrLink(CFG.reactive.chain, CFG.reactive.address), `: ${bits.join(", ")}.`);
    } else {
      w.textContent = "The Reactive network watcher status is not available from this browser right now; the vault state above is unaffected.";
    }
  }

  function renderForm() {
    const v = S.vault;
    if (document.activeElement && $("cfg").contains(document.activeElement)) return; // do not clobber typing
    if ($("cfg").dataset.epoch === String(v.epoch)) return;
    $("cfg").dataset.epoch = String(v.epoch);
    $("cfg-ben").value = v.beneficiary;
    for (const [id, sec, uid] of [["cfg-warn", v.warnAfter, "cfg-warn-u"], ["cfg-rel", v.releaseAfter, "cfg-rel-u"], ["cfg-grace", v.grace, "cfg-grace-u"]]) {
      const [val, ui] = bestUnit(sec);
      $(id).value = val;
      $(uid).value = String(UNITS[ui][1]);
    }
  }

  function tick() {
    if (!S.vault) return;
    const v = S.vault, now = chainNow();
    const d = derive(v, now);
    const card = $("state-card");
    card.dataset.kind = d.kind;
    const label = $("state-label"), count = $("state-count"), text = $("state-text"), meta = $("state-meta");
    const track = $("track");
    track.hidden = true;
    count.textContent = "";
    meta.textContent = "";
    const sym = S.token ? S.token.symbol : "tokens";
    switch (d.kind) {
      case "alive":
        label.textContent = "Alive";
        count.textContent = clock(d.warnAt - now);
        text.textContent = `until a warning is sent, if nothing more is heard from the owner. Last activity ${ago(v.resetAt)}.`;
        meta.textContent = `Warning due ${fmtTime(d.warnAt)}. Release possible no earlier than ${fmtTime(d.releaseAt)}.`;
        showTrack(v.resetAt, d.warnAt, d.releaseAt, now);
        break;
      case "warning-due":
        label.textContent = "Warning is due";
        count.textContent = clock(d.releaseAt - now);
        text.textContent = `The owner has been silent for ${human(now - v.resetAt)}. The warning is sent on the next Reactive network tick; the vault does not know about it yet.`;
        meta.textContent = `Release possible no earlier than ${fmtTime(d.releaseAt)}, after the warning has been issued.`;
        showTrack(v.resetAt, d.warnAt, d.releaseAt, now);
        break;
      case "warning":
        label.textContent = "Warning";
        count.textContent = clock(d.releaseAt - now);
        text.textContent = `until the vault can release ${fmtAmount(S.token.balance, S.token.decimals, sym)} to the beneficiary. The owner can stop this with a ping${hasTokens() ? ", a tracked token transfer" : ""}, or Cancel.`;
        meta.textContent = `Warning issued ${fmtTime(v.warnedAt)}. Release possible from ${fmtTime(d.releaseAt)}.`;
        showTrack(v.resetAt, d.warnAt, d.releaseAt, now);
        break;
      case "release-due":
        label.textContent = "Release is due";
        text.textContent = "The waiting time has passed. The release happens when the next Reactive network tick reaches the vault. The owner can still cancel until then.";
        meta.textContent = `Release was possible from ${fmtTime(d.releaseAt)}.`;
        break;
      case "released": {
        label.textContent = "Released";
        const amt = S.releasedAmount != null ? fmtAmount(S.releasedAmount, S.token.decimals, sym) : "The vault’s tokens";
        text.textContent = `${amt} ${S.releasedAmount != null ? "was" : "were"} sent to the beneficiary. A release is final.`;
        break;
      }
      case "cancelled":
        label.textContent = "Cancelled";
        text.textContent = "The owner turned the release off. Nothing will be sent to the beneficiary. The owner can reconfigure the vault or recover the tokens.";
        break;
    }
    const last = $("f-last");
    if (last) last.textContent = `${fmtTime(v.resetAt)} (${ago(v.resetAt)})`;
  }

  function showTrack(start, warnAt, releaseAt, now) {
    $("track").hidden = false;
    const span = Math.max(1, releaseAt - start);
    const pct = (x) => Math.min(100, Math.max(0, ((x - start) / span) * 100));
    $("track-fill").style.width = pct(now) + "%";
    $("track-warn").style.left = pct(warnAt) + "%";
  }

  function renderActions() {
    const v = S.vault;
    const connected = !!W.account;
    const isOwner = connected && v && sameAddr(W.account, v.owner);
    $("connect").textContent = connected ? "Reconnect" : "Connect wallet";
    const who = $("who");
    who.replaceChildren();
    if (connected) {
      who.append("Connected as ", el("span", { class: "mono", text: W.account, title: W.account }));
      if (W.chainId != null) who.append(` on ${chainName(W.chainId)}`);
    } else if (!window.ethereum) {
      who.textContent = "No browser wallet found. Install one (for example MetaMask) to use these controls.";
    }
    const note = $("owner-note");
    note.hidden = true;
    note.className = "notice";
    if (connected && v) {
      note.hidden = false;
      if (isOwner) { note.classList.add("ok"); note.textContent = "This is the owner address. All controls are available."; }
      else note.textContent = `This is not the owner address (owner: ${short(v.owner)}). Cancel and Reconfigure are disabled. A ping from this address is accepted by the chain but does not count as the owner being alive.`;
    }
    const off = busy || !v;
    $("ping").disabled = off || !connected;
    $("cancel").disabled = off || !isOwner || !v.active || v.released;
    $("cfg-submit").disabled = off || !isOwner || v.released;
    const showRecover = v && !v.active && !v.released && S.token && S.token.balance != null && S.token.balance > 0n;
    $("recover-box").hidden = !showRecover;
    $("recover").disabled = off || !isOwner;
  }
  function chainName(id) {
    for (const c of Object.values(CFG.chains)) if (c.chainId === Number(id)) return c.name;
    return `chain ${id}`;
  }

  /* ---------- timeline ---------- */
  /* Event history. Primary source: a JSON-RPC node (eth_getLogs in chunks the node allows).
     Fallback: the chain's Blockscout API, which is CORS-enabled but rate-limited (HTTP 429). */
  const logProviders = {};
  function logProvider(key) {
    if (!logProviders[key]) {
      const c = chain(key);
      logProviders[key] = c.logRpc && c.logRpc !== c.rpc ? new E.JsonRpcProvider(c.logRpc, c.chainId, { staticNetwork: true }) : provider(key);
    }
    return logProviders[key];
  }

  async function rpcLogs(key, address, topics, fromBlock) {
    const c = chain(key), p = logProvider(key);
    const head = await p.getBlockNumber();
    const step = c.logChunk || 50000;
    let rows = [];
    for (let f = fromBlock || 0; f <= head; f += step) {
      const part = await p.getLogs({ address, topics, fromBlock: f, toBlock: Math.min(head, f + step - 1) });
      rows.push(...part);
    }
    rows.sort((x, y) => y.blockNumber - x.blockNumber || y.index - x.index);
    rows = rows.slice(0, 40); // only the newest are shown; fetch timestamps for those only
    const blockTs = {};
    await Promise.all([...new Set(rows.map((l) => l.blockNumber))].map(async (n) => { blockTs[n] = (await p.getBlock(n)).timestamp; }));
    return rows.map((l) => ({ topics: [...l.topics], data: l.data, tx: l.transactionHash, block: l.blockNumber, ts: blockTs[l.blockNumber], idx: l.index }));
  }

  async function explorerLogs(key, address, topics, fromBlock) {
    const c = chain(key);
    if (!c.explorerApi) throw new Error("no explorer API configured");
    const params = { module: "logs", action: "getLogs", fromBlock: String(fromBlock || 0), toBlock: "latest", address };
    if (topics[0]) params.topic0 = topics[0];
    if (topics[1]) { params.topic1 = topics[1]; params.topic0_1_opr = "and"; }
    const r = await fetch(`${c.explorerApi}?${new URLSearchParams(params)}`);
    if (!r.ok) throw new Error(`explorer API ${r.status}`);
    const j = await r.json();
    if (!Array.isArray(j.result)) throw new Error("explorer API returned no data");
    return j.result
      .map((l) => ({
        topics: l.topics.filter(Boolean), data: l.data, tx: l.transactionHash,
        block: parseInt(l.blockNumber, 16), ts: parseInt(l.timeStamp, 16), idx: parseInt(l.logIndex || "0x0", 16),
      }))
      .sort((x, y) => y.block - x.block || y.idx - x.idx)
      .slice(0, 40);
  }

  async function getLogs(key, address, topics, fromBlock) {
    try {
      return await rpcLogs(key, address, topics, fromBlock);
    } catch (e1) {
      try {
        return await explorerLogs(key, address, topics, fromBlock);
      } catch (e2) {
        throw new Error(`${errText(e1)}; explorer fallback: ${errText(e2)}`);
      }
    }
  }

  function describeVaultEvent(ev, ctx) {
    const key = CFG.vault.chain;
    const sym = S.token ? S.token.symbol : "tokens";
    const dec = S.token ? S.token.decimals : 18;
    switch (ev.name) {
      case "Configuration": {
        const [epoch, w, r, g, active] = ev.args;
        const detail = `warn ${human(Number(w))}, release ${human(Number(r))}, grace ${human(Number(g))}`;
        if (!active) return { title: "Cancelled by the owner", detail, tone: "bad", cfgKey: `${epoch}/${w}/${r}/${g}/${active}` };
        return { title: Number(epoch) === 1 ? "Vault created with its policy" : `Settings updated (version ${epoch})`, detail, tone: "alive", cfgKey: `${epoch}/${w}/${r}/${g}/${active}` };
      }
      case "Heartbeat":
        return { title: "Vault registered owner activity", detail: `activity signal #${ev.args[1]}`, tone: "alive" };
      case "Warning":
        return { title: "Warning issued", detail: "Silence passed the warning threshold.", tone: "warn" };
      case "Released": {
        const amt = ev.args[2];
        ctx.releasedAmount = amt;
        return { title: `Released ${fmtAmount(amt, dec, sym)}`, detail: `to ${ev.args[1]}`, tone: "done" };
      }
    }
    return null;
  }

  async function loadTimeline() {
    const items = [];
    const notes = [];
    const ctx = { releasedAmount: null };
    const vkey = CFG.vault.chain;
    const owner = S.vault.owner;
    const ownerTopic = E.zeroPadValue(owner, 32);

    const tasks = [];
    const cache = (S.srcCache = S.srcCache || {});
    // Run one source; on failure keep what that source returned last time instead of blanking the list.
    const source = (id, label, fn) => {
      const got = [];
      return fn(got).then(
        () => { cache[id] = got; items.push(...got); },
        (e) => {
          if (cache[id]) { items.push(...cache[id]); notes.push(`${label} could not refresh (${errText(e)}); showing earlier data.`); }
          else notes.push(`${label} unavailable (${errText(e)}).`);
        });
    };
    // 1. Vault events
    tasks.push(source("vault", "Vault history", async (items) => {
      const logs = await getLogs(vkey, CFG.vault.address, [], CFG.vault.deployBlock);
      for (const l of logs) {
        let ev; try { ev = vaultIface.parseLog({ topics: l.topics, data: l.data }); } catch { continue; }
        if (!ev) continue;
        const d = describeVaultEvent(ev, ctx);
        if (d) items.push({ ...l, chain: vkey, ...d });
      }
    }));

    // 2. Pings and tracked-token transfers by the owner
    for (const [key, c] of Object.entries(CFG.chains)) {
      if (c.pulse) {
        tasks.push(source("ping-" + key, `${c.name} pings`, async (items) => {
          const logs = await getLogs(key, c.pulse.address, [pulseIface.getEvent("Ping").topicHash, ownerTopic], c.pulse.deployBlock);
          for (const l of logs) items.push({ ...l, chain: key, title: `Ping from the owner on ${c.name}`, detail: "recorded by the Pulse contract", tone: "alive" });
        }));
      }
      for (const tk of c.trackedTokens || []) {
        tasks.push(source("tok-" + key + tk.address, `${c.name} ${tk.symbol || "token"} transfers`, async (items) => {
          const logs = await getLogs(key, tk.address, [tokenIface.getEvent("Transfer").topicHash, ownerTopic], tk.deployBlock);
          for (const l of logs) items.push({ ...l, chain: key, title: `${tk.symbol || "Token"} sent from the owner on ${c.name}`, detail: "counts as activity", tone: "alive" });
        }));
      }
    }

    // 3. Reactive network activity (optional)
    if (CFG.reactive && CFG.reactive.address) {
      tasks.push(source("reactive", "Reactive network history", async (items) => {
        const rk = CFG.reactive.chain, rc = chain(rk), p = provider(rk);
        const head = await p.getBlockNumber();
        const range = rc.maxLogRange || 10000;
        const start = Math.max(CFG.reactive.deployBlock || 0, head - range * 6);
        const topic = reactiveIface.getEvent("Activity").topicHash;
        const blockTs = {};
        for (let from = start; from <= head; from += range) {
          const logs = await p.getLogs({ address: CFG.reactive.address, topics: [topic], fromBlock: from, toBlock: Math.min(head, from + range - 1) });
          for (const l of logs) {
            const ev = reactiveIface.parseLog({ topics: [...l.topics], data: l.data });
            if (blockTs[l.blockNumber] == null) blockTs[l.blockNumber] = (await p.getBlock(l.blockNumber)).timestamp;
            const [chainId, source, kind, version] = ev.args;
            items.push({
              chain: rk, tx: l.transactionHash, block: l.blockNumber, ts: blockTs[l.blockNumber], idx: l.index,
              title: `Reactive network counted ${Number(kind) === 1 ? "a token transfer" : "a ping"} from ${chainName(chainId)}`,
              detail: `activity signal #${version}`, tone: "alive",
            });
          }
        }
      }));
    }

    await Promise.all(tasks);
    items.sort((a, b) => b.ts - a.ts || b.idx - a.idx);
    // The same settings can be published again (to inform the Reactive network); do not show that as a new policy.
    const seenCfg = new Set();
    for (const it of [...items].reverse()) {
      if (!it.cfgKey) continue;
      if (seenCfg.has(it.cfgKey)) { it.title = "Settings re-published to the Reactive network"; it.tone = ""; }
      seenCfg.add(it.cfgKey);
    }
    S.timeline = items;
    if (ctx.releasedAmount != null) S.releasedAmount = ctx.releasedAmount;
    renderTimeline(notes);
  }

  function renderTimeline(notes) {
    const ol = $("timeline");
    ol.replaceChildren();
    const items = S.timeline.slice(0, 40);
    if (!items.length) ol.append(el("li", { class: "muted", text: "No events found yet." }));
    for (const it of items) {
      ol.append(el("li", null,
        el("span", { class: `dot ${it.tone || ""}` }),
        el("div", null,
          el("div", { class: "ev-title", text: it.title }),
          el("div", { class: "ev-meta" },
            `${fmtTime(it.ts)} · ${chain(it.chain).name} · `,
            link("view transaction", txUrl(it.chain, it.tx)),
            it.detail ? ` · ${it.detail}` : ""))));
    }
    $("timeline-note").textContent = [S.timeline.length > 40 ? `Showing the newest 40 of ${S.timeline.length}.` : "", ...notes].filter(Boolean).join(" ");
  }

  /* ---------- wallet actions ---------- */
  function setStatus(node, isErr) {
    const t = $("tx-status");
    t.className = "tx" + (isErr ? " err" : "");
    t.replaceChildren(node);
  }

  async function ensureChain(key) {
    const c = chain(key);
    const want = "0x" + c.chainId.toString(16);
    const cur = await window.ethereum.request({ method: "eth_chainId" });
    if (cur.toLowerCase() === want) return;
    try {
      await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId: want }] });
    } catch (e) {
      const code = e && (e.code ?? (e.data && e.data.originalError && e.data.originalError.code));
      if (code !== 4902 && code !== -32603) throw e;
      await window.ethereum.request({
        method: "wallet_addEthereumChain",
        params: [{ chainId: want, chainName: c.name, nativeCurrency: c.nativeCurrency, rpcUrls: [c.rpc], blockExplorerUrls: [c.explorer] }],
      });
    }
  }

  async function send(key, label, build) {
    if (!window.ethereum || busy) return;
    busy = true; renderActions();
    try {
      setStatus(document.createTextNode(`${label}: switching network if needed…`));
      await ensureChain(key);
      const signer = await new E.BrowserProvider(window.ethereum).getSigner();
      setStatus(document.createTextNode(`${label}: confirm in your wallet…`));
      const tx = await build(signer);
      const url = txUrl(key, tx.hash);
      setStatus(el("span", null, `${label}: sent, waiting for confirmation — `, link(short(tx.hash), url)));
      const rc = await tx.wait();
      if (rc && rc.status === 1) {
        setStatus(el("span", null, `${label}: confirmed — `, link(short(tx.hash), url),
          label === "Ping" ? ". The vault sees a ping only after the Reactive network relays it; this can take a minute." : ""));
      } else {
        setStatus(el("span", null, `${label}: the transaction failed — `, link(short(tx.hash), url)), true);
      }
      await refresh(true);
      setTimeout(() => refresh(true), 4000);
    } catch (e) {
      setStatus(document.createTextNode(`${label}: ${errText(e)}`), true);
    } finally {
      busy = false; renderActions();
    }
  }

  async function connect() {
    if (!window.ethereum) { renderActions(); return; }
    try {
      const accts = await window.ethereum.request({ method: "eth_requestAccounts" });
      W.account = accts[0] ? E.getAddress(accts[0]) : null;
      W.chainId = parseInt(await window.ethereum.request({ method: "eth_chainId" }), 16);
    } catch (e) {
      setStatus(document.createTextNode(`Connect: ${errText(e)}`), true);
    }
    renderActions();
  }

  function readForm() {
    const ben = $("cfg-ben").value.trim();
    const num = (id, uid) => Number($(id).value) * Number($(uid).value);
    const w = num("cfg-warn", "cfg-warn-u"), r = num("cfg-rel", "cfg-rel-u"), g = num("cfg-grace", "cfg-grace-u");
    if (!E.isAddress(ben) || /^0x0{40}$/i.test(ben)) throw new Error("Enter a valid beneficiary address.");
    if (sameAddr(ben, CFG.vault.address)) throw new Error("The beneficiary cannot be the vault itself.");
    for (const x of [w, r, g]) if (!Number.isInteger(x) || x <= 0) throw new Error("Times must be whole, positive numbers.");
    if (r <= w) throw new Error("Release after must be longer than warn after.");
    if (r > 3650 * 86400) throw new Error("Release after can be at most 3650 days.");
    if (g > 365 * 86400) throw new Error("Grace can be at most 365 days.");
    return { ben: E.getAddress(ben), w, r, g };
  }

  function wire() {
    $("connect").addEventListener("click", connect);
    $("reload").addEventListener("click", () => refresh(true));
    $("ping").addEventListener("click", () => {
      const key = $("ping-chain").value;
      const owner = S.vault && sameAddr(W.account, S.vault.owner);
      if (!owner && !confirm("This wallet is not the owner address. The ping will not count as the owner being alive. Send it anyway?")) return;
      send(key, "Ping", (signer) => new E.Contract(chain(key).pulse.address, PULSE_ABI, signer).ping());
    });
    $("cancel").addEventListener("click", () => {
      if (!confirm("Cancel the release? Nothing will be sent to the beneficiary until you reconfigure the vault.")) return;
      send(CFG.vault.chain, "Cancel", (signer) => new E.Contract(CFG.vault.address, VAULT_ABI, signer).cancel());
    });
    $("recover").addEventListener("click", () => {
      if (!confirm("Send all tokens in the vault back to the owner address?")) return;
      send(CFG.vault.chain, "Recover tokens", (signer) => new E.Contract(CFG.vault.address, VAULT_ABI, signer).recoverCancelled());
    });
    $("cfg").addEventListener("submit", (ev) => {
      ev.preventDefault();
      let f;
      try { f = readForm(); } catch (e) { setStatus(document.createTextNode(e.message), true); return; }
      const msg = `Save these settings and restart the countdown from now?\n\nBeneficiary: ${f.ben}\nWarn after: ${human(f.w)}\nRelease after: ${human(f.r)}\nGrace: ${human(f.g)}`;
      if (!confirm(msg)) return;
      send(CFG.vault.chain, "Reconfigure", (signer) => new E.Contract(CFG.vault.address, VAULT_ABI, signer).configure(f.ben, f.w, f.r, f.g));
    });
    if (window.ethereum && window.ethereum.on) {
      window.ethereum.on("accountsChanged", (a) => { W.account = a && a[0] ? E.getAddress(a[0]) : null; renderActions(); });
      window.ethereum.on("chainChanged", (id) => { W.chainId = parseInt(id, 16); renderActions(); });
    }
    // silently pick up an already-authorised wallet; never prompts
    if (window.ethereum) {
      window.ethereum.request({ method: "eth_accounts" }).then(async (a) => {
        if (a && a[0]) {
          W.account = E.getAddress(a[0]);
          W.chainId = parseInt(await window.ethereum.request({ method: "eth_chainId" }), 16);
          renderActions();
        }
      }).catch(() => {});
    }
  }

  /* ---------- main ---------- */
  let timelineBusy = false;
  async function refreshTimeline() {
    if (timelineBusy || !S.vault) return;
    timelineBusy = true;
    try {
      await loadTimeline();
      tick(); // the released amount may have arrived
    } catch (e) {
      $("timeline-note").textContent = `Events could not be loaded (${errText(e)}).`;
    } finally {
      timelineBusy = false;
    }
  }

  async function refresh(withTimeline) {
    try {
      await Promise.all([loadVault(), loadReactive()]);
      renderStatic();
      tick();
      renderActions();
      // Events come from a rate-limited public API: never block the status on them.
      if (withTimeline || refreshCount % TIMELINE_EVERY === 0 || !S.timeline.length) refreshTimeline();
      refreshCount++;
    } catch (e) {
      if (!S.vault) {
        $("state-card").dataset.kind = "error";
        $("state-label").textContent = "Cannot read the vault";
        $("state-text").textContent = `${errText(e)} Check your connection or try again in a moment.`;
      } else {
        $("state-meta").textContent = `Could not refresh (${errText(e)}). Showing the last data.`;
      }
    }
  }

  async function main() {
    if (!E) { $("state-label").textContent = "Cannot load the page library"; return; }
    try {
      CFG = await (await fetch("config.json", { cache: "no-store" })).json();
    } catch (e) {
      $("state-card").dataset.kind = "error";
      $("state-label").textContent = "Missing config.json";
      return;
    }
    // selectors
    const sel = $("ping-chain");
    for (const [k, c] of Object.entries(CFG.chains)) if (c.pulse) sel.append(el("option", { value: k, text: c.name }));
    for (const id of ["cfg-warn-u", "cfg-rel-u", "cfg-grace-u"]) for (const [n, m] of UNITS) $(id).append(el("option", { value: String(m), text: n }));
    const links = $("links");
    links.append("Contracts: vault ", addrLink(CFG.vault.chain, CFG.vault.address));
    wire();
    renderActions();
    await refresh(true);
    setInterval(tick, 1000);
    setInterval(() => { if (!busy && !document.hidden) refresh(false); }, REFRESH_MS);
  }
  window.__hb = { S, tick, renderStatic, renderActions }; // read-only helpers for manual testing
  main();
})();
