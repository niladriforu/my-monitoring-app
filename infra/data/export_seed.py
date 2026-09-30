"""Write a deterministic AM simulator snapshot for the data Terraform stack.

The clock and RNG are fixed, so re-running this script produces the same files.
Account numbers are already masked by the simulator.
"""
import importlib.util
import json
import time
from pathlib import Path

FIXED = 1759104000.0  # 2026-09-29 00:00:00 UTC
time.time = lambda: FIXED

ROOT = Path(__file__).resolve().parents[2]
SEED = Path(__file__).resolve().parent / "seed"
spec = importlib.util.spec_from_file_location("am_data", ROOT / "backend" / "app" / "data.py")
am_data = importlib.util.module_from_spec(spec)
spec.loader.exec_module(am_data)

store = am_data.Store()
kpis = store.kpis()
events = list(store._events)
alerts = store.alerts()
throughput = store.throughput()
channels = store.channels()
geo = store.geo()


def num(value: float | int) -> str:
    if isinstance(value, bool):
        raise TypeError(value)
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    text = format(float(value), "f")
    if "." in text:
        text = text.rstrip("0").rstrip(".")
    return text or "0"


def item(fields: dict) -> dict:
    encoded = {}
    for key, value in fields.items():
        if isinstance(value, bool):
            encoded[key] = {"BOOL": value}
        elif isinstance(value, (int, float)):
            encoded[key] = {"N": num(value)}
        else:
            encoded[key] = {"S": str(value)}
    return encoded


def dump(name: str, payload) -> None:
    (SEED / name).write_text(json.dumps(payload, indent=2) + "\n")


event_ids = [event["id"] for event in events]
alert_ids = [alert["id"] for alert in alerts]
if len(event_ids) != len(set(event_ids)):
    raise SystemExit("duplicate event ids")
if len(alert_ids) != len(set(alert_ids)):
    raise SystemExit("duplicate alert ids")

SEED.mkdir(parents=True, exist_ok=True)
dump("events.json", events)
dump("alerts.json", alerts)
dump("kpis.json", kpis)
dump("throughput.json", throughput)
dump("channels.json", channels)
dump("geo.json", geo)
dump("ddb-events.json", {event["id"]: item(event) for event in events})
dump("ddb-alerts.json", {alert["id"]: item(alert) for alert in alerts})
dump(
    "ddb-aggregates.json",
    {
        name: item({"id": name, "payload": json.dumps(payload, separators=(",", ":"))})
        for name, payload in {
            "kpis": kpis,
            "throughput": throughput,
            "channels": channels,
            "geo": geo,
        }.items()
    },
)

print(f"events={len(events)} alerts={len(alerts)} channels={len(channels)} cities="
      f"{sum(len(country['cities']) for country in geo['countries'])}")
