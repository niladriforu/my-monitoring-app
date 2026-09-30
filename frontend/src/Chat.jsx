import React, { useEffect, useRef, useState } from "react";
import { post } from "./api.js";

const PROMPTS = [
  "What should the desk handle first?",
  "Summarize the open alerts",
  "Which channel is failing?",
  "Anything stuck pending or in review?",
  "Draft an acknowledgement for the top alert",
];

const INTRO =
  "I answer from the live book only: open alerts, fail rates, latency, and transactions sitting in pending or review.";

export default function Chat() {
  const [messages, setMessages] = useState([]);
  const [text, setText] = useState("");
  const [busy, setBusy] = useState(false);
  const scroller = useRef(null);
  const field = useRef(null);

  useEffect(() => {
    const el = scroller.current;
    if (el) el.scrollTop = el.scrollHeight;
  }, [messages, busy]);

  const ask = async (raw) => {
    const message = raw.trim();
    if (!message || busy) return;
    setText("");
    setMessages((m) => [...m, { role: "user", text: message }]);
    setBusy(true);
    try {
      const res = await post("/api/chat", { message });
      setMessages((m) => [...m, { role: "assistant", text: res.reply }]);
    } catch (e) {
      setMessages((m) => [...m, { role: "assistant", text: e.message }]);
    } finally {
      setBusy(false);
      field.current?.focus();
    }
  };

  return (
    <aside className="chat">
      <header>
        <span className="code">ASK</span>
        <span>Desk assistant</span>
      </header>
      <div className="chat-log" ref={scroller}>
        {messages.length === 0 && <p className="intro">{INTRO}</p>}
        <div className="prompts">
          {PROMPTS.map((p) => (
            <button key={p} type="button" onClick={() => ask(p)} disabled={busy}>
              {p}
            </button>
          ))}
        </div>
        {messages.map((m, i) => (
          <div key={i} className={`bubble ${m.role}`}>
            {m.text}
          </div>
        ))}
        {busy && <div className="bubble assistant dim">Checking the book…</div>}
      </div>
      <form
        className="chat-form"
        onSubmit={(e) => {
          e.preventDefault();
          ask(text);
        }}
      >
        <input
          ref={field}
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder="Ask about alerts, failures, or a status note"
          aria-label="Ask the desk assistant"
          maxLength={500}
          disabled={busy}
        />
        <button type="submit" disabled={busy || !text.trim()}>
          Send
        </button>
      </form>
    </aside>
  );
}
