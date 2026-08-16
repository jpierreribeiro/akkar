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

local ROCKSPEC = "akkar-dev-1.rockspec"

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

  it("keeps the CLI runnable by whatever Lua is installed", function()
    -- `#!/usr/bin/env lua5.4` is the Debian binary name. On a source build,
    -- on Homebrew, and under 5.5 it is simply not there.
    local shebang = read("bin/akkar"):match "^[^\n]*"
    assert.equal("#!/usr/bin/env lua", shebang)
  end)
end)
