# "LuaResty" — four scenarios for taking nginx's 5.8×, and what each costs

The measured background, so this page argues from numbers:

| | |
|---|---:|
| gap to OpenResty | **9.4×** |
| of which the language (LuaJIT) | 1.62× |
| of which nginx being C | **5.8×** |
| akkar's CPU that is HTTP written in Lua | 66% |
| akkar's CPU that is akkar's own chain | 34% |

**78% of the gap is C.** So "get OpenResty's numbers" means "get a C HTTP
server", and the only real question is which C server and who owns it.

There are four ways to have one. They are genuinely different products, not
degrees of the same one.

---

## Scenario 1 — akkar becomes a library for OpenResty

The handlers, the router and the validation run inside
`content_by_lua_block`. nginx does HTTP; akkar does the application.

### What survives, and it is more than it first looks

Roughly two thirds of akkar is pure Lua with no substrate dependency:
routing, `v.*` validation and schema expansion, the SQL builder, JWT, CSRF,
sessions, OpenAPI generation, metrics, the tenant scope, idempotency keys.
All of it ports.

### What breaks

- **Every adapter.** `req.db`, `req.cache`, `req.http` are cqueues sockets.
  Under OpenResty they become `ngx.socket.tcp` cosockets — a different API,
  different timeout semantics, different pooling.
- **The pool.** OpenResty has its own connection pooling built into the
  cosocket (`sock:setkeepalive`). `akkar/pool.lua` would be redundant at best
  and fighting it at worst — and the pool is where two of this project's
  hardest bugs lived.
- **`app:run` disappears.** The process, the workers, the listen sockets, the
  reload, the shutdown drain all become `nginx.conf`. `akkar build` and the
  single-artifact deployment story go with it.
- **Jobs and cron** become `ngx.timer.at`, which has a different failure
  model — a timer that outlives a worker reload is nginx's problem, not ours.
- **The watchdog dies, and this one is not negotiable.** It works by
  `debug.sethook` with an instruction count. On LuaJIT a debug hook **aborts
  every trace**, so the thing that costs under 2% on PUC Lua would cost most
  of the JIT's advantage. You would ship without it or ship slow.
- **You inherit LuaJIT's missing integer subtype**, measured in
  `docs/substrate/LUAJIT.md`: `db.lua:57` chooses `int8` from `math.type`,
  which `DECISIONS.md` calls the 3.91× fix, and LuaJIT has no such
  distinction. The shim that makes it run has to lie.

### What happens to the invariants

The four invariants are the product, so this is the real accounting:

| invariant | under OpenResty |
|---|---|
| all I/O goes through adapters akkar owns | **enforceable, but only by forbidding `ngx.*` in handlers** — `akkar.vm`'s sandbox could do it, and it becomes a policy rather than a structural fact |
| the handler returns the response rather than mutating a context | **survives** — this is pure Lua |
| every request has a deadline | **survives in shape**, rebuilt on cosocket timeouts and `ngx.now` |
| the capability set is closed | **survives** |

The first one is the loss. Today it is true because akkar owns the loop:
there is no other way to do I/O. Under nginx there is always another way, and
the invariant becomes a rule people can break.

### Cost and verdict

**3–6 months, and a different product at the end.** The honest name for it is
not akkar-on-OpenResty; it is a new project that shares akkar's application
layer.

**When it would be right:** if akkar's users are people who already run nginx
and want their Lua closer to it. That is a real market and it is not this
project's current one.

---

## Scenario 2 — "LuaResty": fork OpenResty, make it ours

Take nginx + LuaJIT and replace OpenResty's Lua module with our own.

**This is Scenario 1 with more work and less support.** You still get nginx's
event loop and parser, still lose the adapters and `app:run`, still inherit
LuaJIT — and now you also maintain a fork of a C web server and its Lua
bindings, and you diverge from every OpenResty module and every piece of
OpenResty documentation your users would otherwise find.

OpenResty's value is not its Lua glue. It is that nginx is a twenty-year-old
C server and that thousands of people run it.

**Verdict: strictly dominated by Scenario 1.** If you want nginx, use nginx.

---

## Scenario 3 — a C HTTP core inside akkar, keeping cqueues and PUC Lua

This is `docs/WHERE-TO-GO.md`'s option D, and it is the only "have our own"
that keeps akkar being akkar.

The vendored HTTP is 66% of the CPU above the socket. Replacing its hot half
with C — tokenising the request line and headers, the header representation,
the response writer — while **framing stays in Lua**, where 656 lines of
framing, fuzz and encoding tests already are.

### Why framing stays in Lua, and this is not squeamishness

Framing is `Content-Length` versus `Transfer-Encoding: chunked` and the
disagreements between them. That is where request smuggling lives. llhttp owns
that logic and has CVE-2022-32213, -32214 and -32215 to show for it. The
existing tests were written against a Lua implementation and would carry over
to a C one only as a black box.

Same shape as `akkar.pq`: a separate optional rock, so a C compiler never
becomes a hard dependency of `luarocks install akkar`.

### What it buys, bounded from the measurement

If the HTTP layer's CPU went to zero — it would not — the ablation gives
491 µs → 213 µs, about **2.3×**. Realistically **1.6–2×**.

Not 9.4×, because akkar's own chain is the other third and stays Lua. To get
the rest you would have to write akkar in C too, and then it is not a Lua
runtime.

### What it costs

**3–6 months to something trustworthy, then a security-relevant C parser to
maintain for as long as the project exists.** Every akkar release becomes a
release with a C attack surface.

### Everything it keeps

`app:run`, the adapters, cqueues, PUC Lua and its integer subtype, the
watchdog, `akkar build`, and the first invariant as a structural fact rather
than a policy.

---

## Scenario 4 — stay pure Lua and take what is left

`docs/WHERE-TO-GO.md`'s option A. Ceiling around 1.5×, of which the largest
single piece is measured and removable: the two per-request coroutines are
**55% of a request's allocation**, and a long-lived worker measured **zero**
bytes per unit of work against 1,664 for a fresh coroutine.

**Weeks. No new risk. Every step measurable without a quiet machine.**

---

## The comparison, on one screen

| | buys | costs | keeps akkar's identity |
|---|---:|---|---|
| **1** library for OpenResty | 9.4× | 3–6 months | invariant 1 becomes policy; no `app:run`; no watchdog; LuaJIT integers |
| **2** fork OpenResty | 9.4× | more than 1 | same losses, plus a C fork to maintain |
| **3** C core inside akkar | 1.6–2.3× | 3–6 months + permanent C security surface | **yes, all of it** |
| **4** stay pure Lua | ~1.5× | weeks | **yes, all of it** |

---

## The question underneath all four

**Who is akkar competing with?**

Against **Lapis, Luvit, Sinatra, FastAPI** — application frameworks — akkar is
already **31% ahead of the nearest one on the identical substrate**, and the
product is the invariants: `spec/substrate_spec.lua`, the closed capability
set, the propagated deadline, the deterministic simulation in the lab. None of
that is about speed. It is about **proving** what other frameworks assert.

Against **OpenResty** — infrastructure — nothing here is enough. OpenResty is
nginx. Competing with it means becoming a C web server, and that is Scenario 1
or 2, with years of work and a different thing at the end.

**The chosen direction is 4, then 3 as a deliberate later decision.** Written
here so that whoever revisits it has the numbers rather than the argument.

A note on order that is not strategy but sequencing: **4 makes 3 cheaper.** A
C layer sitting under a leaner Lua chain is a smaller C layer, and the
allocation work in 4 is what makes the boundary between them obvious.
