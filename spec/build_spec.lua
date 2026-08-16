--[[
akkar.build — one application, one executable.

The interesting part of this module is not that it writes C. It is that it
answers a question a general-purpose bundler cannot: WHICH MODULE DOES THIS
`luaopen_` SYMBOL BELONG TO.

Reversing the C naming convention is ambiguous. `luaopen__openssl_x509_verify_param`
could be `_openssl.x509.verify.param` or `_openssl.x509.verify_param`, and no
rule over symbols can tell -- both readings are consistent with the
convention. `luastatic` guesses, guesses wrong, and the binary dies with
"module not found" for a module that is demonstrably linked into it.

akkar does not guess, because the code that requires the module is going into
the same binary and names it exactly. Mapping FORWARD -- a module name to its
symbol -- is unambiguous, so the ambiguity disappears.

Most of what is below needs no compiler. The one test that does skips cleanly,
the same way the Teal spec does: needing a C toolchain to run the suite would
be worse than the gap it closes.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local build = require "akkar.build"

local function write_temp(name, contents)
  local dir = os.tmpname()
  os.remove(dir)
  os.execute("mkdir -p " .. dir)
  local path = dir .. "/" .. name
  os.execute("mkdir -p " .. path:gsub("/[^/]*$", ""))
  local file = assert(io.open(path, "w"))
  file:write(contents)
  file:close()
  return path, dir
end

describe("naming a native module from its symbol", function()
  it("reads an ordinary name", function()
    assert.equal("cjson", build.module_name_of "luaopen_cjson")
    assert.equal("lpeg", build.module_name_of "luaopen_lpeg")
  end)

  it("turns underscores into dots", function()
    assert.equal("http.server", build.module_name_of "luaopen_http_server")
  end)

  it("keeps a LEADING underscore, which is part of the name", function()
    -- The one the generic bundler gets wrong. `cqueues` and `luaossl` both
    -- ship their C half under a name beginning with an underscore, and a
    -- bundler that treats it as a separator produces `.cqueues` -- which
    -- nothing requires and nothing finds.
    assert.equal("_cqueues", build.module_name_of "luaopen__cqueues")
    assert.equal("_cqueues.socket", build.module_name_of "luaopen__cqueues_socket")
    assert.equal("_openssl.x509.name", build.module_name_of "luaopen__openssl_x509_name")
  end)

  it("refuses anything that is not an entry point", function()
    assert.is_nil(build.module_name_of "strlen")
    assert.is_nil(build.module_name_of "lua_pushstring")
  end)
end)

describe("naming a Lua module from its path", function()
  it("drops the extension and turns slashes into dots", function()
    assert.equal("akkar.db", build.module_name_for("/opt/tree", "/opt/tree/akkar/db.lua"))
  end)

  it("collapses init.lua, as package.path does", function()
    -- Getting this wrong makes the entry module of every package invisible:
    -- `require "akkar"` would find nothing while `akkar.init` sat embedded.
    assert.equal("akkar", build.module_name_for("/opt/tree", "/opt/tree/akkar/init.lua"))
    assert.equal("http", build.module_name_for("/opt/tree", "/opt/tree/http/init.lua"))
  end)
end)

describe("reading what the sources require", function()
  it("finds every literal require, in either quoting style", function()
    local path = write_temp("m.lua", [[
      local a = require "cqueues"
      local b = require('http.server')
      local c = require "_openssl.x509.verify_param"
    ]])
    local names = build.required_names { m = path }

    assert.is_true(names["cqueues"])
    assert.is_true(names["http.server"])
    assert.is_true(names["_openssl.x509.verify_param"])
  end)

  it("does not pretend to find a computed require", function()
    -- The honest limit, and it is the same one every tool that reads source
    -- rather than running it has.
    local path = write_temp("m.lua", [[
      local name = "cq" .. "ueues"
      local m = require(name)
    ]])
    assert.is_nil(build.required_names { m = path }["cqueues"])
  end)
end)

describe("the plan", function()
  it("prefers the name the code asks for over the rule", function()
    -- THE TEST THIS MODULE EXISTS FOR. The symbol
    -- `luaopen__openssl_x509_verify_param` reads, by rule, as
    -- `_openssl.x509.verify.param`. The module is
    -- `_openssl.x509.verify_param`, and the only thing that knows is the
    -- `require` about to be embedded beside it.
    --
    -- Verified end to end before this was written: with the rule alone the
    -- built binary died on exactly this module.
    local symbol = "luaopen__openssl_x509_verify_param"
    assert.equal("_openssl.x509.verify.param", build.module_name_of(symbol),
      "the rule no longer produces the wrong reading; this test is now moot")

    local wrapper = write_temp("openssl/x509/verify_param.lua",
                               'return require "_openssl.x509.verify_param"')
    local root = wrapper:gsub("/openssl/x509/verify_param%.lua$", "")

    local plan = build.plan {
      entry = wrapper,
      roots = { root },
      -- Standing in for `nm` output, so this test needs no archive and no
      -- toolchain.
      native = {},
    }
    -- The require is embedded, so the forward mapping can be checked.
    assert.is_true(build.required_names(plan.lua)["_openssl.x509.verify_param"],
      "the plan did not embed the wrapper that names the module")
  end)

  it("lets the caller override a name the rule cannot recover", function()
    local entry = write_temp("app.lua", "return true")
    local plan = build.plan {
      entry = entry,
      roots = {},
      native = { ["weird_name"] = "luaopen_weird_name" },
    }
    assert.equal("luaopen_weird_name", plan.native["weird_name"])
  end)

  it("embeds the entry under a name no application would pick", function()
    local entry = write_temp("app.lua", "return true")
    local plan = build.plan { entry = entry, roots = {} }
    assert.equal("__akkar_entry", plan.entry)
    assert.equal(entry, plan.lua["__akkar_entry"])
  end)
end)

describe("the emitted host", function()
  it("registers every module by its exact name", function()
    local entry = write_temp("app.lua", "print 'hello'")
    local plan = build.plan { entry = entry, roots = {} }
    plan.native = { ["_cqueues.socket"] = "luaopen__cqueues_socket" }

    local c = assert(build.emit(plan))

    assert.is_truthy(c:find('lua_setfield(L, -2, "_cqueues.socket")', 1, true),
      "the native module was not registered under its real name")
    assert.is_truthy(c:find("int luaopen__cqueues_socket(lua_State *L);", 1, true),
      "the entry point was not declared")
    assert.is_truthy(c:find('#define AKKAR_ENTRY "__akkar_entry"', 1, true))
  end)

  it("embeds the source rather than bytecode", function()
    -- Deliberate, and stated in the module: bytecode is not portable across
    -- versions or word sizes, and `akkar.vm` refuses to load it on principle
    -- because crafted bytecode escapes every sandbox ever written. A build
    -- step that embedded it would be the one place in this project treating
    -- bytecode as trustworthy.
    local entry = write_temp("app.lua", "return 'a distinctive marker'")
    local plan = build.plan { entry = entry, roots = {} }
    local c = assert(build.emit(plan))

    -- The marker, byte by byte, as a hex array. Whitespace is stripped from
    -- both sides: the emitter wraps every sixteen bytes, so a marker longer
    -- than that is split across lines and a contiguous search would be
    -- testing the line width rather than the contents.
    local marker = "a distinctive marker"
    local hex = {}
    for i = 1, #marker do
      hex[#hex + 1] = string.format("0x%02x,", marker:byte(i))
    end

    local flat = c:gsub("%s+", "")
    assert.is_truthy(flat:find(table.concat(hex), 1, true),
      "the source was not embedded verbatim")
  end)
end)

describe("producing the archives", function()
  it("knows the libraries akkar itself needs", function()
    -- Recipes rather than one algorithm, and the module says why: every C
    -- rock builds differently, and a generic "compile every .c" gets three of
    -- these four wrong.
    for _, name in ipairs { "cqueues", "luaossl", "lua-cjson", "lpeg" } do
      assert.is_truthy(build.recipes[name], "no recipe for " .. name)
    end
  end)

  it("compiles cjson without the file that would collide", function()
    -- `fpconv.c` and `dtoa.c` each define `fpconv_strtod`; archiving both is
    -- a duplicate symbol at link time and nowhere else.
    local sources = build.recipes["lua-cjson"].sources
    local named = {}
    for _, file in ipairs(sources) do named[file] = true end

    assert.is_true(named["fpconv.c"])
    assert.is_nil(named["dtoa.c"], "dtoa.c and fpconv.c cannot both be archived")
  end)

  it("tells luaossl not to look itself up dynamically", function()
    -- Without this the built binary dies at startup on a `dlopen` of its own
    -- executable -- see docs/RUNTIME.md.
    assert.is_truthy(build.recipes.luaossl.cppflags:find("HAVE_DLADDR=0", 1, true))
  end)

  it("refuses to guess which files a library compiles", function()
    local ok, why = build.archive {
      source = "/tmp", lua_include = "/usr/include", output = "/tmp/x.a",
      recipe = {},
    }
    assert.is_nil(ok)
    assert.is_truthy(tostring(why):find("will not guess", 1, true),
      "expected a refusal that explains itself, got: " .. tostring(why))
  end)

  it("names a library it has no recipe for, rather than failing vaguely", function()
    local ok, why = pcall(build.archive, {
      source = "/tmp", lua_include = "/usr/include", output = "/tmp/x.a",
      recipe = "some-library-nobody-taught-it",
    })
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("no recipe for", 1, true))
  end)
end)

-- ---------------------------------------------------------------------------
local function toolchain()
  local cc = io.popen "cc --version 2>/dev/null"
  local have_cc = cc and cc:read "a" ~= ""
  if cc then cc:close() end

  for _, path in ipairs {
    "/usr/lib/x86_64-linux-gnu/liblua5.4.a",
    "/usr/lib/liblua5.4.a",
  } do
    local f = io.open(path, "r")
    if f then
      f:close()
      local h = io.open("/usr/include/lua5.4/lua.h", "r")
      if h then h:close() return have_cc and path end
    end
  end
  return nil
end

local lua_library = toolchain()

if not lua_library then
  describe("akkar build, end to end", function()
    pending "no C compiler or no liblua5.4.a; skipping"
  end)
  return
end

describe("akkar build, end to end", function()
  it("produces an executable that runs with no Lua installed", function()
    local entry, dir = write_temp("app.lua", [[
      local greeting = require "greeting"
      print(greeting.text .. " from " .. _VERSION)
    ]])
    write_temp("unused.lua", "return true")

    -- A second module in the same directory, so the roots mechanism is
    -- exercised rather than assumed.
    local module_file = assert(io.open(dir .. "/greeting.lua", "w"))
    module_file:write 'return { text = "akkar build works" }'
    module_file:close()

    local binary = dir .. "/built"
    local result, why = build.run {
      entry = entry,
      roots = { dir },
      archives = {},
      output = binary,
      lua_library = lua_library,
      lua_include = "/usr/include/lua5.4",
      libs = "-lm -ldl",
    }

    assert.is_truthy(result, "the build failed: " .. tostring(why))

    local pipe = assert(io.popen(binary .. " 2>&1"))
    local output = pipe:read "a"
    pipe:close()

    assert.is_truthy(output:find("akkar build works", 1, true),
      "the binary did not run its embedded module; got: " .. tostring(output))
  end)
end)
