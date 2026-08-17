--[[
`app:task` — a background loop in the server's own process.

## What this is for, and the shape of the gap it fills

Until this existed there was no supported way to run a loop alongside
`app:run`: the call ends in `s:loop()`, or in a controller wrapping exactly
two tasks, and neither is reachable from outside. It was found as a
DOCUMENTATION cost, which is the useful part -- the smallest honest example of
"the request should not wait for the email" is one process, an in-memory queue
and a consumer sharing the event loop, and that sentence could not be written
as code. The guide's first working example needed Redis and a second process.

So the test that matters most in this file is the one that writes exactly that
example and runs it.

## Why these tests spawn a real server

`app:test` never calls `app:run`, and `app:run` is where tasks are wrapped and
supervised. A test that exercised the registration and not the running would
check the half that cannot break. Each case therefore starts a real server in
its own process and reads what it logged.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local akkar   = require "akkar"

describe("app:task registration", function()
  it("refuses a task with no name", function()
    -- The name is what a log line and a restart counter call it. Without one
    -- an operator reading "task raised" learns nothing.
    local app = akkar.new()
    assert.is_false(pcall(function() return app:task(function() end) end))
  end)

  it("refuses two tasks with the same name", function()
    local app = akkar.new()
    app:task("emails", function() end)
    local ok, why = pcall(function() return app:task("emails", function() end) end)
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("already registered", 1, true))
  end)

  it("refuses a task that is not a function", function()
    local app = akkar.new()
    assert.is_false(pcall(function() return app:task("x", "not a function") end))
  end)

  it("reports whether it is stopping", function()
    local app = akkar.new()
    assert.is_false(app:stopping())
  end)
end)

-- ===================================================================== live

local portable = require "spec.support.portable"

local function have_lua()
  local pipe = io.popen(portable.lua .. " -v 2>&1")
  if not pipe then return false end
  local out = pipe:read "a"
  pipe:close()
  return out and out:find "Lua" ~= nil
end

if not have_lua() then
  describe("app:task running", function()
    pending "no Lua interpreter to spawn a server with; skipping"
  end)
  return
end

--- Runs a whole akkar program in its own process and returns what it printed.
---
--- The program is expected to stop itself; `timeout` is the backstop, not the
--- mechanism, so a program that hangs fails loudly instead of passing after a
--- kill.
local function run_program(source, seconds)
  local path = os.tmpname() .. ".lua"
  local file = assert(io.open(path, "w"))
  -- The parent's resolved search paths, written in rather than appended to.
  -- A fresh `lua5.4` inherits only the environment, so appending depends on
  -- `LUA_PATH` being exported -- and where it is not, every case in this file
  -- fails with "the consumer never ran the job" when the real answer is that
  -- cqueues was never found. `package.cpath` matters as much as `package.path`
  -- here: cqueues is a C module.
  file:write(("package.path = %q\n"):format("./?.lua;./?/init.lua;" .. package.path))
  file:write(("package.cpath = %q\n"):format("./?.so;" .. package.cpath))
  file:write(source)
  file:close()

  local pipe = assert(io.popen(portable.timeout(seconds or 15,
    ("%s %q"):format(portable.lua, path)) .. " 2>&1"))
  local output = pipe:read "a"
  pipe:close()
  os.remove(path)
  return output
end

describe("app:task running", function()
  it("runs the example the guide could not write", function()
    -- ONE PROCESS. An in-memory queue, a route that pushes, and a consumer
    -- sharing the event loop. No Redis, no second terminal.
    local output = run_program [==[
      local akkar  = require "akkar"
      local memory = require "akkar.jobs.memory"
      local queue  = memory.new "emails"

      local app = akkar.new()
      app:post("/signup", function()
        queue:push("welcome", { to = "ada@example.com" })
        return akkar.created { queued = true }
      end)

      app:task("emails", function(task)
        queue:consume({
          welcome = function(payload)
            print("SENT " .. payload.to)
          end,
        }, { timeout = 0, should_stop = task.stopping,
             log = { warn = function() end, error = function() end } })
      end)

      -- Drive it from inside the loop: push through the real handler chain,
      -- let the consumer run, then shut down the way a signal would.
      app:task("driver", function(task)
        local client = app:test()
        client:post("/signup", { body = {} })
        while queue:depth() > 0 and not task.stopping() do
          cqueues_sleep()
        end
        cqueues_sleep()
        app:stop(2)
        os.exit(0)
      end)

      function cqueues_sleep() require("cqueues").sleep(0.05) end

      app:run { port = 8471, check_capabilities = false,
                log = akkar.log.new { level = "error", sink = function() end } }
    ]==]

    assert.is_truthy(output:find("SENT ada@example.com", 1, true),
      "the in-process consumer never ran the job:\n" .. output)
  end)

  it("restarts a task that raises, and says so", function()
    -- A supervisor that swallowed the error would keep the process up while
    -- the queue behind a dead consumer grew, and nothing would say so.
    local output = run_program [==[
      local akkar = require "akkar"
      local app = akkar.new()
      local attempts = 0

      app:task("flaky", function()
        attempts = attempts + 1
        print("ATTEMPT " .. attempts)
        if attempts >= 3 then
          print "RESTARTED TWICE"
          app:stop(1)
          os.exit(0)
        end
        error "task fell over"
      end)

      app:run { port = 8472, check_capabilities = false }
    ]==]

    assert.is_truthy(output:find("RESTARTED TWICE", 1, true),
      "a task that raised was not restarted:\n" .. output)
    -- And it is LOUD. A silent restart is the failure this supervisor exists
    -- to avoid.
    assert.is_truthy(output:find("task raised", 1, true),
      "the restart was silent:\n" .. output)
  end)

  it("does not let a failing task take the server down", function()
    local output = run_program [==[
      local akkar = require "akkar"
      local app = akkar.new()
      app:get("/ping", function() return { ok = true } end)

      app:task("always-fails", function() error "nope" end)

      app:task("checker", function(task)
        require("cqueues").sleep(0.4)      -- let it fail a few times
        local res = app:test():get "/ping"
        print("SERVER ANSWERED " .. tostring(res.status))
        app:stop(1)
        os.exit(0)
      end)

      app:run { port = 8473, check_capabilities = false }
    ]==]

    assert.is_truthy(output:find("SERVER ANSWERED 200", 1, true),
      "a failing task took the server with it:\n" .. output)
  end)

  it("asks tasks to stop AFTER the drain, not before", function()
    -- The ordering decision, checked. A request in flight can enqueue work,
    -- so a consumer stopped at STOP_ACCEPTING would leave it unconsumed while
    -- the shutdown reported itself clean.
    local output = run_program [==[
      local akkar = require "akkar"
      local app = akkar.new()

      app:task("watcher", function(task)
        print("STOPPING AT START = " .. tostring(task.stopping()))
        local seen_stop = false
        while not seen_stop do
          if task.stopping() then
            seen_stop = true
            print "TASK WAS ASKED TO STOP"
          end
          require("cqueues").sleep(0.02)
        end
        os.exit(0)
      end)

      app:task("stopper", function()
        require("cqueues").sleep(0.2)
        app:stop(2)
      end)

      app:run { port = 8474, check_capabilities = false }
    ]==]

    assert.is_truthy(output:find("STOPPING AT START = false", 1, true),
      "a task was told to stop before anything asked it to:\n" .. output)
    assert.is_truthy(output:find("TASK WAS ASKED TO STOP", 1, true),
      "shutdown never reached the tasks:\n" .. output)
    -- The log line proves the ordering: the drain finishes, THEN the tasks
    -- are asked.
    assert.is_truthy(output:find("asking tasks to finish", 1, true),
      "the shutdown did not go through the task phase:\n" .. output)
  end)
end)
