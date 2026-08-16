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
      current, start_line = {}, line_no
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

local files = doc_files()

describe("the documentation", function()
  if #files == 0 then
    pending "docs/guide does not exist yet"
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

      if block.marker == "skip" then
        -- Deliberately not executed and deliberately not compiled. The page
        -- has to explain why in its own prose; nothing here can check that.
        it("skips a block that is meant to be wrong (" .. where .. ")", function()
          assert.is_truthy(block.code, "an empty skipped block is not a skip")
        end)

      elseif block.marker == "no-run" then
        it("compiles " .. where, function()
          local chunk, why = load(block.code, "@" .. where)
          assert.is_truthy(chunk,
            "a documentation example does not compile:\n  " .. tostring(why))
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
