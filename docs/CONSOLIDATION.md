# Technical consolidation — September 2026

Execution ledger, not production certification. Public Lua APIs stay compatible;
the MLOps example has documented breaking changes. Preserve existing edits.

Baseline: `6a1bb5b02b8257c5a8ada7e15e17e451d61ee37b` plus existing dirty tree.
Python baseline: 15 tests passed (`uv run --frozen pytest`). Lua baseline:
3,655 successes, no failures/errors/pending, 724.53 seconds, with
`eval "$(luarocks path)"` and `ulimit -n 8192`.

- [x] Baseline and active-vs-historical documentation reconciliation.
- [x] Server-to-server identity and tenant permissions.
- [x] Outbox, fenced leases, immutable model/input and bounded resources.
- [x] Controlled Linux substrate source installation using one CI manifest.
- [x] Private HTTP normalization/configuration extraction.
- [ ] Recovery tests, observability and local operational evidence.

External gates stay explicit: exact-commit CI, unavailable architectures,
24-hour soak, one-hour multiprocess, restore/rotation/rollback drills and repo
settings. No AWS requirement for local work. PR review is authorized; release
publication and production promotion are not part of this delivery.

## Evidence collected in this checkout

- Final full Lua run: 3,663 successes, zero failures/errors/pending; TAP plan
  `1..3663`, process exit 0. Log: `/tmp/akkar-pr-suite.tap`.
- First post-refactor full Lua run: 3,661 successes, zero failures, one error,
  zero pending. The error exposed a lazy-socket fixture readiness race in
  `spec/concurrency_spec.lua`; readiness now requires an actual HTTP response.
  Isolated concurrency run after correction: 7 successes, zero errors.
- Focused runtime/configuration/auth/packaging/allocation batch: 145 successes.
  Substrate manifest/doctor/packaging batch: 51 successes, zero errors.
- Controlled libraries through a non-shadowing test runner: 168 successes,
  zero failures/errors/pending. Fixture readiness + socket buffer: 14 successes.
  Final documentation links + concurrency batch: 221 successes, zero errors.
- Python unit/API, worker and real isolated-schema PostgreSQL recovery tests:
  39 passed, including legacy migration.
- Controlled installation in `/tmp/akkar-substrate.SQdEpz/runtime`: Lua 5.4.6,
  pinned cqueues, checked source archives, doctor successful from `/tmp`.
  Native Postgres driver remains optional and absent; OpenSSL is host-linked.
- Compose online + batch smoke: fixed input still processed after latest object
  overwrite; idempotent repeat; foreign tenant gets 404; one attempt succeeded.
- Live Lua gateway: authenticated online request 200, unauthenticated status 401.
- Final local restart smoke recovered dispatcher, Redis, worker, Postgres and
  API using exact container IDs, without restarting one-shot dependencies.
  A database dump restored into a fresh test database matched all 19 job rows.
  Log: `/tmp/akkar-consolidation-recovery-final.log`. This does not prove
  coordinated object-store recovery or every in-flight failure scenario.
- One-minute `/ping` smoke: 12 samples, no HTTP/socket errors, RSS 15,744 KiB
  throughout; request counter 15,413 → 200,654. DB disabled: this is a harness
  smoke, not production-shaped certification. TSV: `/tmp/akkar-consolidation-smoke.tsv`.
- Repeat one-minute smoke with persistent metadata and wrk output: 12 samples,
  RSS 15,872 KiB throughout, request counter 11,615 → 162,679, no HTTP/socket
  errors. Artifacts: `/tmp/akkar-consolidation-evidence-smoke.tsv`, `.tsv.meta`
  and `.tsv.wrk.txt`.

The active worktree is dirty; these are local execution results, not evidence
for a committed release SHA. The final full-suite log is stored under `/tmp`.
See [controlled installation boundaries](CONTROLLED-INSTALL.md) and the
[MLOps migration guide](../examples/mlops/README.md).
