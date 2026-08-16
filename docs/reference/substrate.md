# akkar.substrate

Patches lua-http in place to repair one denial of service that cannot be
worked around from outside it. Two functions and three fields of state.

**When you need it.** `App:run` calls `substrate.apply()` for you, so an
application never touches this module. You reach for it directly in two
situations: a test that wants the unpatched behaviour and therefore must not
let it be applied, and a running process where you want to know whether
malformed request framing is arriving at all.

```lua no-run
local substrate = require "akkar.substrate"
```

## What the patch changes

It replaces one function: `http.h1_stream`'s `methods.shutdown`.

The replacement does three things around the original.

**Before.** It installs a `step` on the stream **instance**, with `rawset`, so
it shadows the metatable method for this stream and only for the duration of
this `shutdown` call. That `step` calls the original and then insists on
progress: if `stats_recv` has not advanced for more than eight consecutive
calls, it answers `false` instead of `true`. The drain loop inside `shutdown`
uses `step`'s answer as its only stopping condition, so a `false` ends it.

**During.** The original `shutdown` runs inside a `pcall`.

**After.** The instance `step` is removed with `rawset(self, "step", nil)`,
whether the original returned or raised. On a raise, `rescued` is incremented,
`last_rescued` is set to the error, the socket is shut down and the state set
to `closed` if it is not already, and `shutdown` returns `true`.

### What a caller can observe

| observable | how |
|---|---|
| the patch is in place | `substrate.applied.h1_shutdown_spin` is `true` |
| a raise was swallowed | `substrate.rescued` went up |
| what it said | `substrate.last_rescued` |
| a connection was not reused | a stream whose drain was cut short is closed rather than kept alive |

A stream that drains normally is unaffected. It makes progress, the guard never
fires, and `shutdown` returns exactly what it always returned.

Nothing else in lua-http sees a modified `step`, because the override lives on
the instance and is removed before `shutdown` returns.

### The two defects it covers

Both are one malformed request, no volume, no timing, no authentication.

`Content-Length: banana` leaves `body_read_left` as `nil`, which is not zero,
so the drain loop takes the read branch forever and reports progress it is not
making. The coroutine never yields, the cqueues controller is starved, and the
accept loop stops running without ever returning. The listening socket stays
open, so a health check that asks "is the port open" says yes. That is what the
progress guard ends.

`Content-Length: -5` is a different failure. `read_next_chunk` raises
`invalid length: -5`, lua-http calls `stream:shutdown()` with no `pcall` around
it, the error reaches `cq:loop()`, `server:loop()` returns, and the process
exits. That is what the `pcall` and the counter catch.

## substrate.applied

A table of which repairs are in place. One key so far.

| key | value |
|---|---|
| `h1_shutdown_spin` | `true` once `fix_h1_shutdown_spin` has succeeded; absent before that |

Read only. Setting it by hand makes `fix_h1_shutdown_spin` a no-op that
answers `true`.

## substrate.apply()

Applies every repair.

**Returns** a report:

```lua no-run
{ h1_shutdown_spin = { applied = true, reason = nil } }
```

`applied` is what `fix_h1_shutdown_spin` returned, and `reason` is its second
value, so `reason` is `nil` on success and a string on refusal.

**Raises** nothing.

It is called from `App:run` and not at require time, because importing a module
should not mutate a third party library as a side effect.

```lua
local substrate = require "akkar.substrate"

local report = substrate.apply()
assert(type(report.h1_shutdown_spin) == "table")

if report.h1_shutdown_spin.applied then
  assert(substrate.applied.h1_shutdown_spin == true)
else
  -- lua-http is absent, or has moved on from the shape this repair expects.
  assert(type(report.h1_shutdown_spin.reason) == "string")
end
```

## substrate.fix_h1_shutdown_spin()

Installs the replacement `shutdown` described above. Idempotent, and safe to
call at any time.

**Returns** `true` when the patch is in place, including when it was already in
place from an earlier call.

**Returns** `false` and a reason when it refuses:

| reason | when |
|---|---|
| `http.h1_stream is not installed` | `require "http.h1_stream"` failed |
| `http.h1_stream does not have the expected shutdown/step` | `methods` is not a table, or `methods.shutdown` or `methods.step` is not a function |

The second is the hopeful case: a lua-http that has fixed the defect itself, or
restructured past it. This module refuses to patch a shape it does not
recognise rather than patching it anyway.

**Raises** nothing.

```lua
local substrate = require "akkar.substrate"

local ok, why = substrate.fix_h1_shutdown_spin()
if ok then
  assert(why == nil)
  assert(substrate.fix_h1_shutdown_spin() == true)   -- idempotent
else
  assert(why:find "h1_stream")
end
```

## substrate.last_rescued

The error value from the most recent swallowed raise, or `nil` when there has
not been one. Set at the same moment `rescued` is incremented, so it always
describes the latest count and never an earlier one.

## substrate.rescued

A count of how many times the replacement `shutdown` caught a raise from the
original and turned it into a normal return. Starts at `0`.

Counted rather than silent on purpose. Swallowing an error is the right call
in this one place, and it is still an error: a repair that leaves no trace is
indistinguishable from a repair that is no longer needed. A number climbing
here means malformed framing is arriving.

```lua
local substrate = require "akkar.substrate"

assert(substrate.rescued == 0)
assert(substrate.last_rescued == nil)
```

## Not here

**Anything else in lua-http.** One repair, named for what it repairs. Every
other module in akkar treats the substrate as replaceable and leaves it alone.

**A way to undo the patch.** `applied` records that it happened; there is no
`unapply`. A test that wants the unpatched behaviour has to not apply it.

**A guard on the normal path.** The progress requirement is installed for the
duration of one `shutdown` call and nowhere else. `step` outside `shutdown`
behaves exactly as lua-http wrote it.

## See also

- [akkar](akkar.md), for `app:run`, which is what calls `apply()`
- [The lua-http wedge](../substrate/lua-http-wedge.md), for the 25 line
  reproduction with no akkar in it
- `spec/substrate_spec.lua`, which states what akkar requires of the substrate
  and has one test that needs the unpatched behaviour
- the module source, `akkar/substrate.lua`, which measures the wedge rather than
  guessing at it
