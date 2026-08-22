-- SPIKE: async subprocess spawn under cqueues. NOT a module, a probe.
--
-- STATUS 2026-08-20: the DESIGN CLOSES, one fd detail remains.
--
-- Proven on the box: posix.fork, posix.dup2 and posix.exec compose under a
-- cqueues loop. The child forked, redirected, and its exec SUCCEEDED --
-- `/tmp/child_dbg.txt` shows "child: chamando <exec>" with no return line,
-- which is exec replacing the image (a returning exec is a failed exec). So
-- luaposix + cqueues can spawn a real external binary, which was the open
-- question behind akkar.subprocess and the process-isolation P0.
--
-- WHAT IS LEFT: the parent passed `child_end:pollfd()` -- the cqueues wrapper's
-- descriptor -- where the child needs the RAW numeric fd to dup2 onto 0/1, and
-- the parent must close its own copy of that fd or `rev` never sees EOF. Get
-- the raw fd right and the round-trip completes. That is a socketpair/fd
-- detail, not a design flaw.
--
-- NEXT: fix the fd, prove the counter keeps advancing during the call (loop
-- not blocked), then decide whether akkar.subprocess ships luaposix as a
-- separate rock the way akkar-pq does.

-- Does async subprocess spawn actually work under a cqueues event loop?
--
-- The pieces exist (posix.fork/execp, cqueues socket.pair). The question is
-- whether they compose without the two failures that make fork-under-a-loop
-- hard: the child inheriting the parent's event loop and file descriptors, and
-- the parent blocking on the child's pipe instead of yielding to the loop.
--
-- This spike proves the smallest real thing: fork, exec `/usr/bin/rev` (which
-- reverses each line of stdin to stdout), write a line through a socketpair,
-- read the reversed line back, all WITHOUT blocking the loop -- a second
-- coroutine runs a counter the whole time and must keep advancing.
local cqueues = require "cqueues"
local socket  = require "cqueues.socket"
local posix   = require "posix"

local fork  = posix.fork or posix.unistd.fork
local execp = posix.execp or posix.unistd.execp
local exec  = posix.exec or (posix.unistd and posix.unistd.exec)
local dup2  = posix.dup2 or posix.unistd.dup2
local close = posix.close or posix.unistd.close
local _exit = posix._exit or (posix.unistd and posix.unistd._exit) or os.exit

-- A connected AF_UNIX pair. The parent keeps one end (pollable by cqueues),
-- the child gets the other as its stdin AND stdout.
local parent_end, child_end = socket.pair(socket.SOCK_STREAM)

-- The child needs the RAW fd of its end to dup2 onto 0 and 1.
local child_fd = child_end:pollfd()

local pid = fork()
if pid == 0 then
  -- CHILD. Diagnose to a file, because stdout/stderr are about to become the
  -- socket. This whole block is temporary spike scaffolding.
  local dbg = io.open("/tmp/child_dbg.txt", "w")
  local ok, err = pcall(function()
    dbg:write("child: fork ok, tipo dup2=" .. type(dup2) .. " exec=" .. type(exec) .. " execp=" .. type(execp) .. "\n")
    dbg:write("child: child_fd=" .. tostring(child_fd) .. "\n")
    dbg:flush()
    dup2(child_fd, 0)
    dup2(child_fd, 1)
    local fn = exec or execp
    dbg:write("child: chamando " .. tostring(fn) .. "\n"); dbg:flush()
    fn("/usr/bin/rev", { "/usr/bin/rev" })
    dbg:write("child: exec RETORNOU (falhou)\n")
  end)
  if not ok then dbg:write("child ERRO: " .. tostring(err) .. "\n") end
  dbg:close()
  _exit(127)
end

-- PARENT. Close the child's end so we are the only holder; an unclosed copy
-- keeps the pipe open and `rev` never sees EOF.
child_end:close()

local counter = 0
local result

local cq = cqueues.new()

-- The proof that the loop is not blocked: this runs the whole time.
cq:wrap(function()
  for _ = 1, 200 do
    counter = counter + 1
    cqueues.sleep(0.001)
  end
end)

cq:wrap(function()
  parent_end:setmode("bn", "bn")
  parent_end:write("hello world\n")
  parent_end:flush()
  parent_end:shutdown("w")            -- send EOF so `rev` emits and exits
  result = parent_end:read("*l")
  parent_end:close()
end)

local t0 = cqueues.monotime()
assert(cq:loop(5))
local elapsed = cqueues.monotime() - t0

-- Reap the child so it is not a zombie.
local wait = posix.wait or posix.sys.wait.wait
local _, _, status = wait(pid)

print(("exec rev: enviei 'hello world', recebi %q"):format(tostring(result)))
print(("contador correu ate %d durante a chamada (loop nao travou)"):format(counter))
print(("tempo de parede: %.3f s"):format(elapsed))
print(("filho terminou: status %s"):format(tostring(status)))

assert(result == "dlrow olleh", "rev nao devolveu a linha invertida")
assert(counter >= 190, "o contador nao correu; o loop TRAVOU na chamada")
print("SPIKE OK: spawn assincrono fecha, sem travar o loop")
