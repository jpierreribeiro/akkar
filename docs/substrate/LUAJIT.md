# LuaJIT — what it would actually take

F3 in `docs/PLAN.md` is a one-week timebox with its decision rule written in
advance: **if `/ping` does not gain ≥ 2×, LuaJIT is refused with a number.**

This page is the half of that week that does not need the study box: **what it
would cost**, enumerated rather than estimated. The throughput half is still
unmeasured and the decision is still open.

The short version: the substrate is ready and akkar is not. Nine of akkar's
own files do not compile under LuaJIT, and the reason is not the one the plan
predicted.

---

## The substrate works. That was the go/no-go and it passed.

LuaJIT 2.1.1703358377, unpacked into a private prefix with `dpkg -x` — the
same no-root trick `src/build.sh` documents for `libpq-dev`.

**cqueues builds against it**, from the same commit CI pins
(`c366149…`), `make all5.1 && make install5.1`, exit 0 both times. And it runs:

```
require cqueues :  true   20200726
COMMIT          :  c36614982fe0
loop runs       :  true
cqueues.socket  :  true
condition       :  true
poll(number)    :  0.050 s
```

That last line matters more than it looks. `cqueues.poll(number)` is the
mechanism F2 now depends on for every request's deadline, and it behaves
identically here.

**The vendored HTTP parses clean: 0 of 16 files fail.** lua-http was written
for 5.1 compatibility, so the ~54% of a request that lives in
`akkar/vendor/http/` is already LuaJIT-ready and needs no work at all.

---

## akkar did not: nine of 59 files failed to PARSE. Now none do.

**All 60 files compile under LuaJIT 2.1.** `akkar/bitwise.lua` supplies the
operators as functions, and `static.lua`'s four `<close>` variables are a
`using(handle, fn)` helper that closes on every path. The 5.4 suite stayed
green throughout: 1,786 passing, 0 failures.

What follows is the inventory as it was found, kept because the shape of the
work is the useful part.

```
akkar/config.lua:209     unexpected symbol near '/'
akkar/crypto.lua:84      unexpected symbol near '>'
akkar/doctor.lua:190     unexpected symbol near '>'
akkar/etag.lua:72        unexpected symbol near '~'
akkar/execution.lua:99   ')' expected near '&'
akkar/init.lua:259       unexpected symbol near '/'
akkar/jwt.lua:191        unexpected symbol near '<'
akkar/static.lua:389     unexpected symbol near '<'
akkar/trace.lua:177      ')' expected near '|'
```

**The plan predicted the blockers would be semantic** — `math.type` missing and
the compat shim's version lying about it. They are mostly **syntactic**, and a
syntax error is a harder kind of blocker: there is no shim for it, because the
file never compiles far enough to load one.

LuaJIT 2.1 is Lua 5.1 with some 5.2 extensions. `goto` works. `//`, `&`, `|`,
`~`, `<<`, `>>` and `<close>` are all Lua 5.3+ or 5.4+ and are parse errors.

### The complete inventory

**Integer division `//` — 5 sites, 3 files**

| | |
|---|---|
| `config.lua:209`, `init.lua:259` | `#word // 3`, the typo-suggestion distance — the same line in two files |
| `static.lua:436, 438, 439` | civil-from-days date arithmetic |

**Bitwise operators — 14 sites, 7 files**

| | |
|---|---|
| `crypto.lua:84, 119` | hex encoding, constant-time compare |
| `doctor.lua:190–192` | decoding OpenSSL's packed version |
| `etag.lua:72` | the content hash |
| `execution.lua:99` | the request-id counter mask — **per request** |
| `init.lua:1424` | traceparent sampled flag — **per request when tracing** |
| `init.lua:1483–1484` | CIDR mask for trusted proxies |
| `jwt.lua:191, 195, 196` | base64url |
| `trace.lua:177` | `whole | 0`, the integer-coercion idiom |

**`<close>` — 4 sites, 1 file:** `static.lua:389, 539, 816, 832`, all the same
shape, a file handle scoped to a block.

**`math.type` — 6 sites, 5 modules:** `db.lua:57`, `doctor.lua:138`,
`log.lua:67`, `sql.lua:238, 246`, `trace.lua:195`.

---

## What the portable spelling costs the target we actually ship

Bitwise cannot be shimmed at the syntax level: every `a & b` becomes
`bit.band(a, b)`, on **every** interpreter, including the Lua 5.4 and 5.5 this
runtime ships to. That is a permanent tax on the primary target, paid to
support a secondary one — so it should be a number, not a feeling.

Measured, 5,000,000 iterations, twice:

| | ns/op | over the operator |
|---|---:|---:|
| `a & b`, native | 29–37 | — |
| `band(a, b)`, Lua function | 64 | **+74% to +120%** |
| `x // 3`, native | 41–48 | — |
| `math.floor(x / 3)` | 76–80 | **+65% to +83%** |

**And it does not matter, which is the useful half of the finding.** The
per-operation tax is large in percentage and about 30 ns in absolute terms.
Only two of the fourteen bitwise sites run on a normal request — the request-id
mask and, when tracing, the sampled flag — so the cost is roughly 60 ns against
a request that takes 85,000 ns of CPU. **About 0.07%**, an order of magnitude
below the 1.16% noise floor this project measures against.

The rest — crypto, jwt, etag, doctor, the CIDR mask — run per boot, per token
or per configured route, not per request.

So the portability tax is affordable. **The cost of LuaJIT is the work, not the
tax.**

---

## The semantic blocker is still the real one

`math.type` has no LuaJIT equivalent, and the compat shim's version **lies**:
it returns `"integer"` for an integral float. That is not an inconvenience, it
is the exact defect `v.integer` exists to prevent, and it was found porting a
service that handled money.

The consequence is concentrated in one line — `db.lua:57`:

```lua
if math.type(v) == "integer" then return INT8, tostring(v) end
```

which chooses `int8` over `float8` for a bound parameter. `docs/DECISIONS.md`
calls that **the 3.91× fix**. Under a shim that lies, that line silently picks
the wrong type for every integral float, and `doctor.lua:138` — which exists to
catch a missing `math.type` — would pass, because the shim provides one.

**LuaJIT has no integer subtype at all.** Every number is a double. So this is
not a shim problem to be solved with a better shim; it is a property of the
runtime, and `v.integer`, `sql.lua`'s limit and offset checks, `log.lua`'s
number formatting and `trace.lua`'s OTLP encoding all rest on a distinction
LuaJIT does not make.

---

## What this changes about the decision

Before: "the blockers are semantic and the cost side is priced."

Now:

1. **The substrate is free.** cqueues builds and runs; the vendored HTTP needs
   nothing. That was the risk and it is retired.
2. **The syntactic work is DONE.** 23 edits across 9 files, behind
   `akkar/bitwise.lua` and a `using(handle, fn)` helper in `static.lua`. All
   60 files parse under LuaJIT and the 5.4 suite is green: 1,786 passing.
3. **The portability tax is 0.07% of a request**, measured, so it does not
   argue against doing the work.
4. **The semantic blocker is unchanged and is a property of LuaJIT**, not of
   our shim. It cannot be worked around; it can only be accepted, which means
   accepting that `req.db` binds every whole number as `float8` and that
   `v.integer` becomes advisory.

So the question is no longer "can we?" but "is a runtime with no integer
subtype the runtime we want?", and that is answerable only against a
throughput number that does not exist yet.

**Still to do, and it needs the study box:** build LuaJIT-compatible
`lua-cjson`, `lpeg`, `lpeg_patterns`, `basexx`, `binaryheap`, `fifo` and
`luaossl`, then run `/ping`. **The 23 syntactic edits are done and the 5.4
suite is green with them in.** Then apply the rule that was written in advance: **under 2×, refused
with a number.**
