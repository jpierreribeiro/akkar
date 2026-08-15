# Benchmarks

Written to be run on a machine with real cores, not on a laptop sharing them
with a browser. Calibrated against an **AWS c5.2xlarge** (8 vCPU, 16 GB).

Nothing here runs in CI, and nothing here is a claim until someone runs it and
pastes the numbers into `RESULTS.md`.

## Why these three

The framework already has measurements for the things a unit test can pin:
parameter binding, pool concurrency, yield budgets. What a single machine
running one process cannot answer is the question that decides how akkar is
deployed:

> One Lua VM is one core. How well does N processes actually scale, and where
> does it stop?

That is the real answer to CPU-bound work, and it is only meaningful measured
across cores.

## Setup

```sh
export PATH="$HOME/.local/bin:$PATH"
eval "$(luarocks path --bin)"

docker run -d --name akkar-pg -e POSTGRES_PASSWORD=akkar \
  -e POSTGRES_DB=akkar -p 55432:5432 postgres:16-alpine
docker run -d --name akkar-redis -p 6379:6379 redis:7-alpine

docker exec -i akkar-pg psql -U postgres -d akkar <<'SQL'
create table if not exists users (
  id serial primary key, name text not null, email text, password_hash text);
insert into users (name, email) select 'user' || i, 'u' || i || '@example.com'
  from generate_series(1, 10000) i;
SQL
```

A load generator is needed. `wrk` is the assumption; `hey` or `oha` work with
small edits:

```sh
sudo apt-get install -y wrk    # or: cargo install oha
```

**Raise the file descriptor limit before measuring anything.** Hitting
`ulimit -n` looks exactly like the server falling over, and has cost more
benchmark afternoons than any real bug:

```sh
ulimit -n 65535
```

## 1. Throughput and latency — `bench/serve.lua`

```sh
lua5.4 bench/serve.lua                       # one process on :8300
wrk -t4 -c100 -d30s http://127.0.0.1:8300/ping
wrk -t4 -c100 -d30s http://127.0.0.1:8300/users/42
```

`/ping` measures the framework with nothing behind it. `/users/:id` measures
the realistic case, where the database dominates and the framework should be
noise. Comparing the two says how much of a real request akkar is responsible
for — if `/ping` is 20x faster, the framework is not the thing to optimise.

## 2. Multicore scaling — `bench/scale.sh`

```sh
bash bench/scale.sh 1 2 4 8
```

Starts N processes behind `SO_REUSEPORT` on the same port, runs the same load
against each configuration, and prints requests per second per N.

What to look for, and what each answer means:

- **Near-linear to 8** — the deployment story is "run one process per core",
  and CPU-bound work is a capacity question rather than an architecture one.
- **Flattening at 4** — something shared is the bottleneck. Check the Postgres
  connection count first: N processes times `pool_size` is easy to push past
  `max_connections`, and then the limit is the database, not akkar.
- **Worse than linear from the start** — the load generator or the loopback is
  saturated, not the server. Rerun with the generator on another host before
  believing it.

## 3. Blocking under load — `bench/blocking.lua`

The measurement that matters most, and the one a unit test cannot make.

```sh
lua5.4 bench/blocking.lua 1     # one process
wrk -t4 -c100 -d30s http://127.0.0.1:8300/ping    # in another shell
# then, in a third: curl http://127.0.0.1:8300/expensive
```

`/expensive` burns ~250 ms of CPU, the way `bcrypt` at cost 12 does. Watch what
happens to `/ping` p99 while it runs, then repeat with 8 processes.

The expected shape: with one process, one blocking call stalls everything for
250 ms. With eight, it stalls one eighth of capacity. **That is the honest
answer to CPU-bound work in a single-threaded runtime** — not a helper, but
enough processes that one blocked worker is a fraction rather than the whole.

`bench/blocking.lua` also serves `/expensive-yielding`, the same work wrapped
in `work.yielding`. Comparing the two under load shows the trade already
measured in isolation: neighbour latency collapses, the task itself gets
roughly 2.7x slower.

## Recording results

Paste output into `bench/RESULTS.md` with the instance type, the date and the
`wrk` command. A number without the machine it came from is not a result.
