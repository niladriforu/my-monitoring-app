// API client. In AWS the token comes from Cognito (Hosted UI / PKCE) — see README.
// Locally we fetch a dev token from the backend (disabled when ENV=prod).
const BASE = import.meta.env.VITE_API_BASE || "";
let token = sessionStorage.getItem("am_token");

async function ensureToken() {
  if (token) return token;
  const r = await fetch(`${BASE}/api/dev-token`);
  if (!r.ok) throw new Error("AUTH REQUIRED");
  token = (await r.json()).token;
  sessionStorage.setItem("am_token", token);
  return token;
}

async function send(path, options) {
  const t = await ensureToken();
  const r = await fetch(`${BASE}${path}`, {
    ...options,
    headers: { Authorization: `Bearer ${t}`, ...(options.headers || {}) },
  });
  if (r.status === 401) {
    sessionStorage.removeItem("am_token");
    token = null;
  }
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

export function get(path) {
  return send(path, {});
}

export function post(path, body) {
  return send(path, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}
