"""Simulated business-activity data source.

Replace `Store` with a repository over Amazon RDS PostgreSQL (events table) fed by
SQS/Kinesis consumers. The API contract stays the same.
"""
import random
import time
from collections import deque

CHANNELS = ["MOBILE", "WEB", "ATM", "BRANCH", "SWIFT", "ACH", "CARDS"]
EVENT_TYPES = ["PAYMENT", "TRANSFER", "LOGIN", "KYC_CHECK", "LOAN_APP", "FX_TRADE", "CARD_AUTH"]
STATUSES = ["OK"] * 18 + ["PENDING", "FAILED", "REVIEW"]
CURRENCIES = ["USD", "USD", "USD", "EUR", "GBP", "JPY"]
# Simulator notionals are drawn in major units. Yen is quoted in yen.
FX_USD = {"USD": 1.0, "EUR": 1.08, "GBP": 1.27, "JPY": 0.0067}

# A few receiving cities in each market the desk watches.
_PLACES = [
    ("New York", "United States", 40.71, -74.01),
    ("Chicago", "United States", 41.88, -87.63),
    ("San Francisco", "United States", 37.77, -122.42),
    ("Toronto", "Canada", 43.65, -79.38),
    ("Vancouver", "Canada", 49.28, -123.12),
    ("Mexico City", "Mexico", 19.43, -99.13),
    ("Monterrey", "Mexico", 25.67, -100.31),
    ("São Paulo", "Brazil", -23.55, -46.63),
    ("Rio de Janeiro", "Brazil", -22.91, -43.17),
    ("Buenos Aires", "Argentina", -34.60, -58.38),
    ("Córdoba", "Argentina", -31.42, -64.18),
    ("London", "United Kingdom", 51.51, -0.13),
    ("Manchester", "United Kingdom", 53.48, -2.24),
    ("Frankfurt", "Germany", 50.11, 8.68),
    ("Munich", "Germany", 48.14, 11.58),
    ("Paris", "France", 48.86, 2.35),
    ("Lyon", "France", 45.76, 4.84),
    ("Zurich", "Switzerland", 47.38, 8.54),
    ("Geneva", "Switzerland", 46.20, 6.14),
    ("Amsterdam", "Netherlands", 52.37, 4.90),
    ("Rotterdam", "Netherlands", 51.92, 4.48),
    ("Madrid", "Spain", 40.42, -3.70),
    ("Barcelona", "Spain", 41.39, 2.17),
    ("Milan", "Italy", 45.46, 9.19),
    ("Rome", "Italy", 41.90, 12.50),
    ("Dubai", "United Arab Emirates", 25.20, 55.27),
    ("Abu Dhabi", "United Arab Emirates", 24.45, 54.38),
    ("Mumbai", "India", 19.08, 72.88),
    ("Bengaluru", "India", 12.97, 77.59),
    ("Singapore", "Singapore", 1.35, 103.82),
    ("Hong Kong", "Hong Kong", 22.32, 114.17),
    ("Shanghai", "China", 31.23, 121.47),
    ("Beijing", "China", 39.90, 116.41),
    ("Tokyo", "Japan", 35.68, 139.69),
    ("Osaka", "Japan", 34.69, 135.50),
    ("Seoul", "South Korea", 37.57, 126.98),
    ("Busan", "South Korea", 35.18, 129.08),
    ("Jakarta", "Indonesia", -6.21, 106.85),
    ("Surabaya", "Indonesia", -7.25, 112.75),
    ("Sydney", "Australia", -33.87, 151.21),
    ("Melbourne", "Australia", -37.81, 144.96),
    ("Johannesburg", "South Africa", -26.20, 28.05),
    ("Cape Town", "South Africa", -33.92, 18.42),
    ("Lagos", "Nigeria", 6.52, 3.38),
    ("Abuja", "Nigeria", 9.06, 7.49),
    ("Nairobi", "Kenya", -1.29, 36.82),
    ("Mombasa", "Kenya", -4.04, 39.67),
]
CITIES = [
    {"city": city, "country": country, "lat": lat, "lon": lon}
    for city, country, lat, lon in _PLACES
]


def mask(acct: str) -> str:
    return "*" * (len(acct) - 4) + acct[-4:]


class Store:
    def __init__(self) -> None:
        self._rng = random.Random(42)
        self._events: deque = deque(maxlen=500)
        self._seq = 100000
        for i in range(120):
            self._add(time.time() - (120 - i) * 3, CITIES[i % len(CITIES)])

    def _add(self, ts: float, place: dict | None = None) -> None:
        r = self._rng
        self._seq += 1
        acct = "".join(str(r.randint(0, 9)) for _ in range(12))
        place = place or r.choice(CITIES)
        currency = r.choice(CURRENCIES)
        notional = r.lognormvariate(6, 1.4)
        if currency == "JPY":
            notional *= 150
        amount = round(notional, 0 if currency == "JPY" else 2)
        self._events.appendleft({
            "id": f"EV{self._seq}",
            "ts": ts,
            "type": r.choice(EVENT_TYPES),
            "channel": r.choice(CHANNELS),
            "account": mask(acct),
            "amount": amount,
            "currency": currency,
            "value_usd": round(amount * FX_USD[currency], 2),
            "city": place["city"],
            "country": place["country"],
            "lat": place["lat"],
            "lon": place["lon"],
            "status": r.choice(STATUSES),
            "latency_ms": int(r.lognormvariate(4.5, 0.6)),
        })

    def _tick(self) -> None:
        latest = self._events[0]["ts"]
        while time.time() - latest > 2:
            latest += 2
            self._add(latest)

    def recent_events(self, limit: int) -> list[dict]:
        self._tick()
        return list(self._events)[:limit]

    def kpis(self) -> dict:
        self._tick()
        ev = list(self._events)
        n = len(ev)
        failed = sum(e["status"] == "FAILED" for e in ev)
        lat = sorted(e["latency_ms"] for e in ev)
        return {
            "volume": n,
            "value_usd": round(sum(e["value_usd"] for e in ev if e["currency"] == "USD"), 2),
            "success_rate": round(100 * (n - failed) / n, 2),
            "p50_ms": lat[n // 2],
            "p95_ms": lat[int(n * 0.95)],
            "pending": sum(e["status"] == "PENDING" for e in ev),
            "in_review": sum(e["status"] == "REVIEW" for e in ev),
        }

    def alerts(self) -> list[dict]:
        self._tick()
        out = []
        for e in list(self._events)[:80]:
            if e["status"] == "FAILED" and e["amount"] > 1500:
                out.append({"sev": "HIGH", "msg": f"{e['type']} failed on {e['channel']} ({e['amount']:.0f} {e['currency']})", "id": e["id"], "ts": e["ts"]})
            elif e["status"] == "REVIEW":
                out.append({"sev": "MED", "msg": f"{e['type']} flagged for review on {e['channel']}", "id": e["id"], "ts": e["ts"]})
            elif e["latency_ms"] > 400:
                out.append({"sev": "LOW", "msg": f"Slow {e['type']} {e['latency_ms']}ms on {e['channel']}", "id": e["id"], "ts": e["ts"]})
        return out[:25]

    def throughput(self) -> list[dict]:
        self._tick()
        buckets: dict[int, int] = {}
        now = int(time.time())
        for e in self._events:
            b = (now - int(e["ts"])) // 20
            if b < 24:
                buckets[b] = buckets.get(b, 0) + 1
        return [{"t": -b * 20, "count": buckets.get(b, 0)} for b in range(23, -1, -1)]

    def channels(self) -> list[dict]:
        self._tick()
        agg: dict[str, dict] = {}
        for e in self._events:
            a = agg.setdefault(e["channel"], {"channel": e["channel"], "count": 0, "failed": 0, "lat": 0})
            a["count"] += 1
            a["failed"] += e["status"] == "FAILED"
            a["lat"] += e["latency_ms"]
        return sorted(
            [{"channel": a["channel"], "count": a["count"], "fail_pct": round(100 * a["failed"] / a["count"], 1),
              "avg_ms": round(a["lat"] / a["count"])} for a in agg.values()],
            key=lambda x: -x["count"],
        )

    def geo(self) -> dict:
        """Received volume and USD value by city, grouped under each country."""
        self._tick()
        buckets: dict[tuple[str, str], dict] = {}
        for place in CITIES:
            buckets[(place["country"], place["city"])] = {
                "city": place["city"],
                "country": place["country"],
                "lat": place["lat"],
                "lon": place["lon"],
                "volume": 0,
                "value_usd": 0.0,
            }
        for e in self._events:
            b = buckets.get((e["country"], e["city"]))
            if b is None:
                continue
            b["volume"] += 1
            b["value_usd"] += e["value_usd"]
        by_country: dict[str, dict] = {}
        for b in buckets.values():
            b["value_usd"] = round(b["value_usd"], 2)
            country = by_country.setdefault(b["country"], {
                "country": b["country"], "volume": 0, "value_usd": 0.0, "cities": [],
            })
            country["volume"] += b["volume"]
            country["value_usd"] += b["value_usd"]
            country["cities"].append({
                "city": b["city"], "lat": b["lat"], "lon": b["lon"],
                "volume": b["volume"], "value_usd": b["value_usd"],
            })
        countries = []
        for country in by_country.values():
            country["value_usd"] = round(country["value_usd"], 2)
            country["cities"].sort(key=lambda city: (-city["value_usd"], city["city"]))
            countries.append(country)
        countries.sort(key=lambda country: (-country["value_usd"], country["country"]))
        return {"countries": countries}

    def assist(self, message: str) -> dict:
        """Answer a command-center question from the live book. No model call."""
        q = " ".join(message.lower().split())
        kpis = self.kpis()
        alerts = self.alerts()
        channels = self.channels()
        return {"reply": _answer(q, kpis, alerts, channels)}


def _answer(q: str, kpis: dict, alerts: list[dict], channels: list[dict]) -> str:
    rank = {"HIGH": 0, "MED": 1, "LOW": 2}
    ordered = sorted(alerts, key=lambda a: rank.get(a["sev"], 9))
    high = [a for a in ordered if a["sev"] == "HIGH"]
    top = ordered[0] if ordered else None

    if any(w in q for w in ("not an alert", "false positive", "ignore")):
        if not top:
            return "Nothing is open, so there is no status to record."
        return (
            f"Suggested status for {top['id']}: NOT AN ALERT — {top['msg']}. "
            "Expected activity on this feed. No downstream action."
        )

    if any(w in q for w in ("acknowledg", "draft", "status note", "downstream", "talked")):
        if not top:
            return "Nothing is open to acknowledge."
        return (
            f"Suggested status for {top['id']}: ACKNOWLEDGED — {top['msg']}. "
            "Talked to the downstream system. Watching the next cycle before closing it."
        )

    if any(w in q for w in ("stuck", "pending", "review", "queue")):
        return (
            f"{kpis['pending']} transactions are pending and {kpis['in_review']} are in review. "
            "Pending is still moving through the checks. Review means someone on the desk needs to look, "
            "usually after a fraud or balance hold."
        )

    if any(w in q for w in ("fail", "channel", "unhealthy", "worst", "which system", "which app")):
        if not channels:
            return "No channel stats yet."
        worst = max(channels, key=lambda c: (c["fail_pct"], c["avg_ms"]))
        slow = max(channels, key=lambda c: c["avg_ms"])
        return (
            f"{worst['channel']} has the highest fail rate at {worst['fail_pct']}% "
            f"across {worst['count']} transactions. "
            f"{slow['channel']} is the slowest, averaging {slow['avg_ms']} ms. "
            "If that fail rate is above the threshold for this feed, it should already be an open alert."
        )

    if any(w in q for w in ("slow", "latency", "p95", "p50")):
        tone = "above" if kpis["p95_ms"] > 300 else "inside"
        return (
            f"Latency is p50 {kpis['p50_ms']} ms and p95 {kpis['p95_ms']} ms, {tone} the 300 ms watch line. "
            f"Success rate is {kpis['success_rate']}%."
        )

    if any(w in q for w in ("alert", "first", "triage", "handle", "priority", "open")):
        if not alerts:
            return "No active alerts. The book is inside the current thresholds."
        lines = [f"{len(alerts)} alerts are open, {len(high)} of them high severity."]
        if top:
            lines.append(f"Start with {top['id']} ({top['sev']}): {top['msg']}.")
        lines.append("Acknowledge it only after you have a status: not an alert, acknowledged, or talked to the downstream system.")
        return " ".join(lines)

    lines = [
        f"Book right now: {kpis['volume']} transactions, {kpis['success_rate']}% successful, "
        f"${kpis['value_usd']:,.0f} USD, p95 {kpis['p95_ms']} ms.",
        f"{kpis['pending']} pending, {kpis['in_review']} in review, {len(alerts)} open alerts"
        + (f" ({len(high)} high)." if alerts else "."),
    ]
    if top:
        lines.append(f"Top alert is {top['id']}: {top['msg']}.")
    lines.append(
        "Ask what to handle first, which channel is failing, what is stuck, or for an acknowledgement note."
    )
    return " ".join(lines)


store = Store()
