# Certifying a performance patch

Three tools, because a performance change needs three different kinds of
evidence and they are not interchangeable.

The reason this exists: an earlier project of the owner's proved **twice** that
a symbol's share of a profile is not the gain from removing it. Pre-sizing a
buffer held 10.7% of that profile and delivered **−2.6%** of ceiling. An RTTI
cache held 6.86% and **regressed p99 by 17.8%**. Both looked obviously right
beforehand. So nothing here is certified by reasoning about where the time
goes.

## `alloc.lua` — where a regression assertion can live

```sh
lua5.4 bench/certify/alloc.lua [akkar_dir]
```

Bytes allocated per request, with the collector stopped so the number is total
allocation rather than retained memory. **Deterministic**: the same tree gives
the same numbers on a laptop and on a c5.2xlarge, verified. That is what makes
it a gate — a rise after a patch is a regression with no noise floor to hide
behind.

It reports four groups, because the in-process client does not serialise and a
first version of this file was blind to exactly the axis it was pointed at:

| group | what it includes |
|---|---|
| dispatch only | the framework, payload-independent |
| dispatch + response encode | what the socket path adds outbound |
| request decode alone | what the socket path adds inbound |
| decode + dispatch | the full inbound path |

A falling number is **not** automatically faster. Certify time separately.

## `ab.sh` — end-to-end, and it refuses to call noise a result

```sh
git worktree add /tmp/akkar-base HEAD~1
PORT=8720 bash bench/certify/ab.sh /tmp/akkar-base . /rows/50
```

Both variants run **side by side on two ports** for the whole session, and the
generator alternates between them. Restarting a server between repetitions
makes every measurement a cold start, and the first version of this harness
spent its runs reporting timeouts from exactly that. Side by side, the two also
meet identical machine conditions at the same instant.

What it refuses to do:

- measure when a port is already busy, or when the server on it is not the one
  it started — verified through a `/__whoami` endpoint, after this harness once
  measured **another agent's server** that had claimed the port first and
  passed every check because something answered;
- compare variants whose payloads differ, canonicalised first because akkar's
  JSON is **not byte-stable** (Lua table order depends on the hash seed);
- score a difference smaller than the noise floor derived from that same run;
- continue when a process dies mid-run, or when `wrk` reports connect errors or
  timeouts. Read and write errors up to one per connection are teardown and
  are allowed — anything more is not.

It reports two sections. The **ceiling** answers "how much work fits". The
**service time** answers "how long one request takes", and says whether it had
headroom to mean that: if adding connections barely raises throughput, the low
run was saturated too and its latency is queue depth.

`wrk`'s default 2 s timeout is overridden to 10 s, because under closed-loop
saturation the queue delay alone approaches 2 s and the default truncates the
distribution being measured.

## `payload.sh` — where serialisation starts to dominate

```sh
bash bench/certify/payload.sh [akkar_dir]
```

Sweeps 1 to 2500 rows on two axes: response size (`/rows/:n`, encode cost) and
request size (`/echo`, decode cost with a constant response). Reports µs per
request and **ns per byte**.

ns/byte is the column to read. Flat means cost is proportional to payload and
is nobody's bug. Rising means cost is superlinear, or proportional to element
count rather than bytes — the shape the owner's earlier framework had, where it
turned out to be per-element reflection and a redundant second pass.

## Running these honestly

The box must be idle. A certification run on a machine shared with other work
produced spreads of 11–18% at the ceiling and up to 100% at low concurrency,
against 0.7% measured on the same hardware when it had the machine to itself.
A noise floor that wide swallows every patch worth making.
