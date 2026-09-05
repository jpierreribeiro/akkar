# Python/MLOps beside akkar

Python runs in a private process, never inside the Lua VM. This example is a
production candidate, not a certified deployment. Lua contracts are unchanged;
the public batch request has breaking changes documented below.

## Local stack and credentials

Run `docker compose up --build` in this directory after setting secrets from
`.env.example`. The fixture starts Postgres, Redis, versioned MinIO, MLflow,
a stopped-worker migration, model bootstrap, FastAPI, Celery and an outbox
dispatcher. Bootstrap promotes a demonstration model: never run it in production.

From the repository root, generate a client key once:

```sh
lua -e 'local k,h=require("akkar.auth").generate_key("ml"); print("KEY="..k); print("HASH="..h)'
```

Store only the hash in a private JSON credential file:

```json
[
  {
    "hash": "REPLACE_WITH_64_CHARACTER_SHA256_HASH",
    "tenant_id": "acme",
    "permissions": ["predict", "batch:submit", "batch:read"],
    "models": ["akkar-reference"]
  }
]
```

Start `lua examples/mlops/gateway.lua` from the repository root with
`ML_SERVICE_URL=http://127.0.0.1:8000`, `ML_INTERNAL_TOKEN` and
`ML_CLIENT_KEYS_FILE` set. The gateway defaults to loopback:8080; use `PORT`
to avoid a local conflict. Externally expose it only behind TLS. Keep Python,
MLflow, Redis, Postgres and object storage private.

Every public request needs `X-API-Key`. Identity and model allowlists are
checked before forwarding. A missing/revoked key returns 401; insufficient
permissions or a forbidden model returns 403. Do not send `tenant_id`: it is
derived from the credential and a payload containing it is rejected.

For rotation, deploy a credential file containing old and new hashes for the
same tenant, restart the gateway gracefully, migrate callers, remove the old
entry and restart again. There is no unauthenticated administration endpoint.

## Online and batch contracts

`POST /v1/predictions` accepts `inputs`, optional `model_name` and
`model_alias`. It returns predictions, resolved model version and digest.

`POST /v1/batches` requires `Idempotency-Key` and this body:

```json
{
  "input_uri": "s3://ml-batch/acme/input.jsonl",
  "input_version_id": "VERSION_RETURNED_BY_S3_PUT_OBJECT",
  "input_sha256": "SHA256_OF_EXACT_JSONL_BYTES"
}
```

An actual 64-character lowercase hex digest is required. The input must be
under the authenticated tenant's prefix in the configured bucket; the S3
version cannot be `null`. Optional `model_name` and `model_alias` select
an allowed model. Nonempty `parameters` is rejected, not silently ignored.

Acceptance returns 202 and a public `status_url`. The tenant-scoped status
endpoint returns 404 for another tenant's job. `output_uri` is null until the
winning attempt commits; output locations are generated, not caller-supplied.

A repeated key with the same intent only observes the original job, including
terminal failures. It does not resolve the alias again or enqueue another job.
A different intent with that key returns 409. Retry a terminal failure with a
new key. Model version, source and digest are fixed at acceptance; input
version and digest are verified before inference.

## Recovery semantics

Job and outbox are one Postgres transaction. The dispatcher polls every second,
publishes pending intents, and reconciles messages not claimed within 60 seconds.
Broker publication is at-least-once: a crash after publication can duplicate it.

Each claim has a fresh ownership token and a 60-second lease, renewed every
15 seconds. At most five execution attempts are admitted. Expired owners cannot
renew, fail or finish a newer attempt. Output uses a unique job/attempt key;
an upload abandoned before database commit is an orphan, never the visible
result. Only the winning URI is exposed. This is not exactly-once physical
execution and does not authorize arbitrary external side effects in workers.

Models use sklearn/skops only, digest verification, no packaged Python code,
a two-entry process-local LRU and temporary download directories. Python code
execution and hostile-model OS isolation are outside this example's trust boundary.

## Migrating an earlier example

Stop API, dispatcher and workers; back up the database; run
`docker compose run --rm migrate`; then start the new services. Do not run a
rolling mixed-version upgrade. Add client credentials and update batch callers
to remove `tenant_id`/`output_uri` and provide version/digest.

Migration is repeatable, preserves terminal jobs and marks older nonterminal
jobs lacking immutable metadata as failed. Resubmit those with new keys.
Enable bucket versioning before accepting new batches. After an incompatible
schema/client update, rollback requires the matching database backup and old
application, not merely an image change.

## Validation and operations

```sh
uv sync --frozen
uv run --frozen pytest
# Also set ML_TEST_DATABASE_URL to a disposable Postgres for recovery tests.
uv run --frozen python -m compileall -q ml_service bootstrap.py smoke.py
docker compose config --quiet
docker compose exec api /app/.venv/bin/python smoke.py
```

Postgres tests create and remove only unique test-owned schemas. Without
`ML_TEST_DATABASE_URL` they explicitly skip; CI provides Postgres and executes
them. The smoke uploads a versioned input, submits/observes a batch, verifies
its output, and checks cross-tenant refusal. It leaves its own prefixed records
and objects for evidence inspection.

For an explicitly disposable project named `akkar-consolidation-...`, run
`uv run --frozen python recovery.py PROJECT_NAME`. It verifies container
ownership before restarting anything, tests delayed dispatch/recovery and
restores a Postgres dump into a unique temporary database. It removes only
that restored test database. A database-only restore is not proof of joint
database/object-store disaster recovery.

`/live`, `/ready` and `/metrics` are private operational endpoints.
Metrics include outbox age/backlog, stalled/running/failed jobs and retained
retry counts. Labels never include job or tenant IDs. Logs carry job, request
and attempt correlation. Import `observability/dashboard.json` and load
`observability/alerts.yml` into your existing monitoring; these files alone
do not prove an alert was delivered.

Use least-privilege serving credentials and a separate registry writer. Configure
timeouts, container CPU/memory/process limits, TLS, backup/restore and artifact
scanning before production. Stale unreferenced attempt objects need an operator
retention policy; do not apply a blanket lifecycle deletion to successful output.
The full operational gate remains in `docs/PRODUCTION-READINESS.md`.
