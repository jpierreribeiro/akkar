import json
import hashlib
import hmac
from io import BytesIO
from typing import Any
from urllib.parse import urlparse

import boto3

from .config import settings


def _client():
    cfg = settings()
    return boto3.client(
        "s3",
        endpoint_url=cfg.s3_endpoint_url,
        aws_access_key_id=cfg.s3_access_key.get_secret_value(),
        aws_secret_access_key=cfg.s3_secret_key.get_secret_value(),
        region_name=cfg.s3_region,
    )


def _split(uri: str, expected_bucket: str, tenant_id: str) -> tuple[str, str]:
    parsed = urlparse(uri)
    if parsed.scheme != "s3" or not parsed.netloc or not parsed.path.lstrip("/"):
        raise ValueError("only non-empty s3://bucket/key URIs are accepted")
    bucket, key = parsed.netloc, parsed.path.lstrip("/")
    if bucket != expected_bucket:
        raise ValueError(f"bucket must be {expected_bucket}")
    if not key.startswith(tenant_id + "/"):
        raise ValueError("object key must be scoped below the tenant prefix")
    return bucket, key


def validate_job_uris(tenant_id: str, input_uri: str) -> None:
    cfg = settings()
    _split(input_uri, cfg.input_bucket, tenant_id)


def read_jsonl(uri: str, tenant_id: str, version_id: str, sha256: str) -> list[dict[str, Any]]:
    cfg = settings()
    max_bytes = cfg.max_batch_input_bytes
    bucket, key = _split(uri, cfg.input_bucket, tenant_id)
    obj = _client().get_object(Bucket=bucket, Key=key, VersionId=version_id)
    try:
        if obj.get("VersionId") != version_id:
            raise ValueError("object version mismatch")
        size = int(obj.get("ContentLength", 0))
        if size > max_bytes:
            raise ValueError(f"input exceeds {max_bytes} bytes")
        data = obj["Body"].read(max_bytes + 1)
    finally:
        obj["Body"].close()
    if len(data) > max_bytes:
        raise ValueError(f"input exceeds {max_bytes} bytes")
    if not hmac.compare_digest(hashlib.sha256(data).hexdigest(), sha256):
        raise ValueError("input digest mismatch")
    rows = [json.loads(line) for line in data.splitlines() if line.strip()]
    if len(rows) > cfg.max_batch_rows:
        raise ValueError(f"input exceeds {cfg.max_batch_rows} rows")
    if not all(isinstance(row, dict) for row in rows):
        raise ValueError("each JSONL line must be an object")
    return rows


def write_jsonl(uri: str, tenant_id: str, rows: list[Any]) -> None:
    cfg = settings()
    bucket, key = _split(uri, cfg.output_bucket, tenant_id)
    payload = bytearray()
    for row in rows:
        payload.extend(json.dumps(row, separators=(",", ":"), default=str).encode())
        payload.extend(b"\n")
        if len(payload) > cfg.max_batch_output_bytes:
            raise ValueError(f"output exceeds {cfg.max_batch_output_bytes} bytes")
    _client().upload_fileobj(BytesIO(payload), bucket, key)
