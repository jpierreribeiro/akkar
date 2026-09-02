--[[
The rockspec, checked against the tree it claims to describe.

Everything here is a mistake that had already been made and that nothing in
the repository would ever have caught, because NO DOCUMENTED FLOW INSTALLS THE
ROCK. The README installs dependencies (`--only-deps`) and runs from a
checkout, so the packaging was never exercised by anyone, ever.

What that hid: `bin/akkar` did not ship at all -- no `install.bin`, and `bin`
was not among the copied directories -- while `README.md` documented
`akkar doctor` as a shell command. And every dependency bound was an open
`>=`, against `docs/PLAN.md` §5 which has said "pin versions, commit the
rockspec" since the beginning.

This file is cheap and it is the only thing standing between a new module and
a rock that silently does not contain it.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

-- BOTH ROCKSPECS, and the release one is why.
--
-- `akkar-dev-1.rockspec` tracks the branch and is what a contributor installs
-- dependencies from. `akkar-0.1.0-1.rockspec` pins a tag and is what a user
-- installs. They declare the same modules, and a module added to one and not
-- the other means `luarocks install akkar` ships a package missing a file
-- while the development install works perfectly -- which nobody here would
-- ever notice.
--
-- So every check in this file runs against both, and one more check compares
-- them to each other.
local ROCKSPECS = { "akkar-dev-1.rockspec", "akkar-0.1.0-1.rockspec" }
local ROCKSPEC = ROCKSPECS[1]

local function read(path)
  local file = assert(io.open(path, "r"), "cannot read " .. path)
  local contents = file:read "a"
  file:close()
  return contents
end

--- The rockspec is Lua. Loading it beats matching patterns against it.
local function load_rockspec()
  local env = {}
  local chunk = assert(load(read(ROCKSPEC), "=" .. ROCKSPEC, "t", env))
  chunk()
  return env
end

local function lua_files_under(dir)
  local found = {}
  local pipe = assert(io.popen("find " .. dir .. " -name '*.lua' -type f 2>/dev/null"))
  for line in pipe:lines() do found[#found + 1] = line:gsub("^%./", "") end
  pipe:close()
  table.sort(found)
  return found
end

describe("the rockspec", function()
  local spec = load_rockspec()

  it("lists every module that exists on disk", function()
    -- The failure this prevents: a module added to `akkar/` and not to the
    -- rockspec installs as nothing, and the first `require` of it fails on
    -- somebody else's machine rather than on ours.
    local declared = {}
    for _, path in pairs(spec.build.modules) do declared[path] = true end

    local missing = {}
    for _, path in ipairs(lua_files_under "akkar") do
      if not declared[path] then missing[#missing + 1] = path end
    end

    assert.equal(0, #missing,
      "on disk but not in the rockspec: " .. table.concat(missing, ", "))
  end)

  it("lists no module that does not exist", function()
    local absent = {}
    for name, path in pairs(spec.build.modules) do
      local file = io.open(path, "r")
      if file then file:close() else absent[#absent + 1] = name .. " -> " .. path end
    end
    assert.equal(0, #absent,
      "in the rockspec and not on disk: " .. table.concat(absent, ", "))
  end)

  it("ships the command line, which the README tells people to run", function()
    assert.is_truthy(spec.build.install and spec.build.install.bin,
      "no install.bin: `akkar doctor` does not exist after `luarocks install`")
    assert.equal("bin/akkar", spec.build.install.bin.akkar)
  end)

  it("does not ship the benchmark harness", function()
    -- Deliberately Linux-only shell expecting docker, sudo and a reserved
    -- machine. Dead weight in an installed rock, and misleading about what
    -- akkar needs in order to run.
    for _, dir in ipairs(spec.build.copy_directories or {}) do
      assert.is_not.equal("bench", dir)
    end
  end)

  it("bounds every dependency at both ends", function()
    -- An open `>=` is how a dependency that reaches into another library's
    -- internals -- which `akkar/db.lua` does with pgmoon's socket, and says
    -- so -- breaks on a release nobody chose to take.
    local unbounded = {}
    for _, entry in ipairs(spec.dependencies) do
      if not entry:find "<" then unbounded[#unbounded + 1] = entry end
    end
    assert.equal(0, #unbounded,
      "unbounded: " .. table.concat(unbounded, "; "))
  end)

  it("allows the Lua versions the project claims to support", function()
    local lua = nil
    for _, entry in ipairs(spec.dependencies) do
      if entry:match "^lua " then lua = entry end
    end
    assert.is_truthy(lua, "no bound on lua itself")
    assert.is_truthy(lua:find "5.6", "5.5 is excluded: " .. lua)
  end)

  -- THE TEST THIS FILE EXISTED WITHOUT, AND THE ONE IT MOST NEEDED.
  --
  -- The test above asserts the rockspec allows Lua 5.5. It asserted that for
  -- months while CI ran three jobs, all of them 5.4. A version range nothing
  -- exercises is a promise, not a fact -- and this repository has now found
  -- the same shape four separate times: a claim written down, locked by an
  -- assertion about the WRITING, and never once measured.
  --
  -- So the assertion is moved down a level. It is no longer "the rockspec
  -- says 5.5"; it is "something runs 5.5". Declaring support and testing it
  -- are now one commit or neither.
  --
  -- Deliberately coarse. It greps a YAML file rather than parsing it, because
  -- what it protects against is a version being DROPPED FROM CI ENTIRELY, and
  -- no amount of parsing precision helps with that. A change subtle enough to
  -- fool this grep is a change somebody made on purpose.
  it("runs every Lua version it claims to support", function()
    local workflow = read(".github/workflows/ci.yml")

    local claimed = {}
    for _, entry in ipairs(spec.dependencies) do
      if entry:match "^lua " then
        -- `lua >= 5.4, < 5.6` means 5.4 and 5.5. The bound is exclusive, so
        -- the last supported minor is the one below it.
        local lo = entry:match ">=%s*5%.(%d)"
        local hi = entry:match "<%s*5%.(%d)"
        assert.is_truthy(lo and hi, "cannot read the lua bound: " .. entry)
        for minor = tonumber(lo), tonumber(hi) - 1 do
          claimed[#claimed + 1] = "5." .. minor
        end
      end
    end
    assert.is_true(#claimed > 0, "the rockspec declares no Lua version")

    for _, version in ipairs(claimed) do
      -- Either the matrix carries it or a job of its own does. Both shapes
      -- are legitimate: 5.4 rides the platform matrix, 5.5 needs its whole
      -- stack built from source and cannot.
      local in_matrix = workflow:find('lua: "' .. version .. '"', 1, true)
      local own_job   = workflow:find("\n  lua" .. version:gsub("%.", "") .. ":", 1, true)
      assert.is_truthy(in_matrix or own_job,
        "the rockspec supports Lua " .. version .. " and CI never runs it. "
        .. "Either add it to the matrix, give it a job, or narrow the "
        .. "rockspec bound -- but do not claim it untested.")
    end
  end)

  -- The recipe is documentation and CI input at once, and that is the only
  -- reason the page describing it cannot go stale. If CI stops running it,
  -- the file becomes prose again and nothing says so.
  it("builds the 5.5 stack from the recipe it documents", function()
    local workflow = read(".github/workflows/ci.yml")
    assert.is_truthy(workflow:find("docs/runtime/lua55-stack.sh", 1, true),
      "CI does not run docs/runtime/lua55-stack.sh: the documented recipe "
      .. "and the built one are free to diverge again")

    local recipe = read("docs/runtime/lua55-stack.sh")
    -- The pinned commit lives in three places and all three must agree.
    -- `spec/substrate_spec.lua` guards the rockspec-to-CI half; this is the
    -- half that would otherwise build 5.5 against a cqueues nobody chose.
    local pinned = workflow:match "CQUEUES_COMMIT:%s*(%x+)"
    assert.is_truthy(pinned, "CI has no CQUEUES_COMMIT")
    assert.is_truthy(recipe:find(pinned, 1, true),
      "the 5.5 recipe pins a different cqueues than CI does")
  end)

  it("keeps the CLI runnable by whatever Lua is installed", function()
    -- `#!/usr/bin/env lua5.4` is the Debian binary name. On a source build,
    -- on Homebrew, and under 5.5 it is simply not there.
    local shebang = read("bin/akkar"):match "^[^\n]*"
    assert.equal("#!/usr/bin/env lua", shebang)
  end)
end)

describe("the release rockspec", function()
  local function load_one(path)
    local env = {}
    local ok = pcall(function()
      local f = load(io.open(path):read "a", "@" .. path, "t", env)
      f()
    end)
    assert(ok, "could not load " .. path)
    return env
  end

  it("declares exactly the files its own tag contains", function()
    -- THIS CHECK USED TO COMPARE AGAINST THE DEVELOPMENT ROCKSPEC, AND THAT
    -- WAS BACKWARDS.
    --
    -- Its reasoning was that a module in one and not the other means
    -- `luarocks install akkar` ships a package missing a file. True of two
    -- rockspecs over one tree -- and this one is not over this tree. It pins
    -- `source.tag`, so `luarocks` fetches THAT tarball, and the only files it
    -- can install are the ones the tag contains. Declaring a module the tag
    -- does not have does not complete the package; it breaks the build, on a
    -- file that cannot be there.
    --
    -- So keeping it in step with the moving tree made it worse on every
    -- commit, and it was kept in step deliberately: two separate pieces of
    -- work added a module to it purely to satisfy the old assertion, each
    -- flagging that it looked wrong. When the tree had drifted far enough the
    -- count told the story -- 72 modules declared, 42 files in the tag.
    --
    -- What is actually true is checked instead: a released rockspec describes
    -- its own tag. When they disagree, the release is stale and the answer is
    -- to cut a new one from the tree being tagged, never to edit this file.
    local rel = load_one "akkar-0.1.0-1.rockspec"
    local tag = rel.source.tag

    -- The tag has to be present to compare against, and a shallow clone has
    -- no tags. Pending rather than green, naming the reason: a check that
    -- cannot run must not look like a check that passed.
    local pipe = assert(io.popen(
      ("git ls-tree -r --name-only %q 2>/dev/null"):format(tag)))
    local listing = pipe:read "a"
    pipe:close()
    if not listing:match "%S" then
      pending("tag " .. tag .. " is not in this clone (a shallow checkout has "
              .. "no tags); run `git fetch --tags` to check the release "
              .. "rockspec against it")
      return
    end

    local in_tag = {}
    for path in listing:gmatch "[^\n]+" do in_tag[path] = true end

    local absent = {}
    for _, path in pairs(rel.build.modules) do
      if not in_tag[path] then absent[#absent + 1] = path end
    end
    table.sort(absent)

    assert.equal(0, #absent,
      ("the release rockspec declares %d file(s) that %s does not contain, so "
       .. "`luarocks install akkar` would fetch that tag and fail to find "
       .. "them. Cut a new version from the tree you are tagging rather than "
       .. "editing this rockspec: %s"):format(#absent, tag,
                                              table.concat(absent, ", ")))
  end)

  it("pins a tag, because a release must not track a branch", function()
    -- `luarocks install` from a moving branch gives two people different code
    -- under one version number.
    local rel = load_one "akkar-0.1.0-1.rockspec"
    assert.is_string(rel.source.tag, "the release rockspec has no tag")
    assert.equal("v" .. rel.version:match "^([^-]+)", rel.source.tag)
  end)

  it("carries a version that is not `dev`", function()
    local rel = load_one "akkar-0.1.0-1.rockspec"
    assert.is_truthy(rel.version:match "^%d+%.%d+%.%d+%-%d+$",
      "unexpected version string: " .. tostring(rel.version))
  end)
end)
