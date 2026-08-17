--[[
akkar.watch — save the file, the server comes back.

## What this is, and what it is not

It is `air`, and it is smaller than `air` for a reason that is worth stating:
in Go the watcher exists because `go build` takes seconds. `akkar run` does no
build at all -- the runtime is already in the binary and only the application
is read from disk -- so restarting costs the time to open one file and bind
one socket. The watcher is therefore a loop, not a build system.

It is NOT hot swapping. The process is stopped and started; anything held in
memory is gone, and a request in flight is dropped. That is the honest thing
for a development loop and the wrong thing for production, so nothing here is
reachable from `app:run`.

Hot swapping IS available and is a different feature: `App:swap_host` replaces
a running application atomically -- one Lua VM runs one coroutine at a time,
and assigning a field yields nowhere -- and a request already in flight
finishes against the app it was routed to. What it needs before being a
supported production path is an answer for capability lifetime: an application
replaced without carrying its pools over leaks every connection it held, which
is precisely the class of defect this project keeps finding.

## Polling, not inotify

`stat` on a handful of files, twice a second. inotify would be fewer syscalls
and one more C dependency, on a project whose whole build story is about
having fewer of those. A tree of a thousand files costs about a millisecond a
tick; a tree where that matters is a tree that wants a real build system.
]]

local M = {}

-- `stat -c %Y` is GNU coreutils. BSD stat -- which is what macOS has -- asks
-- the same question as `stat -f %m` and rejects `-c` outright.
--
-- The consequence was not a warning. `stat_mtime` returned nil for every
-- file, every snapshot compared nil to nil, and `akkar watch` sat there
-- reporting no changes for ever: no error, no output, a watcher that had
-- simply stopped watching. The platform matrix found it as three empty tables
-- in `spec/watch_spec.lua` and one failing example in `docs/reference/watch.md`.
--
-- Resolved once at load, by trying each spelling on a path that certainly
-- exists rather than by branching on the OS name: `uname` would be a guess
-- about which `stat` is installed, and a Linux box can have the BSD one.
local STAT_FORMAT = (function()
  for _, form in ipairs { "stat -c %%Y %q 2>/dev/null",
                          "stat -f %%m %q 2>/dev/null" } do
    local pipe = io.popen(form:format("."))
    if pipe then
      local stamp = pipe:read "l"
      pipe:close()
      if tonumber(stamp) then return form end
    end
  end
  return nil
end)()

--- Whether this machine can be watched at all.
---
--- Exposed so `bin/akkar watch` can say so instead of running a loop that
--- will never fire. Silence is the worst possible report from a watcher.
M.can_stat = STAT_FORMAT ~= nil

local function stat_mtime(path)
  -- `stat` rather than opening the file: opening a file the editor is
  -- half-way through writing gives a truncated read, and a watcher that
  -- restarts on a partial save restarts twice per keystroke.
  if not STAT_FORMAT then return nil end
  local pipe = io.popen(STAT_FORMAT:format(path))
  if not pipe then return nil end
  local stamp = pipe:read "l"
  pipe:close()
  return tonumber(stamp)
end

--- Every file the watcher should care about, under `roots`.
function M.files(roots, pattern)
  local found = {}
  for _, root in ipairs(roots) do
    local pipe = io.popen(("find %q -name %q -type f 2>/dev/null")
                          :format(root, pattern or "*.lua"))
    if pipe then
      for path in pipe:lines() do found[#found + 1] = path end
      pipe:close()
    end
  end
  table.sort(found)
  return found
end

--- A snapshot of what everything looked like.
function M.snapshot(paths)
  local seen = {}
  for _, path in ipairs(paths) do seen[path] = stat_mtime(path) end
  return seen
end

--- What changed between two snapshots, as a list of paths.
---
--- Additions and removals count, not only edits: a new module is the most
--- common thing a watcher misses, and noticing a deletion is what stops the
--- next restart failing on a file that is no longer there.
function M.changed(before, after)
  local changes = {}
  for path, stamp in pairs(after) do
    if before[path] ~= stamp then changes[#changes + 1] = path end
  end
  for path in pairs(before) do
    if after[path] == nil then changes[#changes + 1] = path end
  end
  table.sort(changes)
  return changes
end

--- Runs `command` and restarts it whenever anything under `roots` changes.
---
--- `options.on_restart(changes)` is called before each restart, and
--- `options.should_stop()` ends the loop -- both so this is testable without
--- actually watching a directory for ever.
function M.run(command, roots, options)
  options = options or {}
  local interval    = options.interval or 0.5
  local pattern     = options.pattern
  local should_stop = options.should_stop or function() return false end
  -- `sleep(1)` in a subprocess, NOT `cqueues.sleep`.
  --
  -- The watcher must run where nothing is installed -- that is the whole
  -- premise of the binary it exists to restart -- and requiring the event
  -- loop to wait half a second would make `akkar watch` need exactly the
  -- environment `akkar build` was written to stop needing. One process per
  -- tick at two ticks a second is a cost nobody will ever measure.
  local sleep = options.sleep or function(seconds)
    os.execute(("sleep %s"):format(tostring(seconds)))
  end
  -- The child's output goes to a FILE, never to /dev/null.
  --
  -- A watcher that discards it is a watcher that answers "nothing happened"
  -- when the server failed to start, and the developer has no way to find out
  -- except by running the command by hand -- which is the one thing the
  -- watcher exists to stop them doing. Written down because this session
  -- made the same mistake three times in three different harnesses.
  local log_path = options.log or "akkar-watch.out"

  -- BY PID, NEVER BY COMMAND LINE.
  --
  -- The first version stopped the child with `pkill -f <command>`, and the
  -- command appears verbatim in the WATCHER's own command line -- `akkar
  -- watch ... -- ./myapp run app.lua`. So the watcher matched the pattern,
  -- killed itself before it had started anything, and left no output at all
  -- to say why. A pattern that matches the thing doing the matching is a
  -- footgun with a very long fuse.
  local pidfile = options.pidfile or "akkar-watch.pid"

  local start = options.start or function(cmd)
    -- `setsid` gives the child its own process group, so killing it cannot
    -- reach the watcher. `$$` inside the shell that `exec`s the command is
    -- that command's eventual pid.
    os.execute(("setsid sh -c 'echo $$ > %q; exec %s' >%q 2>&1 &")
               :format(pidfile, cmd, log_path))
  end

  local stop = options.stop or function()
    local file = io.open(pidfile, "r")
    if not file then return end
    local pid = tonumber(file:read "l")
    file:close()
    if pid then
      -- The negative pid is the process GROUP, so a server that spawned
      -- workers does not leave them holding the port.
      os.execute(("kill -TERM -%d 2>/dev/null || kill -TERM %d 2>/dev/null")
                 :format(pid, pid))
    end
    os.remove(pidfile)
  end

  local watched = M.files(roots, pattern)
  local before = M.snapshot(watched)

  stop()
  start(command)
  local restarts = 0

  while not should_stop() do
    sleep(interval)

    watched = M.files(roots, pattern)
    local after = M.snapshot(watched)
    local changes = M.changed(before, after)

    if #changes > 0 then
      before = after
      restarts = restarts + 1
      if options.on_restart then options.on_restart(changes) end
      stop()
      start(command)
    end
  end

  stop()
  return { restarts = restarts, watching = #watched }
end

return M
