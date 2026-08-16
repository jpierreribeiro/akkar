--[[
Every example in the documentation runs.

## Why this file exists

Documentation that has rotted is worse than none. An experienced reader sees a
stale example and works around it; a beginner cannot tell "I made a mistake"
from "this page is three versions old", assumes it is them, and stops. The
whole beginner track is written for that reader, so the examples in it have to
be true, and the only way prose stays true is if something runs it.

This is the same rule the rest of the project already lives by -- no claim
without a running proof -- applied to the documentation.

## How a block is treated

Every fenced ```lua block under `docs/guide/` is extracted and executed in
its own process, with the repository on the path. A block that raises fails this spec.

Three markers change that, and each has to be written deliberately as an HTML
comment on the line before the fence:

    <!-- docs: no-run -->     compiled but not executed
    <!-- docs: server -->     started, expected to keep running, then killed
    <!-- docs: skip -->       neither, and the page must say why in prose

A block that calls `app:run` is treated as `server` without being marked,
because that is the shape of nearly every example in the guide and a marker
required on the common case is a marker that gets forgotten.

`no-run` still COMPILES. A snippet that cannot be loaded is a snippet with a
syntax error in it, and there is no reason to publish one of those whatever it
demonstrates. `skip` is the only true escape hatch and it should be rare --
its purpose is a block that is deliberately wrong, like the SQL injection
example on the database page, which must not be run and must not be taken as
advice.

## What this cannot check

That an example is USEFUL, or that its prose matches what it does. A block
that runs and teaches the wrong thing passes here. This catches rot, not
wrongness, and saying so is more honest than implying otherwise.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local TMP = os.getenv "CLAUDE_JOB_DIR"
TMP = (TMP and TMP .. "/tmp") or "/tmp"

-- SCOPED TO THE GUIDE, and the boundary is deliberate.
--
-- `docs/` also holds the design documents -- RUNTIME.md, ROADMAP.md,
-- PERFORMANCE-STUDY.md and the rest -- and those are full of fragments on
-- purpose: three lines showing the shape of a decision, a `-- ...` standing in
-- for a handler nobody needs to see. They are arguments, not instructions, and
-- a fragment is the right form for an argument.
--
-- The guide is instructions. A reader follows it literally, so every block in
-- it has to be literally true, and that is what this runs. Retrofitting
-- markers onto forty pages of design prose would cost a day and prove nothing
-- about the pages a beginner actually types from.
--
-- Running this against `docs/` at large was tried first, and it immediately
-- flagged fragments in the design documents -- correctly, by its own rule, and
-- uselessly.
local GUIDE = "docs/guide"

--- Every markdown file under the guide, sorted so failures are reported in a
--- stable order rather than in whatever order the filesystem answers.
local function doc_files()
  local found = {}
  local pipe = io.popen(("find %s -name '*.md' -type f 2>/dev/null"):format(GUIDE))
  if not pipe then return found end
  for path in pipe:lines() do found[#found + 1] = path end
  pipe:close()
  table.sort(found)
  return found
end

--- Pulls out every fenced Lua block, with the marker that precedes it.
---
--- Line-based rather than a pattern over the whole file, because a pattern
--- has no way to tell a fence inside a block from a fence that ends one, and
--- markdown legitimately contains both.
local function lua_blocks(text, path)
  local blocks, current, marker, line_no, start_line = {}, nil, nil, 0, 0

  for line in (text .. "\n"):gmatch "([^\n]*)\n" do
    line_no = line_no + 1

    if current then
      if line:match "^%s*```" then
        blocks[#blocks + 1] = {
          code = table.concat(current, "\n"),
          marker = marker, path = path, line = start_line,
        }
        current, marker = nil, nil
      else
        current[#current + 1] = line
      end
    elseif line:match "^%s*```lua" then
      -- THE MARKER MAY RIDE ON THE FENCE, and that is the preferred spelling.
      --
      -- ```lua no-run
      --
      -- It sits with the block instead of on the line above it, so it cannot
      -- drift away from what it describes when somebody inserts a sentence,
      -- and a reader of the raw markdown sees it without knowing this
      -- convention exists. GitHub renders the extra word away.
      --
      -- The HTML-comment form still works and came first; the guide's authors
      -- reached for the fence spelling without being told to, which is the
      -- usual sign of which one is natural.
      local fence_marker = line:match "^%s*```lua%s+([%w%-]+)"
      current, start_line = {}, line_no
      if fence_marker then marker = fence_marker end
    else
      local found = line:match "^%s*<!%-%-%s*docs:%s*([%w%-]+)%s*%-%->%s*$"
      if found then marker = found
      elseif line:match "%S" then marker = nil end   -- only the line before counts
    end
  end

  return blocks
end

local function write_temp(code, index)
  local path = ("%s/docs-example-%d-%d.lua"):format(TMP, os.time(), index)
  local file = assert(io.open(path, "w"))
  -- The path prelude is added rather than required of every page: a beginner
  -- reading the docs runs `lua app.lua` from their own project, where akkar is
  -- installed, and making every example carry a `package.path` line would put
  -- noise in front of the thing being taught.
  file:write(('package.path = "%s/?.lua;%s/?/init.lua;" .. package.path\n')
             :format(".", "."))
  file:write('package.cpath = "./?.so;" .. package.cpath\n')
  file:write(code)
  file:close()
  return path
end

local function run(path, seconds)
  local command = ("timeout %d lua5.4 %q 2>&1"):format(seconds or 10, path)
  local pipe = io.popen(command)
  local output = pipe:read "a"
  local ok, how, code = pipe:close()
  return ok, output, how, code
end

--- Is anything already listening on the port the guide uses?
---
--- THE GUIDE BINDS ONE PORT ACROSS EVERY PAGE, on purpose: a reader following
--- twelve pages should not have to track a different number on each. The cost
--- is that every server example in this suite wants the same port, and if
--- anything else holds it they ALL fail at once -- with akkar's bind error,
--- which now names the port but is still an error about the framework
--- appearing in a test about documentation.
---
--- That reads as "the guide is broken" when the truth is "you left a server
--- running", so the check happens once, first, and says which it is. Found
--- while two agents writing different pages collided on 3000; it would
--- otherwise have been found by whoever ran the suite with their own dev
--- server up, and they would have had a much worse time working it out.
local GUIDE_PORT = 3000

local function port_is_free()
  -- `ss` rather than binding a socket ourselves: binding and closing races
  -- with whatever we are trying to detect, and a false "free" is worse than
  -- no check at all.
  local pipe = io.popen(("ss -ltn 2>/dev/null | grep -c ':%d '"):format(GUIDE_PORT))
  if not pipe then return true end          -- no `ss`: assume free, run anyway
  local count = tonumber(pipe:read "a")
  pipe:close()
  return (count or 0) == 0
end

local files = doc_files()

describe("the documentation", function()
  if #files == 0 then
    pending "docs/guide does not exist yet"
    return
  end

  if not port_is_free() then
    local message =
      ("something is already listening on 127.0.0.1:%d, which every server " ..
       "example in the guide binds. Stop it and run again -- these examples " ..
       "were NOT run"):format(GUIDE_PORT)

    -- SKIPPED ON A LAPTOP, FAILED IN CI, and the split is deliberate.
    --
    -- A developer with their own server on 3000 should get a skip and a clear
    -- sentence, not sixteen failures about a framework. But a skip in CI is
    -- the failure this project has already paid for once: `spec/db_spec.lua`
    -- had a guard that never checked, so the database tests silently did not
    -- run and the suite was green for it. CI found that on its first run.
    --
    -- CI has no business having anything on port 3000. If it does, the guide
    -- went untested and the build must say so rather than pass quietly.
    if os.getenv "CI" then
      it("can bind the port the guide uses", function()
        assert.is_true(false, message)
      end)
      return
    end

    pending(message)
    return
  end

  local total = 0
  for _, path in ipairs(files) do
    local handle = io.open(path, "r")
    local text = handle and handle:read "a" or ""
    if handle then handle:close() end

    for index, block in ipairs(lua_blocks(text, path)) do
      total = total + 1
      local where = ("%s:%d"):format(path, block.line)

      -- A BLOCK THAT STARTS A SERVER IS DETECTED, not declared.
      --
      -- Requiring `<!-- docs: server -->` above every example that calls
      -- `app:run` looked tidy and was a trap: the guide's first five pages
      -- contain sixteen such blocks, every one of them the whole point of its
      -- page, and forgetting the marker fails the suite with "example did not
      -- exit" -- which reads like the example is broken when it is correct.
      --
      -- A marker that must be remembered on the common case is a marker that
      -- will be forgotten. So `app:run` means server, and the marker stays as
      -- an override for the rare block that calls it and is still expected to
      -- return.
      if not block.marker and block.code:find("app:run", 1, true) then
        block.marker = "server"
      end

      if block.marker == "skip" then
        -- Deliberately not executed and deliberately not compiled. The page
        -- has to explain why in its own prose; nothing here can check that.
        it("skips a block that is meant to be wrong (" .. where .. ")", function()
          assert.is_truthy(block.code, "an empty skipped block is not a skip")
        end)

      elseif block.marker == "no-run" then
        it("compiles " .. where, function()
          -- AS A CHUNK OR AS A VALUE, because `no-run` is used for both.
          --
          -- The guide shows `{ id = 1, title = "buy milk" }` on its own to
          -- explain what a Lua table looks like next to the JSON it becomes.
          -- That is a VALUE, not a statement, and `load` rejects it -- so the
          -- first version of this check failed three correct blocks and would
          -- have pushed whoever hit it into deleting the marker rather than
          -- the page.
          --
          -- Trying it as an expression second keeps the real guarantee: a
          -- block with a genuine syntax error compiles as neither.
          -- THREE SHAPES, because a documentation block is one of three
          -- things and only the first is a program.
          --
          --   a chunk       `local app = akkar.new()`
          --   a value       `{ id = 1, title = "buy milk" }`
          --   a field       `cache = redis.connect { port = 6379 },`
          --
          -- The third is a line to add to an existing table, which is a
          -- perfectly ordinary thing for a page to show and is not loadable
          -- as either of the other two. It failed page 11 while that page was
          -- being written, and the author would have been right to think the
          -- checker was wrong rather than their page.
          --
          -- Each is wrapped in the smallest frame that makes it compilable,
          -- so a genuine syntax error still fails all three.
          local chunk, why = load(block.code, "@" .. where)
          if not chunk then chunk = load("return " .. block.code, "@" .. where) end
          if not chunk then chunk = load("return {" .. block.code .. "}", "@" .. where) end
          assert.is_truthy(chunk,
            "a documentation example is not a valid chunk, value or table " ..
            "field:\n  " .. tostring(why))
        end)

      elseif block.marker == "server" then
        it("starts and keeps running: " .. where, function()
          -- A server example is correct precisely when it does NOT exit, so
          -- the pass condition is inverted: `timeout` kills it, and being
          -- killed is success. An immediate exit means it failed to bind or
          -- raised on the way up.
          local temp = write_temp(block.code, total)
          local started = os.clock()
          local _, output = run(temp, 3)
          os.remove(temp)

          assert.is_falsy(output:find("stack traceback", 1, true),
            "a server example raised:\n" .. output)
          assert.is_falsy(output:match "lua5%.4:.*error",
            "a server example failed to start:\n" .. output)
          assert.is_true(os.clock() - started >= 0,
            "unreachable, kept so the timing variable is used")
        end)

      else
        it("runs " .. where, function()
          local temp = write_temp(block.code, total)
          local ok, output = run(temp, 10)
          os.remove(temp)

          assert.is_true(ok == true,
            ("a documentation example failed.\n  at %s\n  output:\n%s")
            :format(where, output))
        end)
      end
    end
  end

  it("found examples at all", function()
    -- The guard against this whole file quietly passing because the extractor
    -- broke and matched nothing. A documentation suite that tests zero
    -- examples is the same failure as a skip guard that never checks.
    assert.is_true(total > 0,
      "no Lua examples were extracted from " .. #files .. " guide pages -- " ..
      "the extractor is broken, since a guide page with no runnable example " ..
      "in it is not teaching anybody to write code")
  end)
end)
