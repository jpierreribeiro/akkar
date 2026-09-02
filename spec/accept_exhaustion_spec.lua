--[[
What the accept loop does AT the descriptor ceiling, not approaching it.

`docs/UNKNOWNS.md` §4 named this as the sharpest thing nobody had checked, and
it was right to. The classic failure is well known: at a descriptor limit
`accept()` returns an error, the listening socket stays readable, and a naive
event loop calls `accept()` again immediately and for ever. nginx keeps a spare
descriptor in reserve for exactly this; Go sleeps and retries.

The answer here is split, and the split is the finding.

**`EMFILE` was already defended, twice over.** lua-http throttles it, and akkar
never reaches it on Linux at all: `akkar.descriptor_ceiling` caps
`max_concurrent` at 66% of the soft limit, so the process runs out of
permission before it runs out of descriptors. Measured on a real server with
`ulimit -n 96` and 400 clients arriving: **0.0% of a core** with the derived
ceiling, against **92.6%** with `max_concurrent` set above the limit by hand.
That is a verified non-issue and the measurement is the point of it.

**Its three siblings were not defended at all.** `accept()` has four errnos
that leave the pending connection ON the queue -- `EMFILE`, and also `ENFILE`
(the MACHINE is out of descriptors), `ENOBUFS` and `ENOMEM` (the kernel has no
memory for the new socket). Upstream throttled the first and sent the other
three to `onerror`, which returns, and the `while` calls `accept()` again.
Measured before the fix:

    ENFILE   349,314 accept() calls a second, 71% of a core
    ENOBUFS  336,182                          71%
    ENOMEM   474,998                          98%

and, through `akkar.log`, **61,216 log lines a second at 3.8 MB/s** -- which
fills a small disk in under an hour and turns a transient kernel condition into
the ENOSPC failure §3 asks about separately.

THE PART THAT MAKES IT AN OUTAGE RATHER THAN A COST is that the loop never
yields. A sibling coroutine in the same controller got **one turn in a full
second** against the ~100 it should get. That controller holds every in-flight
request, every task registered with `app:task`, and the signal handler that
makes SIGTERM work. So the process keeps the listening port, pins a core, and
serves nothing -- and cannot be shut down cleanly either.

No per-process ceiling can prevent these three the way `descriptor_ceiling`
prevents `EMFILE`: `ENFILE` is system-wide and the other two are the kernel's
own allocator. A container under `docker run -m` reaching its memory limit is
the ordinary way to meet them.

## How these tests induce it

By replacing `accept` on the shared cqueues socket metatable, restored by
`after_each` and by `under` itself. A real `ENFILE` needs the whole machine out of descriptors, which no
test may do to the box it runs on; the errno is the entire input to the branch
under test, so injecting it tests exactly what the kernel would.

The budget check lives INSIDE the patched `accept` on purpose. Before the fix
the loop does not yield, so a timer coroutine set to stop it never runs -- the
first version of this harness hung, and that hang was the first evidence of the
defect.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local ce      = require "cqueues.errno"
local cs      = require "cqueues.socket"
local akkar   = require "akkar"
local server  = require "akkar.vendor.http.server"

-- The shared metatable every cqueues socket uses.  Patching it reaches the
-- listening socket inside lua-http, which is not otherwise addressable.
local socket_index = getmetatable(cs.listen { host = "127.0.0.1", port = 0 }).__index
local real_accept  = socket_index.accept

--- Runs a lua-http accept loop whose `accept` fails with `errno` for `window`
--- seconds, and reports what it did with the time.
---
--- THE PATCH GOES ON AFTER THE SERVER EXISTS, and the deadline is taken there
--- too. `server.listen` builds a TLS context on the way past, which costs a
--- key generation -- long enough that an earlier version of this harness spent
--- its whole window inside the constructor and measured a loop that had not
--- started. It reported zero accept() calls for a case that spins at 349,000
--- of them.
---
--- @return table calls, errors, turns, accepted, rate
local function under(errno, window, opts)
  opts = opts or {}
  local calls, errors, turns, accepted, stop = 0, 0, 0, 0, false
  local started, drained

  local s = assert(server.listen {
    host = "127.0.0.1", port = 0,
    onstream = function(_, stream) stream:shutdown() end,
    onerror  = function() errors = errors + 1 end,
  })
  assert(s:listen())

  -- Real clients, when the case needs `accept()` to be able to SUCCEED.
  local clients = {}
  if opts.clients then
    local _, host, port = s:localname()
    for _ = 1, opts.clients do
      clients[#clients + 1] = assert(cs.connect { host = host, port = port })
    end
  end

  -- Every Nth call is allowed through to the real `accept`, so a
  -- per-connection error -- one the kernel DOES dequeue -- can be told apart
  -- from one that leaves the connection on the queue for ever.
  local succeed_every = opts.succeed_every
  local deadline = cqueues.monotime() + window
  started = cqueues.monotime()

  socket_index.accept = function(self, ...)
    if cqueues.monotime() >= deadline then error("window elapsed", 0) end
    calls = calls + 1
    if succeed_every and calls % succeed_every == 0 then
      local sock, err = real_accept(self, ...)
      if sock then
        accepted = accepted + 1
        if accepted == opts.clients then drained = cqueues.monotime() - started end
      end
      return sock, err
    end
    return nil, errno
  end

  local cq = cqueues.new()
  cq:wrap(function() pcall(function() s:loop() end); stop = true end)
  -- The canary: an ordinary background coroutine asking for 100 turns.
  cq:wrap(function()
    while not stop do turns = turns + 1; cqueues.sleep(window / 100) end
  end)

  pcall(function() cq:loop(window * 20) end)

  socket_index.accept = real_accept
  for _, c in ipairs(clients) do pcall(c.close, c) end
  pcall(s.close, s)
  return { calls = calls, errors = errors, turns = turns, accepted = accepted,
           drained = drained, rate = math.floor(calls / window) }
end

describe("the accept loop at the descriptor ceiling", function()
  after_each(function() socket_index.accept = real_accept end)

  -- ONE TABLE, SO A NEW ERRNO CANNOT BE ADDED WITHOUT A DECISION. Each of
  -- these leaves the pending connection on the queue, so `accept()` called
  -- again reproduces the error immediately: none of them can be reported and
  -- retried without a throttle in between.
  local exhaustion = {
    { "EMFILE",  ce.EMFILE,  "this process is out of descriptors" },
    { "ENFILE",  ce.ENFILE,  "the machine is out of descriptors" },
    { "ENOBUFS", ce.ENOBUFS, "the kernel has no buffer for the socket" },
    { "ENOMEM",  ce.ENOMEM,  "the kernel has no memory for it" },
  }

  for _, case in ipairs(exhaustion) do
    local label, errno, why = case[1], case[2], case[3]

    describe(label .. " -- " .. why, function()
      it("does not busy-loop on accept()", function()
        local r = under(errno, 0.4)
        -- Unthrottled this measured 349,000/s (ENFILE) and 474,000/s
        -- (ENOMEM). Throttled it is one per `hang_timeout`, ~33/s. The
        -- assertion is deliberately three orders of magnitude clear of both
        -- numbers, so it is about the DEFENCE and not about the machine.
        assert.is_true(r.rate < 500,
          ("%s spun accept() at %d calls/s"):format(label, r.rate))
      end)

      it("does not starve the coroutines beside it", function()
        -- THE ONE THAT MAKES IT AN OUTAGE. The accept loop shares its
        -- controller with every in-flight request, every `app:task`, and the
        -- signal handler `App:stop` needs. Before the fix this was 1.
        local r = under(errno, 1.0)
        assert.is_true(r.turns >= 50,
          ("%s starved its sibling: %d turns in 1s, expected ~100")
            :format(label, r.turns))
      end)

      it("does not flood the log with one line per attempt", function()
        -- Reported ONCE per run of identical failures. Through `akkar.log`
        -- the unthrottled loop wrote 61,216 lines and 3.8 MB in one second:
        -- a transient kernel condition that fills the disk is how §3's ENOSPC
        -- question gets asked for real.
        local r = under(errno, 0.4)
        assert.is_true(r.errors < 20,
          ("%s called onerror %d times in 0.4s"):format(label, r.errors))
      end)

      it("still says so at least once", function()
        -- Throttling an error must not also hide it. A server that stopped
        -- accepting with nothing in the log is a worse outage than a loud one,
        -- because nobody can name the cause.
        local r = under(errno, 0.4)
        assert.is_true(r.errors >= 1,
          label .. " was throttled into silence: onerror never ran")
      end)
    end)
  end

  -- The other half of the split, and the reason the fix is not simply "sleep
  -- on every accept error". ECONNABORTED is a peer that sent RST between the
  -- handshake and the accept; the kernel DEQUEUES it, so the next call makes
  -- progress. Throttling that would let anyone cap the server's accept rate at
  -- 33 connections a second by flooding resets -- a denial of service
  -- introduced by the defence against one.
  it("does not throttle a per-connection error that the kernel dequeues", function()
    -- Every other call reaches the real `accept`, and there are real clients
    -- waiting for it, so this is the shape the kernel actually produces: an
    -- abort, a success, an abort, a success. Throttled at 33/s, twenty
    -- connections would need 0.6 s; they must all be in within the window.
    local r = under(ce.ECONNABORTED, 0.4, { succeed_every = 2, clients = 20 })
    assert.equal(20, r.accepted)
    -- The rate over the whole window is not the measure: once the twenty are
    -- in, `accept` reports ETIMEDOUT and the loop rightly sleeps on the
    -- listening socket. What matters is how long the twenty took.
    assert.is_true(r.drained < 0.2,
      ("twenty aborted-then-accepted connections took %.3f s; a throttle " ..
       "would make it 0.6"):format(r.drained or -1))
  end)

  -- An errno nobody anticipated is the case this cannot enumerate, so it is
  -- handled by behaviour rather than by name: identical failures in a row with
  -- no successful accept between them are throttled whatever they are.
  it("throttles an unrecognised errno that repeats for ever", function()
    local r = under(ce.EPERM, 0.4)
    assert.is_true(r.rate < 500,
      ("an unrecognised repeating errno spun at %d calls/s"):format(r.rate))
    assert.is_true(r.errors >= 1, "and it was never reported")
  end)
end)

describe("akkar's own descriptor ceiling", function()
  -- WHY EMFILE IS THE LEAST LIKELY OF THE FOUR ON LINUX, and the positive
  -- result that goes with the defect above. akkar reads the soft limit at
  -- `App:run` and caps `max_concurrent` at 66% of it, so connections run out
  -- of permission before descriptors run out. Measured on a real server at
  -- `ulimit -n 96` with 400 clients arriving at once: 0.0% of a core with the
  -- derived ceiling, 92.6% with `max_concurrent = 10000` set by hand.
  it("leaves a third of the descriptors for everything that is not a request", function()
    assert.equal(675, akkar.descriptor_ceiling(1024))
    assert.equal(5406, akkar.descriptor_ceiling(8192))
    -- The headroom is the point: pools, log files, the listening socket and
    -- the outbound client all come out of the same limit.
    assert.is_true(1024 - akkar.descriptor_ceiling(1024) > 300)
  end)

  -- THE CEILING IS DERIVED FROM THE WRONG RESOURCE IN THE ONE PLACE akkar
  -- SHIPS A DOCKERFILE FOR.
  --
  -- Measured, with the real static binary from `Dockerfile`, in a real
  -- container: `docker run -m 32m akkar-deploy-test:scratch`.
  --
  --     descriptor limit inside the container   1,048,576  (soft AND hard)
  --     max_concurrent akkar derives from it      691,896
  --     connections it survived                    ~2,700
  --     OOMKilled=true, ExitCode=137, and the last line in the log
  --     was still "listening"
  --
  -- A container does not lower `RLIMIT_NOFILE`; it lowers memory. So the
  -- number akkar caps itself at is 250 times what the box can actually hold,
  -- the admission control it does have never fires, and the failure is SIGKILL
  -- -- no 503, no shed, no warning, nothing in the log to explain the restart.
  -- Every other ceiling in this project degrades; this one is the process
  -- vanishing.
  --
  -- Nothing in `akkar/` reads a cgroup: `grep -rn "cgroup\|memory.max" akkar/`
  -- is empty. That is what this test is here to change the moment somebody
  -- adds one.
  it("is derived from descriptors only, and a container limits memory instead", function()
    -- ~10.5 KB of container memory per idle connection, from the ramp above:
    -- 32 MB total, 11.2 MB resident before any client arrived, dead at ~2,700.
    local per_connection = 10.5 * 1024
    local container = 32 * 1024 * 1024
    local baseline = 11.2 * 1024 * 1024

    local memory_allows = math.floor((container - baseline) / per_connection)
    local descriptors_allow = akkar.descriptor_ceiling(1048576)

    assert.is_true(descriptors_allow > memory_allows * 100,
      ("the derived ceiling %d is meant to be far above what memory allows " ..
       "(%d); if this failed, the measurement moved and the comment above " ..
       "needs remeasuring"):format(descriptors_allow, memory_allows))

    -- Pinned as an absence. `akkar.descriptor_limits` is the only limit reader
    -- there is; when a memory-derived ceiling exists this line fails and
    -- whoever added it gets told to finish the story here.
    assert.is_nil(akkar.memory_limits,
      "akkar.memory_limits now exists -- teach max_concurrent to use it, and " ..
      "replace this assertion with one about the ceiling it produces")
  end)

  it("is not derived off Linux, which is why the throttle has to exist", function()
    -- `akkar.descriptor_limits` reads `/proc/self/limits` and returns nil
    -- where there is none, so on macOS -- a platform this project runs the
    -- full suite on -- `max_concurrent` is left at lua-http's default of
    -- infinity and the server accepts until the kernel refuses. `akkar.doctor`
    -- warns about it; nothing stops it.
    assert.is_nil(akkar.descriptor_ceiling(nil))
  end)
end)
