"""Activity Monitoring API (FastAPI).

Security posture:
- All /api routes require a JWT (Cognito-issued in AWS; HS256 dev token locally).
- Role based access (viewer / analyst / admin).
- Strict security headers, no wildcard CORS, request IDs, audit log of reads.
- Account numbers are masked in every response.
"""
import logging
import time
import uuid

from fastapi import Depends, FastAPI, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from .config import settings
from .data import store
from .security import Principal, require_role, dev_token

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
audit = logging.getLogger("audit")

app = FastAPI(title="AM API", version="1.0.0", docs_url=None if settings.env == "prod" else "/docs")

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.allowed_origins,
    allow_methods=["GET", "POST"],
    allow_headers=["Authorization", "Content-Type"],
    allow_credentials=False,
)


@app.middleware("http")
async def hardening(request: Request, call_next):
    rid = request.headers.get("x-request-id", str(uuid.uuid4()))
    start = time.perf_counter()
    response = await call_next(request)
    response.headers["X-Request-ID"] = rid
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["X-Frame-Options"] = "DENY"
    response.headers["Strict-Transport-Security"] = "max-age=63072000; includeSubDomains"
    response.headers["Cache-Control"] = "no-store"
    response.headers["Referrer-Policy"] = "no-referrer"
    audit.info("rid=%s %s %s %s %.1fms", rid, request.method, request.url.path,
               response.status_code, (time.perf_counter() - start) * 1000)
    return response


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/api/me")
def me(user: Principal = Depends(require_role("viewer"))):
    return {"sub": user.sub, "roles": user.roles}


@app.get("/api/kpis")
def kpis(user: Principal = Depends(require_role("viewer"))):
    return store.kpis()


@app.get("/api/events")
def events(limit: int = Query(50, ge=1, le=200), user: Principal = Depends(require_role("viewer"))):
    return store.recent_events(limit)


@app.get("/api/alerts")
def alerts(user: Principal = Depends(require_role("viewer"))):
    return store.alerts()


@app.get("/api/throughput")
def throughput(user: Principal = Depends(require_role("viewer"))):
    return store.throughput()


@app.get("/api/channels")
def channels(user: Principal = Depends(require_role("viewer"))):
    return store.channels()


@app.get("/api/geo")
def geo(user: Principal = Depends(require_role("viewer"))):
    """Received transaction volume and USD value for cities in each country."""
    return store.geo()


class ChatIn(BaseModel):
    message: str = Field(min_length=1, max_length=500)


@app.post("/api/chat")
def chat(body: ChatIn, user: Principal = Depends(require_role("viewer"))):
    """Command-center assistant. Answers from the live book only."""
    return store.assist(body.message)


if settings.env != "prod":
    @app.get("/api/dev-token")
    def get_dev_token():
        """Local development only. Disabled when ENV=prod."""
        return {"token": dev_token()}
