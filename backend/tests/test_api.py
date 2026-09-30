from fastapi.testclient import TestClient

from app.main import app
from app.security import dev_token

c = TestClient(app)
H = {"Authorization": f"Bearer {dev_token()}"}


def test_requires_auth():
    assert c.get("/api/kpis").status_code == 401


def test_kpis_and_headers():
    r = c.get("/api/kpis", headers=H)
    assert r.status_code == 200
    assert r.headers["x-content-type-options"] == "nosniff"
    assert 0 <= r.json()["success_rate"] <= 100


def test_accounts_masked():
    for e in c.get("/api/events?limit=50", headers=H).json():
        assert e["account"].startswith("********")


def test_bad_token():
    assert c.get("/api/kpis", headers={"Authorization": "Bearer nope"}).status_code == 401


def test_geo_requires_auth():
    assert c.get("/api/geo").status_code == 401


def test_geo_received_by_city():
    r = c.get("/api/geo", headers=H)
    assert r.status_code == 200
    countries = r.json()["countries"]
    assert any(len(country["cities"]) >= 2 for country in countries)
    assert any(country["country"] == "United States" and len(country["cities"]) >= 3 for country in countries)
    for country in countries:
        assert country["volume"] == sum(city["volume"] for city in country["cities"])
        assert abs(country["value_usd"] - sum(city["value_usd"] for city in country["cities"])) < 0.05
        assert country["volume"] > 0
        for city in country["cities"]:
            assert city["volume"] > 0
            assert city["value_usd"] >= 0
            assert -90 <= city["lat"] <= 90
            assert -180 <= city["lon"] <= 180


def test_chat_requires_auth():
    assert c.post("/api/chat", json={"message": "summarize alerts"}).status_code == 401


def test_chat_answers_from_the_book():
    r = c.post("/api/chat", headers=H, json={"message": "What should the desk handle first?"})
    assert r.status_code == 200
    assert "alert" in r.json()["reply"].lower()
