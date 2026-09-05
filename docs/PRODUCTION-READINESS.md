# Production readiness gate

akkar is a **production candidate**, not yet a publicly certified production
runtime. The code-level controls below are implemented and automated. The
environmental evidence must be produced for each release candidate; it cannot
be inferred from unit tests or from an unavailable AWS VM.

## Configured automation (verify the exact commit's CI result)

- Lua 5.4 is configured on Linux x86-64, Linux ARM64, and macOS ARM64; Lua 5.5 has its
  own source-built job. PostgreSQL/Redis integration and clean LuaRocks install
  are separate required jobs.
- The Python/MLOps example recreates its committed `uv.lock`, tests strict API,
  tenancy, idempotency, body limits, and safe model-artifact policy, then
  validates its Compose manifest.
- Incoming bodies are capped at 1 MiB, aggregate headers at 32 KiB and 100
  fields, JSON at 64 nested arrays/objects, with absolute read/write/request
  deadlines. HTTP/2 enforces the limit after HPACK expansion.
- GitHub Actions are pinned to commit SHAs, workflow permissions are explicit,
  CODEOWNERS and private security reporting policy exist, and Dependabot covers
  Actions, Python, and Docker inputs.
- A manual release workflow accepts only an existing semantic-version tag whose
  commit has successful CI. It generates/lints release rockspecs, archives the
  exact tag, publishes the locked MLOps image, produces SPDX SBOMs, SHA-256
  checksums and GitHub provenance attestations, then creates the GitHub release.

## Evidence required before public critical production

All rows are blocking. A cancelled job is not a pass.

| Gate | Acceptance evidence |
|---|---|
| CI | Every job green on the exact release commit, twice: pull request and `main` |
| ARM regression | 20 consecutive no-service suites on Linux ARM64; no crash, cancellation, or unexplained pending |
| Local soak | 24 hours, one process, production-shaped payload, `SOAK_ASSERT=1`; no HTTP/socket errors and memory drift inside the recorded threshold |
| Multi-process smoke | At least one hour with the intended process count and `reuseport`; every PID remains alive and traffic is distributed |
| Dependency loss | During load, stop/restart Postgres, Redis, and the Python model service; bounded 5xx, breaker opens, recovery occurs without process restart |
| Graceful deploy | Send SIGTERM under load; listeners stop accepting, in-flight work drains inside `shutdown_grace`, no duplicate batch side effect |
| Data recovery | Restore PostgreSQL and object-store backups into an empty environment and serve a verified model from the restored registry |
| Observability | Dashboards and alerts exercise request errors/latency, saturation, queue depth, worker failures, dropped telemetry, and readiness |
| Security | Secret rotation drill, private vulnerability-report path verified, container/model scan reviewed, least-privilege credentials documented |
| Rollback | Roll back both runtime image and MLflow `champion` alias to their previous immutable digest within the operational target |

Run the assertive soak locally, without AWS:

```sh
SOAK_ASSERT=1 \
MAX_RSS_GROWTH_PERCENT=20 MAX_RSS_GROWTH_KB=131072 \
MAX_HEAP_GROWTH_PERCENT=20 MAX_HEAP_GROWTH_KB=32768 \
bash bench/soak.sh 1440 1
```

The TSV, load-generator output, commit SHA, OS/kernel/libc, Lua and cqueues
versions, CPU/RAM, and threshold values are release evidence. Do not replace a
missing 24-hour run with a short benchmark; they answer different questions.

## Repository settings still applied outside the tree

Before calling the project production-ready, configure the `main` branch to
require pull requests, CODEOWNERS review, conversation resolution, linear
history, and all CI job checks; disallow force-push and deletion. Enable
Dependabot security updates and GitHub private vulnerability reporting in the
repository settings. These controls are intentionally not changed by source
code because doing so can lock out the sole maintainer.

Protect the `release` GitHub environment with maintainer approval. Keep the
LuaRocks API key in that environment only; the workflow deliberately stops at
GitHub/GHCR because `luarocks upload` is irreversible and requires a maintainer
credential. Upload the main rock first and `akkar-pq` second, following
[`RELEASE.md`](../RELEASE.md).

## Python boundary

[`examples/mlops/`](../examples/mlops/) is the supported pattern: a private,
independently limited service. `akkar.vm` is not an OS sandbox, and embedding
CPython or accepting arbitrary Python source is outside the production trust
boundary. The training pipeline is the only writer to MLflow; serving accepts
an immutable version only after digest verification and a `skops`-only flavor
  check. The example gateway authenticates server-to-server API keys and derives
tenant identity and permissions from a private credential file. Batch status is
tenant-scoped; jobs use an outbox, fenced leases and immutable model/input
metadata. See the [migration and operating guide](../examples/mlops/README.md).
These controls do not establish the operational gates above; see
[current evidence](CONSOLIDATION.md).
