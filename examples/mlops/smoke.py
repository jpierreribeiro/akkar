"""Local Compose evidence: only writes its own unique tenant-prefixed objects."""
import hashlib
import json
import os
import time
import uuid
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from ml_service.config import settings
from ml_service import storage


def main() -> None:
    cfg = settings()
    base = os.getenv("SMOKE_API_URL", "http://api:8000")
    key = "smoke-" + uuid.uuid4().hex
    tenant = "acme"

    def call(path, body=None, who=tenant):
        headers = {"authorization": "Bearer " + cfg.internal_token.get_secret_value(),
                   "x-tenant-id": who, "idempotency-key": key,
                   "content-type": "application/json"}
        request = Request(base + path, data=None if body is None else json.dumps(body).encode(),
                          headers=headers)
        with urlopen(request, timeout=15) as response:
            return json.load(response)

    rows = [{"sepal length (cm)": 5.1, "sepal width (cm)": 3.5,
             "petal length (cm)": 1.4, "petal width (cm)": 0.2}]
    online = call("/internal/v1/predictions", {"inputs": rows})
    assert len(online["outputs"]) == 1
    raw = (json.dumps(rows[0]) + "\n").encode()
    object_key = f"{tenant}/{key}/input.jsonl"
    s3 = storage._client()
    put = s3.put_object(Bucket=cfg.input_bucket, Key=object_key, Body=raw)
    payload = {"input_uri": f"s3://{cfg.input_bucket}/{object_key}",
               "input_version_id": put["VersionId"],
               "input_sha256": hashlib.sha256(raw).hexdigest()}
    accepted = call("/internal/v1/batches", payload)
    duplicate = call("/internal/v1/batches", payload)
    assert duplicate["duplicate"] and duplicate["job_id"] == accepted["job_id"]
    # Overwrite latest: the worker must continue to read the accepted version.
    s3.put_object(Bucket=cfg.input_bucket, Key=object_key, Body=b"invalid replacement\n")
    status_path = "/internal/v1/batches/" + accepted["job_id"]
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        state = call(status_path)
        if state["state"] in {"failed", "succeeded"}:
            break
        time.sleep(1)
    assert state["state"] == "succeeded", state
    bucket, output_key = storage._split(state["output_uri"], cfg.output_bucket, tenant)
    result = s3.get_object(Bucket=bucket, Key=output_key)
    try:
        assert len(result["Body"].read().splitlines()) == 1
    finally:
        result["Body"].close()
    try:
        call(status_path, who="other")
        raise AssertionError("cross-tenant status was exposed")
    except HTTPError as exc:
        assert exc.code == 404
    print(json.dumps({"ok": True, "job_id": accepted["job_id"],
                      "model_version": state["model_version"],
                      "attempts": state["attempts"]}))


if __name__ == "__main__":
    main()
