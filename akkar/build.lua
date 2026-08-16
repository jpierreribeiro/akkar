--[[
akkar.build — one application, one executable.

## Why akkar emits its own host

The feasibility work in `docs/RUNTIME.md` linked the whole stack with
`luastatic` and stopped one plumbing detail short of serving a request. A
general-purpose bundler has to GUESS which module a `luaopen_` symbol belongs
to, and its guess -- turn every underscore into a dot -- is wrong for exactly
the modules akkar depends on: `luaopen__cqueues_socket` is `_cqueues.socket`,
not `.cqueues.socket`. Rewriting the generated source by hand got cqueues
working and still left `_openssl.rand` unresolved.

A host akkar generates does not guess. It knows which symbol belongs to which
name because it writes both sides of the table.

## What it produces

A single C file and, if a compiler is available, a single executable
containing:

  * the Lua VM, statically linked;
  * every Lua module the application needs, embedded as SOURCE and registered
    in `package.preload`;
  * every native module, registered under its real name.

Deployment stops needing a Lua installation, LuaRocks, or a `.so` on the
target.

## Source, not bytecode

Bytecode would be smaller and faster to load, and it is not used. Lua bytecode
is not portable across versions or word sizes, so a binary built on one
machine could fail on another in a way that looks like corruption. And
`akkar.vm` refuses to load bytecode on principle -- crafted bytecode escapes
every sandbox ever written -- so a build step that embedded it would be the
one place in this project that treats bytecode as trustworthy.

## What this is NOT

Not a cross-compiler: it builds for the machine it runs on. Not a dependency
resolver: it embeds the modules it is told about, and `akkar build --trace`
exists because the reliable way to know what an application loads is to run it
and look.
]]

local M = {}

local function read_file(path)
  local file, why = io.open(path, "rb")
  if not file then return nil, why end
  local contents = file:read "a"
  file:close()
  return contents
end


-- =========================================================== module naming
--
-- THE RULE THE GENERIC BUNDLER GETS WRONG.
--
-- A C module's entry point is `luaopen_` plus its module name with dots
-- turned into underscores. Reversing that is ambiguous in general -- a module
-- genuinely named `foo_bar` is indistinguishable from `foo.bar` -- and there
-- is exactly one place the ambiguity bites akkar: a LEADING underscore.
--
-- `cqueues` and `luaossl` both ship their C half under a name that starts
-- with one (`_cqueues`, `_openssl`) and their Lua half under the plain name.
-- A bundler that treats the leading underscore as a separator produces
-- `.cqueues`, which nothing requires and nothing finds.
--
-- So: a leading underscore is part of the NAME. Everything after it is a
-- separator. Anything else, the caller states explicitly.
function M.module_name_of(symbol)
  local rest = symbol:match "^luaopen_(.+)$"
  if not rest then return nil end

  local leading = ""
  if rest:sub(1, 1) == "_" then
    leading = "_"
    rest = rest:sub(2)
  end
  return leading .. (rest:gsub("_", "."))
end

--- Every module name the embedded sources ask for by name.
---
--- THE AUTHORITATIVE ANSWER TO THE AMBIGUITY ABOVE. `module_name_of` has to
--- guess where the dots go in `luaopen__openssl_x509_verify_param`, and it
--- guesses wrong: the module is `_openssl.x509.verify_param`, whose name
--- genuinely contains an underscore. No rule over symbols can know that.
---
--- The code that requires it does. Every `require "x"` in the sources about
--- to be embedded names a module exactly, so mapping a name FORWARD to its
--- symbol -- dots to underscores, which is unambiguous in that direction --
--- and checking whether the archive defines it turns the guess into a lookup.
---
--- Only literal requires are found, and that is the honest limit: a module
--- fetched through a computed name is invisible here, as it is to every
--- other tool that reads source instead of running it.
function M.required_names(paths)
  local names = {}
  for _, path in pairs(paths) do
    local source = read_file(path)
    if source then
      for name in source:gmatch 'require%s*%(?%s*"([%w_%.]+)"' do
        names[name] = true
      end
      for name in source:gmatch "require%s*%(?%s*'([%w_%.]+)'" do
        names[name] = true
      end
    end
  end
  return names
end

--- Reads the `luaopen_` symbols out of a static archive.
---
--- `nm` rather than parsing ELF: this runs at build time on a developer's
--- machine, where a toolchain is present by definition, and reimplementing a
--- symbol table reader would be a second, worse `nm`.
function M.symbols_in(archive)
  local pipe, why = io.popen("nm -g --defined-only " ..
                             string.format("%q", archive) .. " 2>/dev/null")
  if not pipe then return nil, "could not run nm: " .. tostring(why) end

  local found = {}
  for line in pipe:lines() do
    local symbol = line:match "%s[TtDd]%s+(luaopen_[%w_]+)%s*$"
    if symbol then found[#found + 1] = symbol end
  end
  pipe:close()

  table.sort(found)
  return found
end

-- ============================================================ lua modules
--- Maps a path under `root` to the module name it would be required by.
---
--- `akkar/init.lua` is `akkar`, not `akkar.init` -- the same rule
--- `package.path` uses, and getting it wrong means the entry module of every
--- package is invisible.
function M.module_name_for(root, path)
  local relative = path:sub(#root + 1):gsub("^/", "")
  local name = relative:gsub("%.lua$", ""):gsub("/", ".")
  return (name:gsub("%.init$", ""))
end

--- Collects every `.lua` file under `root`.
function M.collect(root, into)
  into = into or {}
  local pipe = io.popen("find " .. string.format("%q", root) ..
                        " -name '*.lua' -type f 2>/dev/null")
  if not pipe then return into end

  for path in pipe:lines() do
    local name = M.module_name_for(root, path)
    -- First root wins, so an application can shadow a library module by
    -- listing its own directory first.
    if not into[name] then
      into[name] = path
    end
  end
  pipe:close()
  return into
end

-- ============================================================== emitting C
local function hex_array(bytes)
  local out, line = {}, {}
  for i = 1, #bytes do
    line[#line + 1] = string.format("0x%02x,", bytes:byte(i))
    if #line == 16 then
      out[#out + 1] = "  " .. table.concat(line, " ")
      line = {}
    end
  end
  if #line > 0 then out[#out + 1] = "  " .. table.concat(line, " ") end
  return table.concat(out, "\n")
end

local HOST_PREAMBLE = [[
/* Generated by akkar.build. Do not edit: rebuild instead.
 *
 * Every Lua module the application needs is embedded below as SOURCE and
 * registered in package.preload. Every native module is registered under its
 * real name -- which this file knows rather than guesses, because akkar
 * wrote both sides of the table.
 */
#include <string.h>
#include <stdlib.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

typedef struct {
  const char *name;
  const unsigned char *source;
  size_t length;
} akkar_lua_module;

]]

local HOST_LOADER = [[

/* `require` calls a preload entry with (modname, ":preload:"), so one shared
 * loader can serve every embedded module: it is told which one it is. */
static int akkar_load_embedded(lua_State *L) {
  const char *name = luaL_checkstring(L, 1);
  const akkar_lua_module *m;

  for (m = akkar_lua_modules; m->name != NULL; m++) {
    if (strcmp(m->name, name) == 0) {
      if (luaL_loadbuffer(L, (const char *)m->source, m->length, name) != LUA_OK) {
        return lua_error(L);
      }
      lua_pushstring(L, name);
      lua_call(L, 1, 1);
      return 1;
    }
  }
  return luaL_error(L, "akkar: no embedded module '%s'", name);
}

static void akkar_register(lua_State *L) {
  const akkar_lua_module *m;

  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");

  for (m = akkar_lua_modules; m->name != NULL; m++) {
    lua_pushcfunction(L, akkar_load_embedded);
    lua_setfield(L, -2, m->name);
  }

  akkar_register_native(L);

  lua_pop(L, 2);
}

int main(int argc, char **argv) {
  lua_State *L;
  int i;

  L = luaL_newstate();
  if (L == NULL) {
    fprintf(stderr, "akkar: could not create a Lua state\n");
    return 1;
  }
  luaL_openlibs(L);
  akkar_register(L);

  /* `arg` as a standalone interpreter would build it: arg[0] is the
   * executable, arg[1..] the parameters. An application that reads arg
   * behaves the same whether it was run by `lua app.lua` or built. */
  lua_createtable(L, argc - 1, 1);
  for (i = 0; i < argc; i++) {
    lua_pushstring(L, argv[i]);
    lua_rawseti(L, -2, i);
  }
  lua_setglobal(L, "arg");

  lua_getglobal(L, "require");
  lua_pushstring(L, AKKAR_ENTRY);
  if (lua_pcall(L, 1, 0, 0) != LUA_OK) {
    fprintf(stderr, "akkar: %s\n", lua_tostring(L, -1));
    lua_close(L);
    return 1;
  }

  lua_close(L);
  return 0;
}
]]

--- Writes the C host for a plan.
---
--- @param plan  { entry = "module name",
---               lua = { [name] = path },
---               native = { [name] = symbol } }
function M.emit(plan)
  local out = { HOST_PREAMBLE }

  out[#out + 1] = ('#include <stdio.h>\n#define AKKAR_ENTRY %q\n\n'):format(plan.entry)

  -- The Lua half, embedded as source.
  local names = {}
  for name in pairs(plan.lua) do names[#names + 1] = name end
  table.sort(names)

  local symbols = {}
  for index, name in ipairs(names) do
    local source, why = read_file(plan.lua[name])
    if not source then
      return nil, ("cannot read %s for module %s: %s")
                  :format(plan.lua[name], name, tostring(why))
    end
    local symbol = ("akkar_source_%d"):format(index)
    symbols[name] = { symbol = symbol, length = #source }
    out[#out + 1] = ("/* %s */\nstatic const unsigned char %s[] = {\n%s\n};\n")
                    :format(name, symbol, hex_array(source))
  end

  out[#out + 1] = "static const akkar_lua_module akkar_lua_modules[] = {"
  for _, name in ipairs(names) do
    local entry = symbols[name]
    out[#out + 1] = ('  { %q, %s, %d },'):format(name, entry.symbol, entry.length)
  end
  out[#out + 1] = "  { NULL, NULL, 0 }\n};\n"

  -- The native half. Declared and registered by NAME, not by guess.
  local native_names = {}
  for name in pairs(plan.native or {}) do native_names[#native_names + 1] = name end
  table.sort(native_names)

  for _, name in ipairs(native_names) do
    out[#out + 1] = ("int %s(lua_State *L);"):format(plan.native[name])
  end

  out[#out + 1] = "\nstatic void akkar_register_native(lua_State *L) {"
  if #native_names == 0 then
    out[#out + 1] = "  (void)L;"
  end
  for _, name in ipairs(native_names) do
    out[#out + 1] = ("  lua_pushcfunction(L, %s);\n  lua_setfield(L, -2, %q);")
                    :format(plan.native[name], name)
  end
  out[#out + 1] = "}\n"

  out[#out + 1] = HOST_LOADER
  return table.concat(out, "\n")
end

-- ================================================================ the plan
--- Builds a plan from roots, archives and an entry file.
function M.plan(options)
  local entry_path = assert(options.entry, "akkar.build: no entry file")

  local lua = {}
  for _, root in ipairs(options.roots or {}) do
    M.collect((root:gsub("/$", "")), lua)
  end

  -- The entry script is embedded like any other module, under a name no
  -- application would choose, so requiring it cannot collide.
  local entry_name = options.entry_name or "__akkar_entry"
  lua[entry_name] = entry_path

  -- Collect every symbol the archives define, then name them.
  local defined = {}
  for _, archive in ipairs(options.archives or {}) do
    local symbols, why = M.symbols_in(archive)
    if not symbols then return nil, why end
    for _, symbol in ipairs(symbols) do defined[symbol] = true end
  end

  local native = {}

  -- FIRST, the names the code itself asks for. Forward -- a module name to
  -- its symbol -- is unambiguous, so every match here is a fact rather than
  -- an inference.
  for name in pairs(M.required_names(lua)) do
    local symbol = "luaopen_" .. name:gsub("%.", "_")
    if defined[symbol] then
      native[name] = symbol
      defined[symbol] = nil
    end
  end

  -- THEN the rule, for anything left: a module in the archive that nothing
  -- embedded requires by a literal name. Registering it costs nothing and
  -- omitting it would strand a module reached some other way.
  for symbol in pairs(defined) do
    local name = M.module_name_of(symbol)
    if name and not native[name] then native[name] = symbol end
  end

  -- Explicit wins over derived, for the module whose name the rule cannot
  -- recover.
  for name, symbol in pairs(options.native or {}) do native[name] = symbol end

  return { entry = entry_name, lua = lua, native = native }
end

--- Emits the host and, unless `compile = false`, links the executable.
function M.run(options)
  local plan, why = M.plan(options)
  if not plan then return nil, why end

  local source
  source, why = M.emit(plan)
  if not source then return nil, why end

  local c_path = options.c_out or ((options.output or "akkar-app") .. ".c")
  local file, open_why = io.open(c_path, "wb")
  if not file then return nil, "cannot write " .. c_path .. ": " .. tostring(open_why) end
  file:write(source)
  file:close()

  local counts = { lua = 0, native = 0 }
  for _ in pairs(plan.lua) do counts.lua = counts.lua + 1 end
  for _ in pairs(plan.native) do counts.native = counts.native + 1 end

  if options.compile == false then
    return { c = c_path, modules = counts }
  end

  local parts = {
    options.cc or os.getenv "CC" or "cc",
    options.cflags or "-Os",
    -- luaossl asks the dynamic loader for the running image; a
    -- position-independent executable cannot be reopened that way, and the
    -- failure reads "cannot dynamically load position-independent
    -- executable" from a module nobody mentioned.
    "-no-pie",
    string.format("%q", c_path),
  }
  for _, archive in ipairs(options.archives or {}) do
    parts[#parts + 1] = string.format("%q", archive)
  end
  parts[#parts + 1] = string.format("%q", assert(options.lua_library,
    "akkar.build: no lua_library (the path to liblua.a)"))
  parts[#parts + 1] = "-I" .. string.format("%q", assert(options.lua_include,
    "akkar.build: no lua_include (the directory holding lua.h)"))
  parts[#parts + 1] = "-rdynamic"
  parts[#parts + 1] = options.libs or "-lm -ldl -lpthread"
  parts[#parts + 1] = "-o " .. string.format("%q", options.output or "akkar-app")

  local command = table.concat(parts, " ")
  local ok, kind, code = os.execute(command .. " 2>&1")
  if not ok then
    return nil, ("the compiler refused (%s %s): %s")
                :format(tostring(kind), tostring(code), command)
  end

  return { c = c_path, binary = options.output or "akkar-app", modules = counts }
end

return M
