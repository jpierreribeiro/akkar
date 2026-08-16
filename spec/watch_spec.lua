--[[
akkar.watch — save the file, the server comes back.

The loop is driven through injected `start`, `stop`, `sleep` and
`should_stop`, so the whole thing is testable without actually watching a
directory or spawning a server. That is not a convenience: a watcher tested by
watching is a test that either sleeps for real or races, and this project has
enough tests that sleep.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local watch = require "akkar.watch"

local function scratch()
  local dir = os.tmpname()
  os.remove(dir)
  os.execute("mkdir -p " .. dir)
  return dir
end

local function write(path, contents)
  local file = assert(io.open(path, "w"))
  file:write(contents)
  file:close()
end

describe("noticing a change", function()
  it("sees an edit", function()
    local dir = scratch()
    write(dir .. "/app.lua", "return 1")

    local before = watch.snapshot(watch.files { dir })
    -- `stat` has one-second resolution, so an edit inside the same second is
    -- invisible to it. The test states the granularity rather than sleeping
    -- through it.
    local after = { [dir .. "/app.lua"] = (before[dir .. "/app.lua"] or 0) + 1 }

    assert.same({ dir .. "/app.lua" }, watch.changed(before, after))
  end)

  it("sees a new file, which is what a watcher usually misses", function()
    local dir = scratch()
    write(dir .. "/app.lua", "return 1")
    local before = watch.snapshot(watch.files { dir })

    write(dir .. "/helper.lua", "return 2")
    local after = watch.snapshot(watch.files { dir })

    assert.same({ dir .. "/helper.lua" }, watch.changed(before, after))
  end)

  it("sees a deletion, so the next restart does not fail on a ghost", function()
    local dir = scratch()
    write(dir .. "/app.lua", "return 1")
    write(dir .. "/gone.lua", "return 2")
    local before = watch.snapshot(watch.files { dir })

    os.remove(dir .. "/gone.lua")
    local after = watch.snapshot(watch.files { dir })

    assert.same({ dir .. "/gone.lua" }, watch.changed(before, after))
  end)

  it("ignores what the pattern excludes", function()
    local dir = scratch()
    write(dir .. "/app.lua", "return 1")
    write(dir .. "/notes.txt", "hello")

    local found = watch.files({ dir }, "*.lua")
    assert.equal(1, #found)
    assert.is_truthy(found[1]:find("app.lua", 1, true))
  end)
end)

describe("the loop", function()
  it("starts the command once, and again for every change", function()
    local dir = scratch()
    write(dir .. "/app.lua", "return 1")

    local starts, stops, restarts = 0, 0, {}
    local tick = 0

    local result = watch.run("./myapp run app.lua", { dir }, {
      start = function() starts = starts + 1 end,
      stop  = function() stops = stops + 1 end,
      sleep = function()
        tick = tick + 1
        -- Change the file on the second tick only.
        if tick == 2 then
          write(dir .. "/app.lua", "return 2")
          local stamp = os.time() + 60
          os.execute(("touch -d @%d %q"):format(stamp, dir .. "/app.lua"))
        end
      end,
      on_restart = function(changes) restarts[#restarts + 1] = changes end,
      should_stop = function() return tick >= 4 end,
    })

    assert.equal(1, #restarts, "expected exactly one restart")
    assert.equal(2, starts, "the initial start plus one restart")
    assert.equal(1, result.restarts)
    assert.equal(1, result.watching)

    -- Stopped before every start, and once more on the way out, so nothing is
    -- left holding the port.
    assert.equal(3, stops)
  end)

  it("does not restart when nothing changed", function()
    local dir = scratch()
    write(dir .. "/app.lua", "return 1")

    local starts, tick = 0, 0
    watch.run("./myapp", { dir }, {
      start = function() starts = starts + 1 end,
      stop  = function() end,
      sleep = function() tick = tick + 1 end,
      should_stop = function() return tick >= 5 end,
    })

    assert.equal(1, starts, "the watcher restarted a server nothing had touched")
  end)
end)
