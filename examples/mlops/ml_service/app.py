import hmac
import logging
import time
from contextlib import asynccontextmanager
from typing import Any, Awaitable, Callable
from uuid import UUID

from fastapi import FastAPI, Header, HTTPException, Request, Response, status, Depends
from fastapi.responses import JSONResponse, PlainTextResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, Gauge, generate_latest
from redis import Redis

from . import db, storage
from .config import settings
from .model_registry import load, predict, resolve
from .schemas import BatchAccepted, BatchRequest, BatchStatus, PredictionRequest, PredictionResponse

LOGGER = logging.getLogger("akkar.ml")

REQUESTS = Counter("ml_http_requests_total", "Requests", ["route", "status"])
LATENCY = Histogram("ml_prediction_seconds", "Prediction latency", ["model", "version"])
OUTBOX = Gauge("ml_outbox_pending", "Undispatched batch jobs")
OUTBOX_AGE = Gauge("ml_outbox_oldest_seconds", "Oldest pending batch intent")
STALLED = Gauge("ml_jobs_stalled", "Queued too long or expired worker lease")
RETRIES = Gauge("ml_job_retries", "Retry attempts in retained job records")
FAILED = Gauge("ml_jobs_failed", "Retained terminal failures")
RUNNING = Gauge("ml_jobs_running", "Jobs with worker ownership")


def tenant_id(x_tenant_id: str = Header(pattern=r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) -> str:
    return x_tenant_id


class BodyLimitMiddleware:
    def __init__(self, app: Callable[..., Awaitable[Any]], limit: int):
        self.app, self.limit = app, limit

    async def __call__(self, scope: dict[str, Any], receive: Callable[..., Awaitable[Any]], send: Callable[..., Awaitable[Any]]) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        headers = {key.lower(): value for key, value in scope.get("headers", [])}
        content_length = headers.get(b"content-length")
        if content_length:
            try:
                declared = int(content_length)
            except ValueError:
                await self._reject(send, 400, "invalid content-length")
                return
            if declared > self.limit:
                await self._reject(send, 413, "request body too large")
                return

        seen = 0

        class BodyTooLarge(Exception):
            pass

        async def bounded_receive() -> dict[str, Any]:
            nonlocal seen
            message = await receive()
            if message["type"] == "http.request":
                seen += len(message.get("body", b""))
                if seen > self.limit:
                    raise BodyTooLarge
            return message

        started = False

        async def tracked_send(message: dict[str, Any]) -> None:
            nonlocal started
            if message["type"] == "http.response.start":
                started = True
            await send(message)

        try:
            await self.app(scope, bounded_receive, tracked_send)
        except BodyTooLarge:
            if not started:
                await self._reject(send, 413, "request body too large")

    @staticmethod
    async def _reject(send: Callable[..., Awaitable[Any]], code: int, detail: str) -> None:
        body = ('{"detail":"' + detail + '"}').encode()
        await send(
            {
                "type": "http.response.start",
                "status": code,
                "headers": [
                    (b"content-type", b"application/json"),
                    (b"content-length", str(len(body)).encode()),
                ],
            }
        )
        await send({"type": "http.response.body", "body": body})


@asynccontextmanager
async def lifespan(_: FastAPI):
    # Schema changes are an explicit stopped-worker migration, not startup work.
    db.ping()
    # Do not admit traffic and then spend the first request's deadline
    # downloading a model. Every serving worker resolves, verifies, and loads
    # its immutable version before Uvicorn marks startup complete.
    load(settings().model_name, settings().model_alias)
    yield


app = FastAPI(title="akkar ML service", version="1.0.0", lifespan=lifespan)
app.add_middleware(BodyLimitMiddleware, limit=settings().max_body_bytes)


@app.middleware("http")
async def authenticate(request: Request, call_next):  # noqa: ANN001
    if request.url.path.startswith("/internal/"):
        expected = "Bearer " + settings().internal_token.get_secret_value()
        supplied = request.headers.get("authorization", "")
        if not hmac.compare_digest(supplied.encode(), expected.encode()):
            return JSONResponse({"detail": "unauthorized"}, status_code=401)
    response = await call_next(request)
    if traceparent := request.headers.get("traceparent"):
        response.headers["traceparent"] = traceparent
    return response


@app.get("/live")
def live() -> dict[str, bool]:
    return {"ok": True}


@app.get("/ready")
def ready() -> dict[str, bool]:
    redis = Redis.from_url(settings().redis_url)
    try:
        db.ping()
        redis.ping()
        load(settings().model_name, settings().model_alias)
    except Exception as exc:
        raise HTTPException(status_code=503, detail=f"not ready: {type(exc).__name__}") from exc
    finally:
        redis.close()
    return {"ok": True}


@app.get("/metrics")
def metrics() -> Response:
    try:
        values = db.queue_metrics()
        OUTBOX.set(values["pending"])
        OUTBOX_AGE.set(values["oldest"])
        STALLED.set(values["stalled"])
        RETRIES.set(values["retries"])
        FAILED.set(values["failed"])
        RUNNING.set(values["running"])
    except Exception as exc:
        raise HTTPException(status_code=503, detail="metrics database unavailable") from exc
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/internal/v1/predictions", response_model=PredictionResponse)
def predictions(payload: PredictionRequest, tenant: str = Depends(tenant_id)) -> PredictionResponse:
    cfg = settings()
    name, alias = payload.model_name or cfg.model_name, payload.model_alias or cfg.model_alias
    started = time.monotonic()
    try:
        outputs, loaded = predict(name, alias, payload.inputs)
    except Exception as exc:
        LOGGER.exception("prediction failed for model=%s alias=%s", name, alias)
        REQUESTS.labels("predictions", "503").inc()
        raise HTTPException(status_code=503, detail="model unavailable") from exc
    LATENCY.labels(name, loaded.version).observe(time.monotonic() - started)
    REQUESTS.labels("predictions", "200").inc()
    return PredictionResponse(
        model_name=name,
        model_version=loaded.version,
        model_digest=loaded.digest,
        outputs=outputs,
    )


@app.post("/internal/v1/batches", response_model=BatchAccepted, status_code=status.HTTP_202_ACCEPTED)
def batches(
    payload: BatchRequest,
    request: Request,
    tenant: str = Depends(tenant_id),
    idempotency_key: str = Header(min_length=1, max_length=200),
) -> BatchAccepted:
    cfg = settings()
    values = payload.model_dump()
    values["tenant_id"] = tenant
    values["model_name"] = values["model_name"] or cfg.model_name
    values["model_alias"] = values["model_alias"] or cfg.model_alias
    try:
        storage.validate_job_uris(
            values["tenant_id"], values["input_uri"]
        )
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    try:
        row, duplicate = db.create_job(values, idempotency_key, resolve,
                                       request_id=request.headers.get("x-request-id", "")[:128],
                                       traceparent=request.headers.get("traceparent", "")[:128])
    except db.IdempotencyConflict as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except Exception as exc:
        LOGGER.warning("batch acceptance failed type=%s", type(exc).__name__)
        raise HTTPException(status_code=503, detail="batch acceptance unavailable") from exc
    job_id = str(row["job_id"])
    REQUESTS.labels("batches", "202").inc()
    return BatchAccepted(
        job_id=job_id,
        state=row["state"],
        status_url=f"/v1/batches/{job_id}",
        duplicate=duplicate,
    )


@app.get("/internal/v1/batches/{job_id}", response_model=BatchStatus)
def batch_status(job_id: UUID, tenant: str = Depends(tenant_id)) -> BatchStatus:
    row = db.get_job(str(job_id), tenant)
    if not row:
        raise HTTPException(status_code=404, detail="job not found")
    row["job_id"] = str(row["job_id"])
    for key in ("created_at", "started_at", "finished_at"):
        row[key] = row[key].isoformat() if row[key] else None
    return BatchStatus(**{field: row.get(field) for field in BatchStatus.model_fields})
