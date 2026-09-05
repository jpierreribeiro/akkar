"""Real PostgreSQL tests. Each test owns a fresh, explicitly named schema."""
import os
import uuid
from concurrent.futures import ThreadPoolExecutor

import psycopg
from psycopg import sql
from psycopg.rows import dict_row
import pytest

from ml_service import db


@pytest.fixture(autouse=True)
def database(monkeypatch):
    dsn = os.getenv("ML_TEST_DATABASE_URL")
    if not dsn:
        pytest.skip("ML_TEST_DATABASE_URL required for real PostgreSQL recovery tests")
    schema = "akkar_consolidation_" + uuid.uuid4().hex
    with psycopg.connect(dsn, autocommit=True) as conn:
        conn.execute(sql.SQL("create schema {}").format(sql.Identifier(schema)))
    monkeypatch.setattr(db, "connect", lambda: psycopg.connect(
        dsn, row_factory=dict_row, connect_timeout=5,
        options=f"-c search_path={schema} -c statement_timeout=10000"))
    db.migrate()
    try:
        yield
    finally:
        # Only this test's generated schema, never public or an existing schema.
        with psycopg.connect(dsn, autocommit=True) as conn:
            conn.execute(sql.SQL("drop schema {} cascade").format(sql.Identifier(schema)))


def create(key="key", **changes):
    values = dict(tenant_id="acme", model_name="demo", model_alias="champion",
                  input_uri="s3://ml-batch/acme/in", input_version_id="v1",
                  input_sha256="a" * 64, parameters={})
    values.update(changes)
    return db.create_job(values, key, lambda *_: {
        "model_version": "1", "model_digest": "sha256:abc", "model_source": "s3://models/v1"})


def expire(job_id):
    with db.connect() as conn:
        conn.execute("update ml_batch_jobs set lease_until=clock_timestamp()-interval '1 second' where job_id=%s", (job_id,))


def test_acceptance_and_outbox_are_atomic():
    with db.connect() as conn:
        conn.execute("alter table ml_batch_outbox add constraint deny_insert check(false)")
    with pytest.raises(psycopg.errors.CheckViolation):
        create()
    with db.connect() as conn:
        assert conn.execute("select count(*) as n from ml_batch_jobs").fetchone()["n"] == 0


def test_failed_publish_is_retried_and_success_can_be_redelivered():
    row, _ = create()
    published = []

    def crash_after_publish(job):
        published.append(job)
        raise ConnectionError("lost acknowledgement")

    with pytest.raises(ConnectionError):
        db.dispatch_one(crash_after_publish)
    assert db.dispatch_one(published.append)
    assert published == [str(row["job_id"])] * 2
    assert not db.dispatch_one(published.append)
    assert db.claim_job(str(row["job_id"]), "owner")
    assert db.claim_job(str(row["job_id"]), "duplicate") is None


def test_lost_broker_message_is_reconciled():
    row, _ = create()
    db.dispatch_one(lambda _: None)
    with db.connect() as conn:
        conn.execute("update ml_batch_outbox set dispatched_at=clock_timestamp()-interval '61 seconds'")
    db.reconcile()
    sent = []
    assert db.dispatch_one(sent.append)
    assert sent == [str(row["job_id"])]


def test_expired_owner_cannot_heartbeat_finish_or_publish_a_result():
    row, _ = create()
    job = str(row["job_id"])
    assert db.claim_job(job, "old")
    expire(job)
    assert not db.heartbeat(job, "old")
    assert not db.mark_succeeded(job, "old", "s3://orphan")
    db.reconcile()
    assert db.claim_job(job, "new")
    assert not db.mark_failed(job, "old", "late failure")
    assert db.mark_succeeded(job, "new", "s3://winner")
    result = db.get_job(job, "acme")
    assert result["output_uri"] == "s3://winner"
    assert result["attempts"] == 2
    assert db.get_job(job, "other") is None


def test_attempts_are_bounded_and_failed_duplicate_is_observation_only():
    row, _ = create()
    job = str(row["job_id"])
    for attempt in range(5):
        assert db.claim_job(job, str(attempt))
        assert db.mark_failed(job, str(attempt), "transient", retryable=True)
    assert db.claim_job(job, "sixth") is None
    duplicate, is_duplicate = create()
    assert is_duplicate and duplicate["state"] == "failed"


def test_concurrent_acceptance_resolves_once_and_preserves_model_after_promotion():
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: create(), range(2)))
    assert sorted(duplicate for _, duplicate in results) == [False, True]
    assert results[0][0]["job_id"] == results[1][0]["job_id"]
    values = dict(tenant_id="acme", model_name="demo", model_alias="champion",
                  input_uri="s3://ml-batch/acme/in", input_version_id="v1",
                  input_sha256="a" * 64, parameters={})
    def should_not_resolve(*_):
        raise AssertionError("alias resolved again")
    row, duplicate = db.create_job(values, "key", should_not_resolve)
    assert duplicate and row["model_version"] == "1"
    with pytest.raises(db.IdempotencyConflict):
        create(input_version_id="v2")


def test_migration_is_repeatable_and_preserves_new_jobs():
    row, _ = create()
    db.migrate()
    assert db.get_job(str(row["job_id"]), "acme")["state"] == "queued"


def test_two_deliveries_only_one_claim():
    row, _ = create()
    with ThreadPoolExecutor(max_workers=2) as pool:
        claims = list(pool.map(lambda token: db.claim_job(str(row["job_id"]), token), ["a", "b"]))
    assert sum(claim is not None for claim in claims) == 1


def test_legacy_nonterminal_jobs_fail_without_rewriting_terminal_history():
    with db.connect() as conn:
        for state in ("queued", "running", "succeeded", "failed"):
            conn.execute("""insert into ml_batch_jobs
                (job_id,tenant_id,idempotency_key,request_digest,model_name,model_alias,input_uri,state)
                values (%s,'legacy',%s,'legacy:digest','demo','champion','s3://ml-batch/legacy/in',%s)""",
                (str(uuid.uuid4()), state, state))
    db.migrate()
    with db.connect() as conn:
        rows = conn.execute("select * from ml_batch_jobs where tenant_id='legacy'").fetchall()
    states = {row["idempotency_key"]: row["state"] for row in rows}
    assert states == {"queued": "failed", "running": "failed", "succeeded": "succeeded", "failed": "failed"}
