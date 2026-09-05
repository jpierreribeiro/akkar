from datetime import UTC, datetime
from types import SimpleNamespace
from uuid import UUID

from fastapi.testclient import TestClient

import ml_service.app as service


def client(monkeypatch) -> TestClient:
    monkeypatch.setattr(service.db, "ping", lambda: None)
    monkeypatch.setattr(service, "load", lambda name, alias: None)
    return TestClient(service.app)


def auth() -> dict[str, str]:
    token = service.settings().internal_token.get_secret_value()
    return {"authorization": f"Bearer {token}", "x-tenant-id": "acme"}


def test_internal_routes_require_authentication(monkeypatch):
    with client(monkeypatch) as api:
        response = api.post("/internal/v1/predictions", json={"inputs": [{"x": 1}]})
    assert response.status_code == 401


def test_prediction_contract_includes_resolved_model(monkeypatch):
    loaded = SimpleNamespace(version="7", digest="sha256:abc")
    monkeypatch.setattr(service, "predict", lambda name, alias, rows: ([1], loaded))
    with client(monkeypatch) as api:
        response = api.post(
            "/internal/v1/predictions",
            headers=auth(),
            json={"model_name": "risk", "model_alias": "champion", "inputs": [{"x": 1}]},
        )
    assert response.status_code == 200
    assert response.json() == {
        "model_name": "risk",
        "model_version": "7",
        "model_digest": "sha256:abc",
        "outputs": [1],
    }


def test_batch_is_idempotent(monkeypatch):
    row = {"job_id": "5d7eb4bd-bba1-4a14-aee8-76f5709c2438", "state": "queued"}
    monkeypatch.setattr(service.db, "create_job", lambda payload, key, *args, **kwargs: (row, True))
    with client(monkeypatch) as api:
        response = api.post(
            "/internal/v1/batches",
            headers={**auth(), "idempotency-key": "same-operation"},
            json={
                "input_uri": "s3://ml-batch/acme/in.jsonl",
                "input_version_id": "version-1",
                "input_sha256": "a" * 64,
            },
        )
    assert response.status_code == 202
    assert response.json()["duplicate"] is True
    assert response.json()["status_url"].startswith("/v1/batches/")


def test_unknown_fields_are_refused(monkeypatch):
    with client(monkeypatch) as api:
        response = api.post(
            "/internal/v1/predictions",
            headers=auth(),
            json={"inputs": [{"x": 1}], "python_code": "import os"},
        )
    assert response.status_code == 422


def test_declared_oversized_body_is_refused_before_parsing(monkeypatch):
    with client(monkeypatch) as api:
        response = api.post(
            "/internal/v1/predictions",
            headers={**auth(), "content-length": str(service.settings().max_body_bytes + 1)},
            content=b"{}",
        )
    assert response.status_code == 413


def test_batch_status_only_exposes_contract_fields(monkeypatch):
    row = {
        "job_id": UUID("5d7eb4bd-bba1-4a14-aee8-76f5709c2438"),
        "tenant_id": "acme",
        "idempotency_key": "secret-internal-key",
        "state": "queued",
        "attempts": 0,
        "model_name": "iris",
        "model_alias": "champion",
        "model_version": None,
        "model_digest": None,
        "input_uri": "s3://ml-batch/acme/in.jsonl",
        "output_uri": "s3://ml-batch/acme/out.jsonl",
        "parameters": {},
        "error": None,
        "created_at": datetime.now(UTC),
        "started_at": None,
        "finished_at": None,
    }
    monkeypatch.setattr(service.db, "get_job", lambda _, tenant: row if tenant == "acme" else None)
    with client(monkeypatch) as api:
        response = api.get(
            f"/internal/v1/batches/{row['job_id']}",
            headers=auth(),
        )
    assert response.status_code == 200
    assert "idempotency_key" not in response.json()
    assert "parameters" not in response.json()
    assert response.json()["job_id"] == str(row["job_id"])


def test_batch_status_rejects_a_malformed_job_id(monkeypatch):
    with client(monkeypatch) as api:
        response = api.get("/internal/v1/batches/not-a-uuid", headers=auth())
    assert response.status_code == 422


def test_batch_status_is_scoped_to_authenticated_tenant(monkeypatch):
    seen = []
    def get(job_id, tenant):
        seen.append(tenant)
        return None
    monkeypatch.setattr(service.db, "get_job", get)
    with client(monkeypatch) as api:
        response = api.get("/internal/v1/batches/5d7eb4bd-bba1-4a14-aee8-76f5709c2438",
                           headers={**auth(), "x-tenant-id": "other"})
    assert response.status_code == 404
    assert seen == ["other"]


def test_internal_identity_requires_service_auth(monkeypatch):
    with client(monkeypatch) as api:
        response = api.post("/internal/v1/predictions", headers={"x-tenant-id": "acme"},
                            json={"inputs": [{"x": 1}]})
    assert response.status_code == 401


def test_failed_idempotent_batch_is_observed_without_requeue(monkeypatch):
    row = {"job_id": "5d7eb4bd-bba1-4a14-aee8-76f5709c2438", "state": "failed"}
    monkeypatch.setattr(service.db, "create_job", lambda payload, key, *args, **kwargs: (row, True))
    with client(monkeypatch) as api:
        response = api.post(
            "/internal/v1/batches",
            headers={**auth(), "idempotency-key": "retry-failed"},
            json={
                "input_uri": "s3://ml-batch/acme/in.jsonl",
                "input_version_id": "version-1",
                "input_sha256": "a" * 64,
            },
        )
    assert response.status_code == 202
    assert response.json()["state"] == "failed"


def test_batch_refuses_cross_tenant_object_keys(monkeypatch):
    with client(monkeypatch) as api:
        response = api.post(
            "/internal/v1/batches",
            headers={**auth(), "idempotency-key": "cross-tenant"},
            json={
                "input_uri": "s3://ml-batch/other/in.jsonl",
                "input_version_id": "version-1",
                "input_sha256": "a" * 64,
            },
        )
    assert response.status_code == 422
