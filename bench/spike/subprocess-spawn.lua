-- SPIKE: async subprocess spawn under cqueues. NOT a module, a probe.
--
-- STATUS 2026-09-01: THE ROUND TRIP COMPLETES. The design closes, and the
-- reason it did not close before was a caller bug in this file, not a defect
-- in cqueues, in luaposix, or in fd ownership.
--
-- THE CAUSE, and it was none of the things the old header blamed. luaposix's
-- `exec(path, argv)` supplies argv[0] ITSELF -- from `path`, unless the table
-- carries an explicit index 0. So the old `exec("/usr/bin/rev", {"/usr/bin/rev"})`
-- did not run `rev`; it ran `rev /usr/bin/rev`, which reads that FILE and never
-- looks at stdin. Measured directly: while the spike hung, `ps` showed the
-- child as `/usr/bin/rev /usr/bin/rev`, `/proc/<pid>/fd/3` pointed at
-- `/usr/bin/rev`, and the process sat in state R at 100% CPU reversing its own
-- binary while the parent slept in `unix_stream_data_wait` for output that was
-- never coming. Passing `{}` -- argv[0] only -- makes the round trip pass in
-- ~0.22 s. That one edit is the entire fix.
--
-- HOW THAT WAS ISOLATED, and this is the part worth keeping. The same hang
-- reproduces with NO cqueues at all: raw `posix.sys.socket.socketpair` + fork +
-- dup2 + `unistd.exec`, blocking reads, hangs identically. The same sequence in
-- Python -- socketpair, fork, dup2, execv -- completes instantly. That pair of
-- measurements moved the fault off the event loop and onto the exec call before
-- anything else was tried.
--
-- WHAT WAS DISPROVEN BY ABLATION, each re-run with the argv fix in place and
-- the named line removed. None of these three is what unblocked it:
--   * clearing O_NONBLOCK in the child -- passes without it;
--   * `close(parent_fd)` in the child -- passes without it, confirming
--     O_CLOEXEC already closed it;
--   * `child_end:close()` in the parent -- passes without it, confirming the
--     socketpair rule: `shutdown("w")` delivers EOF even while a duplicate
--     descriptor is open. That is NOT true of a pipe, and the old header's
--     "the parent must close its copy or rev never sees EOF" was a pipe rule
--     misapplied to a socket.
--
-- BUT O_NONBLOCK IS STILL LOAD-BEARING, and it was only ever masked. cqueues
-- opens its sockets non-blocking and `dup2` shares the open file description,
-- so the child inherits it. It survives above only because the parent's bytes
-- are already in the socket buffer before `rev` first reads. Delay the parent's
-- write by 300 ms and the child fails outright -- measured:
-- `rev: stdin: 1: Resource temporarily unavailable`, exit status 1. With the
-- `F_SETFL` clear below and the same 300 ms delay: exit status 0. So the clear
-- stays; it is a real fix for a real race, just not the one that was hanging.
--
-- WHAT REMAINS OPEN, and it is not fd ownership:
--   * This spawns. It does not ISOLATE. Landlock and seccomp still need a C
--     shim, and nothing here changes that.
--   * Nothing here reaps concurrently, bounds the child's runtime, handles
--     partial reads, EINTR, or a child that never exits.
--   * Whether akkar.subprocess would ship luaposix as a separate rock the way
--     akkar-pq does is still undecided. luaposix stays OUT of
--     akkar-dev-1.rockspec.
--
-- This file is scaffolding. It proves one thing and prints its evidence.

-- Does async subprocess spawn actually work under a cqueues event loop?
--
-- The pieces exist (posix.fork/exec, cqueues socket.pair). The question is
-- whether they compose without the two failures that make fork-under-a-loop
-- hard: the child inheriting the parent's event loop and file descriptors, and
-- the parent blocking on the child's socket instead of yielding to the loop.
--
-- The fork happens BEFORE cqueues.new(), so the child never inherits a loop.
local cqueues = require "cqueues"
local socket  = require "cqueues.socket"
local posix   = require "posix"
local fcntl   = require "posix.fcntl"

local fork  = posix.fork or posix.unistd.fork
local exec  = posix.exec or (posix.unistd and posix.unistd.exec)
local dup2  = posix.dup2 or posix.unistd.dup2
local close = posix.close or posix.unistd.close
local _exit = posix._exit or (posix.unistd and posix.unistd._exit) or os.exit

-- A connected AF_UNIX pair. The parent keeps one end (pollable by cqueues),
-- the child gets the other as its stdin AND stdout.
local parent_end, child_end = socket.pair(socket.SOCK_STREAM)

-- The child needs the RAW fd of its end to dup2 onto 0 and 1. `pollfd()` gives
-- exactly that -- measured, it returns a real descriptor (4 here), not -1.
local child_fd = child_end:pollfd()
assert(child_fd and child_fd >= 0,
       "pollfd() gave no descriptor; dup2 would wire the child to nothing")
local parent_fd = parent_end:pollfd()

-- `sleep` before `exec rev` so the parent's read genuinely parks on the loop
-- long enough for the witness coroutine below to interleave. The shell replaces
-- itself with `rev`, so what the round trip talks to is still `rev`.
local TARGET_PATH = "/bin/sh"
local TARGET_ARGV = { "-c", "sleep 0.15; exec rev" }

local pid = fork()
if pid == 0 then
  -- CHILD. Diagnose to a file, because stdout/stderr are about to become the
  -- socket. This whole block is temporary spike scaffolding.
  local dbg = io.open("/tmp/child_dbg.txt", "w")
  local ok, err = pcall(function()
    dbg:write("child: fork ok, child_fd=" .. tostring(child_fd) .. "\n")

    -- Clear O_NONBLOCK before the dup2. cqueues opens its sockets non-blocking
    -- because that is what an event loop needs, and `dup2` does not copy a
    -- descriptor -- it points a second number at the SAME open file
    -- description, so the flag travels with it. Without this the child hits
    -- EAGAIN on any read that is not already satisfied by buffered bytes;
    -- proven by delaying the parent's write 300 ms, which makes `rev` exit 1
    -- with "Resource temporarily unavailable" when this line is removed.
    --
    -- Safe here: `parent_end` is a DIFFERENT description and keeps its flags.
    local flags = fcntl.fcntl(child_fd, fcntl.F_GETFL)
    dbg:write("child: flags antes=" .. string.format("%o", flags) .. "\n")
    fcntl.fcntl(child_fd, fcntl.F_SETFL, flags & ~fcntl.O_NONBLOCK)
    dbg:write("child: flags depois=" ..
              string.format("%o", fcntl.fcntl(child_fd, fcntl.F_GETFL)) .. "\n")

    -- Hygiene, not a fix: cqueues already sets O_CLOEXEC, so exec would close
    -- this anyway. Ablated -- removing it changes nothing.
    close(parent_fd)

    dbg:flush()
    dup2(child_fd, 0)
    dup2(child_fd, 1)

    -- THE FIX. luaposix supplies argv[0] from `path`; this table is argv[1..].
    -- Repeating the program name here is what made the old spike hang.
    dbg:write("child: exec " .. TARGET_PATH .. "\n"); dbg:flush()
    exec(TARGET_PATH, TARGET_ARGV)
    dbg:write("child: exec RETORNOU (falhou)\n")  -- a returning exec is a failure
  end)
  if not ok then dbg:write("child ERRO: " .. tostring(err) .. "\n") end
  dbg:close()
  _exit(127)
end

-- PARENT. Closing the child's end is fd hygiene, not an EOF requirement -- on a
-- socketpair `shutdown("w")` delivers EOF regardless. Ablated: passes without.
child_end:close()

local order, result = {}, nil
local cq = cqueues.new()

-- The proof that the loop is not blocked, and it is EVENT ORDERING, not a
-- counter. A counter passes even if the loop stalled; this cannot. The witness
-- can only land BETWEEN the write and the read if the read actually yielded.
-- Same shape as spec/akkar_spec.lua:376-406 and spec/work_spec.lua:13-34.
cq:wrap(function()
  parent_end:setmode("bn", "bn")
  parent_end:write("hello world\n")
  parent_end:flush()
  parent_end:shutdown("w")            -- send EOF so `rev` emits and exits
  order[#order + 1] = "parent wrote"
  result = parent_end:read("*l")      -- parks on the loop for ~150 ms
  order[#order + 1] = "parent read"
  parent_end:close()
end)

cq:wrap(function()
  cqueues.sleep(0.05)                 -- lands while the read is parked
  order[#order + 1] = "witness ran"
end)

local t0 = cqueues.monotime()
assert(cq:loop(5))
local elapsed = cqueues.monotime() - t0

-- Reap the child so it is not a zombie.
local wait = posix.wait or posix.sys.wait.wait
local _, _, status = wait(pid)

print(("exec rev: enviei 'hello world', recebi %q"):format(tostring(result)))
print(("ordem dos eventos: %s"):format(table.concat(order, " | ")))
print(("tempo de parede: %.3f s"):format(elapsed))
print(("filho terminou: status %s"):format(tostring(status)))

assert(result == "dlrow olleh", "rev nao devolveu a linha invertida")
assert(status == 0, "o filho nao saiu limpo")

-- If the read had blocked the loop the order would be
-- "parent wrote | parent read | witness ran".
local EXPECTED = "parent wrote | witness ran | parent read"
assert(table.concat(order, " | ") == EXPECTED,
       "o loop TRAVOU na leitura; esperava " .. EXPECTED)
print("SPIKE OK: spawn assincrono fecha, sem travar o loop")
