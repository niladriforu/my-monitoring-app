import React, { useEffect, useMemo, useRef, useState } from "react";
import { get } from "./api.js";
import Chat from "./Chat.jsx";
import WorldMap from "./Map.jsx";

const PANELS = {
  KPI: "Key metrics",
  EVT: "Live event stream",
  ALR: "Alerts",
  THR: "Throughput",
  CHN: "Channel health",
  MAP: "World map",
};
const FKEYS = [
  ["F1", "HELP", "HELP"],
  ["F2", "KPI", "KPI"],
  ["F3", "EVT", "EVT"],
  ["F4", "ALR", "ALR"],
  ["F5", "THR", "THR"],
  ["F6", "CHN", "CHN"],
  ["F7", "MAP", "MAP"],
  ["F8", "ALL", "ALL"],
];

const fmtTime = (ts) => new Date(ts * 1000).toLocaleTimeString("en-GB");
const fmtNum = (n) => n.toLocaleString("en-US", { maximumFractionDigits: 2 });

function usePoll(path, ms) {
  const [data, setData] = useState(null);
  const [err, setErr] = useState(null);
  useEffect(() => {
    let alive = true;
    const run = () =>
      get(path).then((d) => alive && (setData(d), setErr(null))).catch((e) => alive && setErr(e.message));
    run();
    const id = setInterval(run, ms);
    return () => { alive = false; clearInterval(id); };
  }, [path, ms]);
  return { data, err };
}

function Panel({ id, title, children, focus, onOpen }) {
  const mosaic = id !== "MAP";
  const hidden = mosaic ? focus !== "ALL" && focus !== id : focus !== "MAP";
  if (hidden) return null;
  return (
    <section className={`panel p-${id}`}>
      <header onClick={() => onOpen(id)}>
        <span className="code">{id}</span> {title}
        <span className="grow" />
        <span className="live">● LIVE</span>
      </header>
      <div className="body">{children}</div>
    </section>
  );
}

function Kpis() {
  const { data } = usePoll("/api/kpis", 3000);
  if (!data) return <div className="dim">LOADING…</div>;
  const cells = [
    ["VOLUME", fmtNum(data.volume), ""],
    ["VALUE USD", fmtNum(data.value_usd), ""],
    ["SUCCESS %", data.success_rate.toFixed(2), data.success_rate >= 95 ? "up" : "down"],
    ["P50 MS", data.p50_ms, ""],
    ["P95 MS", data.p95_ms, data.p95_ms > 300 ? "down" : "up"],
    ["PENDING", data.pending, ""],
    ["IN REVIEW", data.in_review, data.in_review > 5 ? "warn" : ""],
  ];
  return (
    <div className="kpis">
      {cells.map(([l, v, c]) => (
        <div key={l} className="kpi">
          <div className="lbl">{l}</div>
          <div className={`val ${c}`}>{v}</div>
        </div>
      ))}
    </div>
  );
}

function Events() {
  const { data } = usePoll("/api/events?limit=40", 2000);
  return (
    <table>
      <thead>
        <tr><th>TIME</th><th>ID</th><th>TYPE</th><th>CHAN</th><th>ACCOUNT</th><th className="r">AMOUNT</th><th>CCY</th><th>STATUS</th><th className="r">MS</th></tr>
      </thead>
      <tbody>
        {(data || []).map((e) => (
          <tr key={e.id}>
            <td className="dim">{fmtTime(e.ts)}</td>
            <td>{e.id}</td>
            <td>{e.type}</td>
            <td>{e.channel}</td>
            <td className="dim">{e.account}</td>
            <td className="r">{fmtNum(e.amount)}</td>
            <td>{e.currency}</td>
            <td className={`st-${e.status}`}>{e.status}</td>
            <td className={`r ${e.latency_ms > 400 ? "down" : ""}`}>{e.latency_ms}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function Alerts() {
  const { data } = usePoll("/api/alerts", 3000);
  return (
    <ul className="alerts">
      {(data || []).map((a) => (
        <li key={a.id + a.sev}>
          <span className={`sev sev-${a.sev}`}>{a.sev}</span>
          <span className="dim">{fmtTime(a.ts)}</span> {a.msg}
        </li>
      ))}
      {data && data.length === 0 && <li className="dim">NO ACTIVE ALERTS</li>}
    </ul>
  );
}

function Throughput() {
  const { data } = usePoll("/api/throughput", 3000);
  if (!data) return <div className="dim">LOADING…</div>;
  const W = 600, H = 160, pad = 24;
  const max = Math.max(1, ...data.map((d) => d.count));
  const pts = data.map((d, i) => [pad + (i * (W - 2 * pad)) / (data.length - 1), H - pad - (d.count / max) * (H - 2 * pad)]);
  const line = pts.map((p) => p.join(",")).join(" ");
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="chart" preserveAspectRatio="none">
      {[0, 0.5, 1].map((f) => (
        <g key={f}>
          <line x1={pad} x2={W - pad} y1={H - pad - f * (H - 2 * pad)} y2={H - pad - f * (H - 2 * pad)} className="grid" />
          <text x={2} y={H - pad - f * (H - 2 * pad) + 3} className="axis">{Math.round(max * f)}</text>
        </g>
      ))}
      <polygon points={`${pad},${H - pad} ${line} ${W - pad},${H - pad}`} className="area" />
      <polyline points={line} className="ln" />
      <text x={W - pad} y={H - 6} textAnchor="end" className="axis">NOW</text>
      <text x={pad} y={H - 6} className="axis">-8 MIN</text>
    </svg>
  );
}

function Channels() {
  const { data } = usePoll("/api/channels", 3000);
  const max = Math.max(1, ...(data || []).map((c) => c.count));
  return (
    <table>
      <thead><tr><th>CHANNEL</th><th>VOL</th><th></th><th className="r">FAIL %</th><th className="r">AVG MS</th></tr></thead>
      <tbody>
        {(data || []).map((c) => (
          <tr key={c.channel}>
            <td>{c.channel}</td>
            <td className="r">{c.count}</td>
            <td className="barcell"><div className="bar" style={{ width: `${(c.count / max) * 100}%` }} /></td>
            <td className={`r ${c.fail_pct > 8 ? "down" : ""}`}>{c.fail_pct.toFixed(1)}</td>
            <td className="r">{c.avg_ms}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

const CONTENT = { KPI: Kpis, EVT: Events, ALR: Alerts, THR: Throughput, CHN: Channels, MAP: WorldMap };

export default function App() {
  const [focus, setFocus] = useState("ALL");
  const [cmd, setCmd] = useState("");
  const [msg, setMsg] = useState("");
  const [now, setNow] = useState(new Date());
  const [user, setUser] = useState("…");
  const [chatOpen, setChatOpen] = useState(true);
  const input = useRef(null);
  const { err } = usePoll("/healthz", 10000);

  useEffect(() => { const id = setInterval(() => setNow(new Date()), 1000); return () => clearInterval(id); }, []);
  useEffect(() => { get("/api/me").then((m) => setUser(m.sub.toUpperCase())).catch(() => setUser("UNAUTH")); }, []);

  const run = (raw) => {
    const c = raw.trim().toUpperCase().replace(/<GO>/, "").trim();
    if (!c) return;
    if (PANELS[c]) { setFocus(c); setMsg(`${c} — ${PANELS[c]}`); }
    else if (c === "ALL" || c === "HOME") { setFocus("ALL"); setMsg("ALL PANELS"); }
    else if (c === "HELP") setMsg("COMMANDS: KPI EVT ALR THR CHN MAP ALL — ESC resets view");
    else if (c === "ASK" || c === "CHAT") { setChatOpen(true); setMsg("DESK ASSISTANT"); }
    else setMsg(`INVALID COMMAND: ${c}  (type HELP)`);
    setCmd("");
  };

  useEffect(() => {
    const onKey = (e) => {
      const el = document.activeElement;
      const typing = el && el !== input.current && (el.tagName === "INPUT" || el.tagName === "TEXTAREA");
      const f = FKEYS.find(([k]) => k === e.key);
      if (typing) return;
      if (f) { e.preventDefault(); run(f[2]); }
      else if (e.key === "Escape") run("ALL");
      else if (!e.ctrlKey && !e.metaKey && e.key.length === 1) input.current?.focus();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const clock = useMemo(
    () => now.toLocaleString("en-GB", { weekday: "short", day: "2-digit", month: "short", year: "numeric", hour: "2-digit", minute: "2-digit", second: "2-digit" }).toUpperCase(),
    [now]
  );

  return (
    <div className="term">
      <div className="topbar">
        <span className="brand">AM</span>
        <span className="sub">ACTIVITY MONITOR</span>
        <span className="grow" />
        <button type="button" className={`ask-toggle ${chatOpen ? "on" : ""}`} onClick={() => setChatOpen((v) => !v)}>
          Assistant
        </button>
        <span className={err ? "down" : "up"}>{err ? "API down" : "API ok"}</span>
        <span className="sep">|</span>
        <span>{user}</span>
        <span className="sep">|</span>
        <span>{clock} EDT</span>
      </div>
      <form className="cmdline" onSubmit={(e) => { e.preventDefault(); run(cmd); }}>
        <span className="prompt">AM&gt;</span>
        <input ref={input} value={cmd} onChange={(e) => setCmd(e.target.value)} autoFocus spellCheck={false} autoComplete="off" aria-label="command line" />
        <button type="submit">GO</button>
        <span className="msg">{msg}</span>
      </form>
      <div className={`workspace ${chatOpen ? "with-chat" : ""}`}>
        <main className={`grid focus-${focus}`}>
          {Object.entries(PANELS).map(([id, title]) => {
            const C = CONTENT[id];
            return (
              <Panel key={id} id={id} title={title} focus={focus} onOpen={(i) => setFocus(focus === "ALL" ? i : "ALL")}>
                <C />
              </Panel>
            );
          })}
        </main>
        {chatOpen && <Chat />}
      </div>
      <footer className="fkeys">
        {FKEYS.map(([k, label, c]) => (
          <button key={k} onClick={() => run(c)} className={focus === c ? "active" : ""}>
            <b>{k}</b> {label}
          </button>
        ))}
      </footer>
    </div>
  );
}
