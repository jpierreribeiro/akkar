import hashlib
from io import BytesIO
from types import SimpleNamespace

import pytest
from pydantic import ValidationError

from ml_service import storage, model_registry as registry
from ml_service.schemas import BatchRequest


def payload(**changes):
    return dict(input_uri="s3://ml-batch/acme/in.jsonl", input_version_id="v1",
                input_sha256="a" * 64, **changes)


@pytest.mark.parametrize("extra", [{"tenant_id": "other"}, {"output_uri": "s3://x/y"},
                                  {"parameters": {"ignored": True}}])
def test_rejects_legacy_or_unimplemented_fields(extra):
    with pytest.raises(ValidationError):
        BatchRequest(**payload(**extra))


def test_requires_real_object_version():
    values = payload()
    values["input_version_id"] = "null"
    with pytest.raises(ValidationError):
        BatchRequest(**values)


@pytest.mark.parametrize("failure", ["size", "digest", "version", None])
def test_input_version_digest_and_stream_cleanup(monkeypatch, failure):
    raw = b'{"x":1}\n'
    body = BytesIO(raw)
    seen = []

    def get(**kwargs):
        seen.append(kwargs)
        return {"Body": body, "ContentLength": 10**12 if failure == "size" else len(raw),
                "VersionId": "wrong" if failure == "version" else "v1"}

    monkeypatch.setattr(storage, "_client", lambda: SimpleNamespace(get_object=get))
    digest = "a" * 64 if failure == "digest" else hashlib.sha256(raw).hexdigest()
    if failure:
        with pytest.raises(ValueError):
            storage.read_jsonl("s3://ml-batch/acme/in.jsonl", "acme", "v1", digest)
    else:
        assert storage.read_jsonl("s3://ml-batch/acme/in.jsonl", "acme", "v1", digest) == [{"x": 1}]
    assert body.closed
    assert seen[0]["VersionId"] == "v1"


def test_cache_is_lru_and_digest_is_part_of_identity(monkeypatch):
    registry._models.clear()
    monkeypatch.setattr(registry.mlflow.artifacts, "download_artifacts", lambda **_: "/unused")
    monkeypatch.setattr(registry, "verify_safe_sklearn_artifact", lambda _: None)
    monkeypatch.setattr(registry, "artifact_digest", lambda _: "sha256:good")
    monkeypatch.setattr(registry.mlflow.sklearn, "load_model", lambda _: object())
    try:
        for version in ("1", "2", "1", "3"):
            registry.load_version("demo", version, "sha256:good", "/unused")
        assert [key[1] for key in registry._models] == ["1", "3"]
        with pytest.raises(RuntimeError, match="digest mismatch"):
            registry.load_version("demo", "1", "sha256:changed", "/unused")
    finally:
        registry._models.clear()


def test_refuses_additional_model_flavors(monkeypatch):
    monkeypatch.setattr(registry.Model, "load", lambda _: SimpleNamespace(flavors={
        "sklearn": {"serialization_format": "skops"}, "custom": {}}))
    with pytest.raises(RuntimeError, match="unexpected model flavor"):
        registry.verify_safe_sklearn_artifact("/unused")
