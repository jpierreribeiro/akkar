--- The commands the harness assumed everyone had.
---
--- The platform matrix found these on the very first macOS run, and it found
--- them all at once: of 318 failures, 299 were the same line.
---
---     sh: timeout: command not found
---     sh: setsid: command not found
---
--- `timeout` is GNU coreutils, `setsid` is util-linux, `ss` is iproute2. All
--- three are Linux, none of them is on a Mac, and the suite had been calling
--- them by name since it was written -- on the one machine that had them.
--- Nothing about akkar was wrong. The harness was.
---
--- THIS FILE ASKS THE SYSTEM, IT DOES NOT ASK WHICH SYSTEM. Branching on
--- `uname` would be a guess about which tools are installed; `command -v` is
--- the fact. A Linux box without coreutils and a Mac with `brew install
--- coreutils` are both handled without either being a special case, and the
--- lookups happen once at load rather than once per spawn.
---
--- What is deliberately NOT here: a shim that makes the fallbacks
--- indistinguishable from the real thing. `M.timeout` kills with SIGALRM
--- where `timeout` kills with SIGTERM and exits 124, so exit codes differ
--- between platforms. Callers here only read output and success, so that is
--- affordable -- but a caller that starts reading exit codes needs to know,
--- and hiding the difference is how it would fail to.

local M = {}

--- Is `name` on PATH?
---
--- `command -v` rather than `which`: `which` is not in POSIX, its exit status
--- is inconsistent across implementations, and on some systems it is a csh
--- script. `command -v` is a shell builtin and is specified.
local function have(name)
  local pipe = io.popen(("command -v %s 2>/dev/null"):format(name))
  if not pipe then return false end
  local found = pipe:read "a"
  pipe:close()
  return found ~= nil and found:match "%S" ~= nil
end

M.have = have

-- ---------------------------------------------------------------- the lua

--- The interpreter to spawn children with.
---
--- THE ONE RUNNING THIS SUITE, before any name on PATH. A spawned server has
--- to be the same Lua as the process spawning it: it inherits `LUA_PATH` and
--- `LUA_CPATH`, and those point at ONE version's modules.
---
--- Found by running the suite under Lua 5.5, where twenty-two framing cases
--- failed with `the server never started listening; it said: lua5.4:`. The
--- harness had resolved `lua5.4` from PATH -- correctly, it was there -- and
--- handed it 5.5's module paths, so every spawned server died on the first
--- `require`. That read as twenty-two protocol defects and was one harness
--- assumption.
---
--- RESOLVED WITHOUT A SUBPROCESS, and the first attempt shows why that
--- matters. It ran `readlink -f /proc/self/exe` through `io.popen` and got
--- back `/usr/bin/readlink`: inside the popen'd process, `/proc/self` IS
--- readlink. That is the identical mistake `spec/concurrency_spec.lua`
--- documents for descriptor counting -- "reading /proc/self/fd through
--- io.popen measures the SUBPROCESS" -- made again in a new place.
---
--- `/proc/self/cmdline` first: its first NUL-separated field is argv[0], which
--- IS the interpreter, and reading a file spawns nothing.
---
--- AND `arg[-1]` IS NOT THE INTERPRETER, which was the second wrong guess
--- here. luarocks launches busted as
---
---     lua5.4 -e 'package.path=...' /path/to/busted
---
--- so `arg[-1]` is that `-e` chunk, `arg[-2]` is `-e`, and the interpreter is
--- at `arg[-3]`. Handing the chunk to a shell produced 407 failures reading
--- `sh: 1: Syntax error: "(" unexpected`. The interpreter is at the MOST
--- NEGATIVE index, whatever that turns out to be, so the walk finds it rather
--- than assuming its depth.
local function running_interpreter()
  local f = io.open("/proc/self/cmdline", "rb")
  if f then
    local raw = f:read "a" or ""
    f:close()
    local argv0 = raw:match "^[^%z]+"
    if argv0 and argv0 ~= "" then return argv0 end
  end
  if type(arg) == "table" then
    local i = 0
    while arg[i - 1] ~= nil do i = i - 1 end
    if i < 0 and type(arg[i]) == "string" and arg[i] ~= "" then return arg[i] end
  end
  return nil
end

M.lua = os.getenv "AKKAR_LUA"
  or running_interpreter()
  or (have "lua5.4" and "lua5.4")
  or (have "lua" and "lua")
  or "lua5.4"                    -- report the missing name we actually expect

-- ------------------------------------------------------------- the timeout

local TIMEOUT = (have "timeout" and "timeout")
  or (have "gtimeout" and "gtimeout")   -- coreutils under Homebrew's g-prefix
  or nil

--- Wraps `command` so it cannot run longer than `seconds`.
---
--- The fallback is perl's `alarm`, which is on macOS by default and on the
--- Ubuntu runners: it sets the alarm and then `exec`s, so there is no wrapper
--- process left holding the pipe and the child's output still comes back
--- whole. If perl is missing too this raises rather than returning the command
--- unbounded, because the caller that most needs a bound is the one waiting
--- for a server that never exits, and it would wait for ever.
function M.timeout(seconds, command)
  if TIMEOUT then
    return ("%s %d %s"):format(TIMEOUT, seconds, command)
  end
  assert(have "perl",
    "no `timeout`, no `gtimeout` and no `perl`: cannot bound a child process. "
    .. "On macOS, `brew install coreutils` provides `gtimeout`.")
  return ("perl -e 'alarm shift; exec @ARGV' %d %s"):format(seconds, command)
end

-- ------------------------------------------------------------ the detaching

local SETSID = have "setsid" and "setsid " or ""

--- Runs `command` in the background with its output in `logfile`.
---
--- `setsid` puts the child in its own session so it survives the shell that
--- started it. Without it, a plain `&` is enough for what these specs do:
--- `os.execute` runs `sh`, `sh` exits immediately, and the child is reparented
--- rather than killed. `disown` is NOT the fallback -- it is a bashism, and
--- `sh` reported "disown: not found" and left a reader wondering why the
--- server had not started.
---
--- The output goes to a FILE, never to /dev/null. A harness that cannot say
--- why the server did not start is a harness that costs an afternoon.
function M.detached(command, logfile)
  return ("%s%s >%q 2>&1 &"):format(SETSID, command, logfile)
end

-- ---------------------------------------------------------------- the ports

--- Is anything listening on `port`? Returns nil when it cannot be determined.
---
--- nil is a real answer and callers must treat it as one. Binding the port
--- ourselves to find out races with whatever we are trying to detect, and a
--- false "free" is worse than no answer at all.
function M.port_in_use(port)
  local command
  if have "ss" then
    command = ("ss -ltn 2>/dev/null | grep -c ':%d '"):format(port)
  elseif have "lsof" then
    -- -sTCP:LISTEN so an outgoing connection to that port elsewhere on the
    -- machine does not read as a server holding it here.
    command = ("lsof -nP -iTCP:%d -sTCP:LISTEN -t 2>/dev/null | grep -c ."):format(port)
  else
    return nil
  end
  local pipe = io.popen(command)
  if not pipe then return nil end
  local count = tonumber(pipe:read "a")
  pipe:close()
  if not count then return nil end
  return count > 0
end

--- The pid of whatever is listening on `port`, or nil.
---
--- Stopping a spawned server by port rather than by name is deliberate:
--- `pkill -f lua5.4` in a suite that spawns interpreters is a way to kill the
--- suite. That reason does not change across platforms; only the tool does.
function M.pid_on_port(port)
  local command
  if have "ss" then
    command = ("ss -ltnp 2>/dev/null | awk '/:%d /{print $NF}'"):format(port)
  elseif have "lsof" then
    -- -t prints the pid alone, which is the whole reason to prefer it here.
    command = ("lsof -nP -iTCP:%d -sTCP:LISTEN -t 2>/dev/null"):format(port)
  else
    return nil
  end
  local pipe = io.popen(command)
  if not pipe then return nil end
  local out = pipe:read "a" or ""
  pipe:close()
  -- `ss` reports `users:(("lua5.4",pid=123,fd=9))`; `lsof -t` reports `123`.
  return out:match "pid=(%d+)" or out:match "^%s*(%d+)"
end

-- ------------------------------------------------------------ the /proc bits

local HAVE_PROC = (function()
  local f = io.open("/proc/self/stat", "r")
  if not f then return false end
  f:close()
  return true
end)()

M.have_proc = HAVE_PROC

--- This process's pid.
---
--- Not the subprocess's. Reading `/proc/self/fd` through `io.popen` measures
--- the CHILD, which is a mistake this project has already made once, so the
--- pid is resolved here and passed down.
---
--- `$PPID` is the portable half: `io.popen` runs a shell, and that shell's
--- parent is this interpreter. It is what answers on a machine with no /proc.
M.pid = (function()
  if HAVE_PROC then
    local f = io.open("/proc/self/stat", "r")
    local line = f:read "l"
    f:close()
    local pid = line and line:match "^(%d+)"
    if pid then return tonumber(pid) end
  end
  local pipe = io.popen "echo $PPID"
  if not pipe then return nil end
  local out = pipe:read "a"
  pipe:close()
  return tonumber((out or ""):match "%d+")
end)()

--- How many descriptors `pid` has open, or nil when it cannot be counted.
---
--- THE TWO ANSWERS ARE NOT THE SAME NUMBER. /proc counts descriptors; `lsof`
--- additionally lists the cwd, the executable and every mapped library. A
--- caller comparing a count against a constant will get a different answer on
--- each platform and must not; a caller comparing two counts from the same
--- process -- which is what leak detection does -- gets the same DELTA from
--- both, because the extra rows do not move.
---
--- nil means "no answer", and callers must report that as pending rather than
--- as a leak of unknown size.
function M.open_fds(pid)
  pid = pid or M.pid
  if not pid then return nil end
  if HAVE_PROC then
    local pipe = io.popen(("ls /proc/%d/fd 2>/dev/null | wc -l"):format(pid))
    if not pipe then return nil end
    local n = tonumber(pipe:read "l")
    pipe:close()
    return n
  end
  if have "lsof" then
    local pipe = io.popen(("lsof -p %d 2>/dev/null | tail -n +2 | wc -l"):format(pid))
    if not pipe then return nil end
    local n = tonumber(pipe:read "l")
    pipe:close()
    -- 0 means lsof answered nothing, which for a live process means it was
    -- refused rather than that the process holds nothing.
    if n == 0 then return nil end
    return n
  end
  return nil
end

--- What `uname -s` says, or nil.
---
--- Everything else in this file refuses to branch on the OS name, and this is
--- the exception that proves the rule: it exists for facts that are genuinely
--- properties of the kernel rather than of what happens to be installed. A
--- cqueues controller costs two descriptors on epoll and three on kqueue --
--- that IS the operating system, and asking `command -v` about it would be
--- asking the wrong question.
M.os_name = (function()
  local pipe = io.popen "uname -s 2>/dev/null"
  if not pipe then return nil end
  local name = (pipe:read "l" or ""):match "%S+"
  pipe:close()
  return name
end)()

--- What one cqueues controller costs here, or nil where nobody has measured.
---
--- MEASURED, on both platforms, and the numbers are not the same:
---
---     Linux  (epoll)   2.00 per controller
---     Darwin (kqueue)  3.00 per controller
---
--- The Linux number was confirmed with /proc and with `lsof` on the same 50
--- controllers -- both said exactly 2.00 -- so the Darwin number is a
--- substrate difference and not an artefact of counting it differently there.
---
--- This is the concurrency ceiling: `descriptor_ceiling` in `akkar/init.lua`
--- divides the descriptor limit by this number. It divides by 2
--- unconditionally, which is right on Linux and would over-promise by half on
--- a Mac -- today that is latent, because the same function reads
--- /proc/self/limits and so derives nothing at all off Linux.
---
--- nil for anything else on purpose: a guess here becomes a wrong ceiling.
M.descriptors_per_controller =
  (M.os_name == "Linux"  and 2)
  or (M.os_name == "Darwin" and 3)
  or nil

-- ----------------------------------------------------------------- the mtime

--- Sets `path`'s modification time to `epoch`.
---
--- `touch -d @1700000000` is GNU. BSD touch -- which is what a Mac has --
--- rejects it and wants `-t [[CC]YY]MMDDhhmm[.SS]`, a format GNU touch also
--- accepts. So the portable spelling is the BSD one, formatted here rather
--- than passed through, and `os.date` does the conversion both understand.
function M.touch_at(path, epoch)
  local stamp = os.date("%Y%m%d%H%M.%S", epoch)
  return os.execute(("touch -t %s %q"):format(stamp, path))
end

return M
