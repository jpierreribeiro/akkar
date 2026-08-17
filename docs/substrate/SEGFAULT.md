# The suite segfaults, intermittently, inside cqueues

Found on 17 August 2026 while running the suite for an unrelated change. Not
caused by that change — the timestamps rule it out, and they are the first
thing recorded here because "did I break this" is the only question that
matters before anything else gets written.

## What happened

`busted` died with `Segmentation fault (core dumped)` after roughly 1,612 of
1,699 tests. The next full run passed 1,699 with exit 0. So it is
**intermittent**, and re-running until it passes is exactly what must not be
done with it.

`coredumpctl` shows this is not new and not rare:

```
12:12:42  SIGBUS   lua5.4
12:17:49  SIGBUS   lua5.4
12:23:09  SIGSEGV  lua5.4
12:44:32  SIGSEGV  lua5.4
```

Four crashes in half an hour of test runs. **Three of them predate the change
being worked on** (`akkar/execution.lua` did not exist until 12:32), and two
predate that session's first commit. Two distinct signals, which is usually
one memory bug seen from two angles rather than two bugs.

## Where

```
$ addr2line -f -C -e ~/.luarocks/lib/lua/5.4/_cqueues.so 0x1423b
table_LLRB_FIND
src/cqueues.c:1192
```

`table` here is not the timer tree. `cqueues.c` generates two:

```c
LLRB_GENERATE_STATIC(table, fileno, rbe, fileno_cmp)   /* <- this one */
LLRB_GENERATE_STATIC(timers, timer, rbe, timer_cmp)
```

So the crash is a lookup in the **file-descriptor table of a pollset**,
walking a red-black tree whose nodes are `struct fileno`. A segfault in a tree
*find* means the tree is corrupt: a node freed while still linked, or mutated
from underneath the walk.

## Why this points at the controller pool

`akkar/execution.lua` (formerly `akkar/init.lua`) keeps a pool of up to 64
cqueues controllers and hands one to every in-flight request for its deadline.
The pool already carries a guard, and the comment beside it describes half of
this problem:

> Only an empty controller goes back. A handler abandoned by the deadline is
> still running inside its controller, and reusing that would hand the next
> request someone else's unfinished work.

`cq:empty()` says the controller has no coroutines left. It does not say the
fileno table is in a state fit for reuse. A descriptor registered with a
pollset and closed elsewhere — by a pool returning a connection, by a stream
shutting down — leaves the pollset holding a node for an fd that is gone, and
the next `find` on that tree walks it.

**This is a hypothesis, not a diagnosis.** What supports it: the crash is in
the fd table specifically; akkar recycles pollsets, which most cqueues users
do not; and the crashes cluster in the part of the suite that spawns servers
and times requests out. What would confirm it: a build of cqueues with
`-fsanitize=address`, and a reproduction under it.

## What it is NOT

**It is not the release-versus-pin mismatch**, and that hypothesis was checked
before being repeated. The 14 commits between `rel-20200726` and the pinned
`c366149` are libressl 3.5.0 opaque bio structs, Lua 5.5 support, compiler
warnings, `thread.c` fixes and freebsd inotify. **None touches the LLRB code or
the pollset.** Upgrading to the pin would not fix this.

## The related defect, which is real and separate

The development machine does not run the cqueues it pins either:

```
$ lua5.4 -e 'local c = require "cqueues" print(c.VERSION, c.COMMIT)'
20200726   nil
```

`COMMIT` is only set when built with `-DCQUEUES_COMMIT`, which the pinned build
passes and the release rock does not. So this machine is running the July 2020
release, and the crashing `_cqueues.so` was built by luarocks from
`/tmp/luarocks_cqueues-20200726.54-0-.../cqueues-rel-20200726/`.

This is the same defect fixed in CI on 17 August — luarocks pulling the release
rock as a dependency of `http` and moving the hand-built one aside — now shown
to be true locally as well. **Every local test run this project has ever done
tested cqueues 2020**, and `akkar/substrate.lua` patches cqueues internals on
the assumption of the pin.

Fixing that is worth doing on its own merits. It will not fix this crash.

## Why it is not being chased right now

Because there is a plan item that removes the suspect entirely.

F2 of the runtime programme replaces the per-request cqueues controller with a
deadline carried as a number in the execution scope, enforced at the adapter
boundary. No controller per request means no controller pool, which means no
recycled pollset. If the hypothesis above is right, F2 deletes this bug rather
than repairing it.

So this is recorded, its priority is noted, and F2 gains a second reason to
exist beyond the concurrency ceiling. If the crash survives F2, it was never
about the pool and this page should say so.

## What to do when it happens again

```sh
coredumpctl list | tail
coredumpctl info <pid>
addr2line -f -C -e ~/.luarocks/lib/lua/5.4/_cqueues.so <offset>
```

And record the offset here. Two data points are a pattern; one is an anecdote,
and this page currently has one address seen once.
