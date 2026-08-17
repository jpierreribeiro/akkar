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

Every fenced ```lua block under `docs/guide/`, `docs/recipes/`,
`docs/reference/` and `docs/why/` is extracted and executed in its own
process, with the repository on the path. A block that raises fails this spec.

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

local portable = require "spec.support.portable"

local TMP = os.getenv "CLAUDE_JOB_DIR"
TMP = (TMP and TMP .. "/tmp") or "/tmp"

-- SCOPED TO THE GUIDE AND THE REFERENCE, and the boundary is deliberate.
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
--
-- The reference joined the guide for the same reason, not by extension of the
-- rule. A reference page is looked up by somebody who copies one function's
-- example, pastes it, and expects it to work -- so its examples are
-- instructions too, and the signature above an example that no longer runs is
-- a signature nobody should trust either. Reference is also the part of any
-- documentation that rots first, because it tracks the code line by line.
--
-- `docs/why/` is in for a narrower reason, and it is NOT the design-document
-- rule being reversed. Those pages are arguments and most of their blocks are
-- fragments, marked `no-run` and only compiled. But a handful of them exist to
-- EXECUTE the argument -- the page on sessions ends by destroying one and
-- reading the store back, and that print is the claim it spent a screen
-- making. A demonstration that has stopped demonstrating is worse than a
-- fragment, because it looks like evidence. So the fragments are marked and
-- the demonstrations run.
--
-- `docs/recipes/` is in for the plainest reason of the four. A recipe is one
-- page, one problem, and one complete file the reader copies whole and runs
-- without reading anything else -- so a recipe that has rotted is not a
-- misleading paragraph, it is a file that does not work, pasted by somebody
-- who has no page before it to compare against. Nearly every block there is a
-- whole server, which this already knows how to start and kill. The two
-- exceptions are marked: a busted spec, which `busted` runs and `lua5.4` does
-- not, and the configuration page, whose file deliberately refuses to start
-- when the environment is missing a required setting.
--
-- `docs/sql/` is a tutorial track, so it is in for the guide's reason rather
-- than a new one: a reader follows it literally and types from it. It earns a
-- line of its own only because of what its blocks DO. Nearly every one of them
-- prints the SQL a builder produced, or the row a real Postgres answered with,
-- and the page shows that output as the thing being taught. An example whose
-- printed statement no longer matches the module is not a stale paragraph, it
-- is a lesson teaching the wrong text, and nothing but running it can tell.
-- Its database examples create their own `sqlguide_`-prefixed tables and drop
-- them again, so the track leaves the shared database as it found it.
local DOC_DIRS = { "docs/guide", "docs/recipes", "docs/reference", "docs/sql",
                   "docs/why" }

--- Every markdown file under the documented directories, sorted so failures
--- are reported in a stable order rather than in whatever order the
--- filesystem answers.
local function doc_files()
  local found = {}
  for _, dir in ipairs(DOC_DIRS) do
    local pipe = io.popen(("find %s -name '*.md' -type f 2>/dev/null"):format(dir))
    if pipe then
      for path in pipe:lines() do found[#found + 1] = path end
      pipe:close()
    end
  end
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

-- A TOKEN UNIQUE TO THIS PROCESS, and it is not decoration.
--
-- The temp file used to be named `docs-example-<os.time()>-<index>`, which is
-- unique within one run and NOT unique across two. Two suites running at the
-- same second -- two people, two agents, a watch loop and a terminal -- pick
-- the same path for the same block index, and each then executes whatever the
-- other wrote there.
--
-- That failure does not look like a collision. It was found as
-- `docs/reference/vm.md` failing with `INFO listening url=http://127.0.0.1:3000`
-- in its output: a page about sandboxing that binds no port, reported as
-- starting a web server, because the other run's guide example had landed in
-- the file a moment before it was read. Whoever hits that goes looking for a
-- server in a page that has none.
--
-- `os.tmpname` is the unique part, taken once. It creates the file on POSIX,
-- so it is removed again immediately; only the name is wanted.
local RUN_TOKEN
do
  local probe = os.tmpname()
  os.remove(probe)
  RUN_TOKEN = probe:gsub("%W", "")
end

local function write_temp(code, index)
  local path = ("%s/docs-example-%s-%d.lua"):format(TMP, RUN_TOKEN, index)
  local file = assert(io.open(path, "w"))
  -- The path prelude is added rather than required of every page: a beginner
  -- reading the docs runs `lua app.lua` from their own project, where akkar is
  -- installed, and making every example carry a `package.path` line would put
  -- noise in front of the thing being taught.
  -- THE CHILD IS A FRESH INTERPRETER and inherits nothing but the environment.
  -- Appending to *its* `package.path` only works if `LUA_PATH` happens to be
  -- exported, which is true when luarocks is wired through the shell and false
  -- when it is wired through a wrapper script on PATH. On the second kind of
  -- shell this file reported six documentation examples as broken when the
  -- truth was "the child could not find cqueues" -- a failure that blames the
  -- docs for the harness.
  --
  -- So the parent's own resolved paths are written in, not appended to. This
  -- process already found akkar and its dependencies; the child is told where.
  file:write(("package.path = %q\n"):format("./?.lua;./?/init.lua;" .. package.path))
  file:write(("package.cpath = %q\n"):format("./?.so;" .. package.cpath))
  file:write(code)
  file:close()
  return path
end

local function run(path, seconds)
  -- Bounded through `spec/support/portable`, because `timeout` is coreutils
  -- and a Mac does not have it. This one line was 299 of the 318 failures the
  -- first macOS run reported, all of them reading as broken documentation.
  local command = portable.timeout(seconds or 10,
    ("%s %q"):format(portable.lua, path)) .. " 2>&1"
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
-- A BLOCK THAT NEEDS A DATABASE MUST NOT FAIL WHERE THERE IS NONE.
--
-- Every other spec in this suite skips when Postgres is unreachable, and this
-- one did not -- so the moment `docs/sql/` arrived, CI's `unit` job (which
-- deliberately runs with no services) went red with twenty-one failures that
-- all said "Connection refused". The pages were right; the runner had no
-- notion that an example could need anything.
--
-- Detected rather than declared, for the same reason the server blocks are
-- detected: a marker required on the common case is a marker that gets
-- forgotten, and there are hundreds of blocks. A fence marker still works as
-- an override for anything detection misses.
--
-- The check CONNECTS. This project has shipped a skip guard that never
-- checked anything -- `spec/db_spec.lua` assumed a factory call meant a live
-- server, and every database test silently did not run while the suite stayed
-- green. `cqueues.socket.connect` builds lazily and succeeds with nothing
-- listening, so the probe has to speak.
local cqueues = require "cqueues"
local socket  = require "cqueues.socket"

local function reachable(host, port)
  local ok = false
  local cq = cqueues.new()
  cq:wrap(function()
    local conn = socket.connect(host, port)
    if not conn then return end
    conn:setmode("bn", "bn")
    conn:onerror(function(_, _, why) return why end)
    -- Writing a byte is what distinguishes "the port is open" from "connect
    -- returned an object". A closed port fails here, not above.
    ok = conn:write("\n") ~= nil
    conn:close()
  end)
  cq:loop(2)
  return ok
end

local HAVE_POSTGRES = reachable("127.0.0.1", 55432)
local HAVE_REDIS    = reachable("127.0.0.1", 6379)

--- Which service, if any, a block cannot run without.
local function needs(code, marker)
  if marker == "needs-db" then return "postgres" end
  if marker == "needs-redis" then return "redis" end
  if code:find("55432", 1, true)
     or code:find("akkar.db", 1, true)
     or code:find("akkar.migrate", 1, true)
     or code:find('require "akkar.pq"', 1, true) then
    return "postgres"
  end
  if code:find("6379", 1, true)
     or code:find("akkar.redis", 1, true)
     or code:find("jobs.redis", 1, true) then
    return "redis"
  end
  return nil
end

local GUIDE_PORT = 3000

local function port_is_free()
  -- Asking the system rather than binding a socket ourselves: binding and
  -- closing races with whatever we are trying to detect, and a false "free"
  -- is worse than no check at all. `ss` is iproute2 and a Mac answers this
  -- with `lsof`, which is why the lookup lives in `portable`.
  local in_use = portable.port_in_use(GUIDE_PORT)
  if in_use == nil then return true end     -- cannot tell: run anyway
  return not in_use
end

local files = doc_files()

describe("the documentation", function()
  if #files == 0 then
    pending "neither docs/guide nor docs/reference exists yet"
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

      elseif block.marker == "server" and
             ((needs(block.code, block.marker) == "postgres" and not HAVE_POSTGRES)
              or (needs(block.code, block.marker) == "redis" and not HAVE_REDIS)) then
        it("skips server " .. where .. ", which needs a service", function()
          assert.is_truthy(block.code)
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
          -- The interpreter prefixes its errors with its own argv[0], so the
          -- pattern has to be the name we actually spawned rather than the
          -- Debian one: on a source-built Lua it is `lua:`, not `lua5.4:`.
          assert.is_falsy(output:match(portable.lua:gsub("%p", "%%%0") .. ":.*error"),
            "a server example failed to start:\n" .. output)
          assert.is_true(os.clock() - started >= 0,
            "unreachable, kept so the timing variable is used")
        end)

      else
        local wants = needs(block.code, block.marker)
        local missing = (wants == "postgres" and not HAVE_POSTGRES)
                     or (wants == "redis" and not HAVE_REDIS)

        it((missing and ("skips " .. where .. ", which needs " .. wants)
                     or ("runs " .. where)), function()
          -- Not a silent skip: the test name says which service was missing,
          -- so a run with fewer examples than expected explains itself in the
          -- output rather than in somebody's head.
          if missing then return end
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
      "no Lua examples were extracted from " .. #files .. " pages -- " ..
      "the extractor is broken, since a guide page with no runnable example " ..
      "in it is not teaching anybody to write code, and a reference page " ..
      "with none is not showing anybody how to call the function")
  end)
end)
