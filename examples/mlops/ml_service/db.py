import hashlib
import json
import uuid
from pathlib import Path
from typing import Any, Callable

import psycopg
from psycopg.rows import dict_row

from .config import settings

LEASE_SECONDS = 60
MAX_ATTEMPTS = 5


class IdempotencyConflict(Exception):
    pass


def _request_digest(payload: dict[str, Any]) -> str:
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(canonical.encode()).hexdigest()


def connect() -> psycopg.Connection[Any]:
    return psycopg.connect(settings().database_url, row_factory=dict_row,
                           connect_timeout=5, options="-c statement_timeout=10000")


def migrate() -> None:
    sql = (Path(__file__).parent.parent / "schema.sql").read_text()
    with connect() as conn:
        conn.execute(sql)


def ping() -> None:
    with connect() as conn:
        conn.execute("select 1").fetchone()


def create_job(payload: dict[str, Any], idempotency_key: str,
               resolve: Callable[..., dict[str, str]], *,
               request_id: str | None = None, traceparent: str | None = None
               ) -> tuple[dict[str, Any], bool]:
    digest = _request_digest(payload)
    tenant = payload["tenant_id"]
    with connect() as conn:
        # Serializes acceptance of this identity, including alias resolution.
        # The original intent digest excludes the resolved model so retries do
        # not change identity after an alias promotion.
        conn.execute("select pg_advisory_xact_lock(hashtextextended(%s, 0))",
                     (json.dumps([tenant, idempotency_key]),))
        existing = conn.execute(
            "select * from ml_batch_jobs where tenant_id=%s and idempotency_key=%s",
            (tenant, idempotency_key),
        ).fetchone()
        if existing:
            if existing["request_digest"] != digest:
                raise IdempotencyConflict("idempotency key was already used for another request")
            return dict(existing), True
        model = resolve(payload["model_name"], payload["model_alias"])
        job_id = str(uuid.uuid4())
        row = conn.execute(
            """insert into ml_batch_jobs
               (job_id, tenant_id, idempotency_key, request_digest, model_name, model_alias,
                input_uri, input_version_id, input_sha256, model_version, model_digest,
                model_source, state, request_id, traceparent)
               values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,'queued',%s,%s)
               returning *""",
            (job_id, tenant, idempotency_key, digest, payload["model_name"],
             payload["model_alias"], payload["input_uri"], payload["input_version_id"],
             payload["input_sha256"], model["model_version"], model["model_digest"],
             model["model_source"], request_id, traceparent),
        ).fetchone()
        conn.execute("insert into ml_batch_outbox(job_id) values (%s)", (job_id,))
        assert row
        return dict(row), False


def get_job(job_id: str, tenant_id: str) -> dict[str, Any] | None:
    with connect() as conn:
        row = conn.execute(
            "select * from ml_batch_jobs where job_id=%s and tenant_id=%s",
            (job_id, tenant_id),
        ).fetchone()
        return dict(row) if row else None


def claim_job(job_id: str, claim_token: str) -> dict[str, Any] | None:
    with connect() as conn:
        row = conn.execute(
            """update ml_batch_jobs set state='running', attempts=attempts+1,
               started_at=clock_timestamp(), error=null, claim_token=%s,
               lease_until=clock_timestamp()+make_interval(secs => %s)
               where job_id=%s and state='queued' and attempts < %s returning *""",
            (claim_token, LEASE_SECONDS, job_id, MAX_ATTEMPTS),
        ).fetchone()
        return dict(row) if row else None


def heartbeat(job_id: str, token: str) -> bool:
    with connect() as conn:
        return conn.execute(
            """update ml_batch_jobs
               set lease_until=clock_timestamp()+make_interval(secs => %s)
               where job_id=%s and claim_token=%s and state='running'
                 and lease_until > clock_timestamp()""",
            (LEASE_SECONDS, job_id, token),
        ).rowcount == 1


def mark_succeeded(job_id: str, token: str, output_uri: str) -> bool:
    with connect() as conn:
        return conn.execute(
            """update ml_batch_jobs set state='succeeded', output_uri=%s,
               finished_at=clock_timestamp(), error=null, claim_token=null, lease_until=null
               where job_id=%s and claim_token=%s and state='running'
                 and lease_until > clock_timestamp()""",
            (output_uri, job_id, token),
        ).rowcount == 1


def mark_failed(job_id: str, token: str, error: str, retryable: bool = False) -> bool:
    with connect() as conn:
        row = conn.execute(
            """update ml_batch_jobs
               set state=case when %s and attempts < %s then 'queued' else 'failed' end,
                   finished_at=case when %s and attempts < %s then null else clock_timestamp() end,
                   error=%s, claim_token=null, lease_until=null
               where job_id=%s and claim_token=%s and state='running'
                 and lease_until > clock_timestamp()
               returning state""",
            (retryable, MAX_ATTEMPTS, retryable, MAX_ATTEMPTS, error[:512], job_id, token),
        ).fetchone()
        if row and row["state"] == "queued":
            conn.execute(
                "update ml_batch_outbox set dispatched_at=null, created_at=clock_timestamp() where job_id=%s",
                (job_id,),
            )
        return row is not None


def reconcile() -> None:
    with connect() as conn:
        conn.execute(
            """update ml_batch_jobs
               set state=case when attempts < %s then 'queued' else 'failed' end,
                   finished_at=case when attempts < %s then null else clock_timestamp() end,
                   error='worker lease expired', claim_token=null, lease_until=null
               where state='running' and lease_until <= clock_timestamp()""",
            (MAX_ATTEMPTS, MAX_ATTEMPTS),
        )
        conn.execute(
            """update ml_batch_outbox o set dispatched_at=null
               from ml_batch_jobs j where j.job_id=o.job_id and j.state='queued'
                 and o.dispatched_at < clock_timestamp()-interval '60 seconds'"""
        )


def dispatch_one(publish: Callable[[str], Any]) -> bool:
    # Publish while holding only an outbox lock, never a job-row lock.
    # Crash after publication rolls back the ack and causes safe redelivery.
    with connect() as conn:
        row = conn.execute(
            """select o.job_id from ml_batch_outbox o join ml_batch_jobs j using(job_id)
               where o.dispatched_at is null and j.state='queued'
               order by o.created_at for update of o skip locked limit 1"""
        ).fetchone()
        if not row:
            return False
        publish(str(row["job_id"]))
        conn.execute("update ml_batch_outbox set dispatched_at=clock_timestamp() where job_id=%s",
                     (row["job_id"],))
        return True


def queue_metrics() -> dict[str, float]:
    with connect() as conn:
        row = conn.execute(
            """select count(*) as pending,
               coalesce(max(extract(epoch from clock_timestamp()-o.created_at)),0) as oldest
               from ml_batch_outbox o join ml_batch_jobs j using(job_id)
               where o.dispatched_at is null and j.state='queued'"""
        ).fetchone()
        stalled = conn.execute(
            """select count(*) as n from ml_batch_jobs where
               (state='running' and lease_until <= clock_timestamp()) or
               (state='queued' and created_at < clock_timestamp()-interval '60 seconds')"""
        ).fetchone()
        totals = conn.execute(
            """select coalesce(sum(greatest(attempts-1,0)),0) as retries,
               count(*) filter(where state='failed') as failed,
               count(*) filter(where state='running') as running
               from ml_batch_jobs"""
        ).fetchone()
        return {"pending": float(row["pending"]), "oldest": float(row["oldest"]),
                "stalled": float(stalled["n"]), "retries": float(totals["retries"]),
                "failed": float(totals["failed"]), "running": float(totals["running"])}
