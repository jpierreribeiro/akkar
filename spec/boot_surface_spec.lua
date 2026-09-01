--[[
What `require "akkar"` drags in, and what it must not.

## The defect this was written for

`akkar/init.lua` exposes `akkar.idempotency` with an eager require, so that
module loads in EVERY application -- including every one that never writes an
idempotent route. When `akkar.idempotency` grew a top-level
`require "akkar.crypto"`, OpenSSL's digest, hmac and kdf came in behind it:
seven modules added to every boot, for a capability most processes never reach.

Nothing caught it. The boot profiler in `bench/study/boot-profile.lua` is a
script somebody runs on purpose, and boot is not something a request-level test
can see. So the number moved from 69 modules to 76 and the only evidence was in
a benchmark nobody was running that day.

## Why this asserts names rather than a count

A count is a number that churns: every legitimate module added to the boot path
would fail this file, and the fix would be to raise it, which trains people to
raise it. What matters is not how many modules boot, it is WHICH -- specifically
that the expensive optional capabilities stay out until something asks for them.

So this names them. A module listed here becoming a boot dependency is a
decision, and it should be argued for in a commit rather than discovered in a
profile six weeks later.

## Why a subprocess

`package.loaded` inside the suite already holds most of the tree, because other
spec files loaded it. The only honest way to ask what a fresh `require "akkar"`
loads is to ask a fresh process.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local portable = require "spec.support.portable"

--- Boots akkar in a fresh Lua state and returns the set of loaded modules.
---
--- The child is told the paths this process already resolved rather than left
--- to append to its own, and it is reached through `portable.lua`. Both for the
--- reason `spec/docs_spec.lua` gives at length: a child that cannot find
--- cqueues fails in a way that blames the code for the harness.
--- @param body string|nil Lua source to run before the module set is read.
---   Defaults to a bare `require "akkar"`. Passed in rather than hard-coded
---   because the h2 assertions below have to ask what a boot that BUILDS A
---   SERVER loads, which is a different question from what `require` loads.
local function boot_modules(body)
  local script = ("package.path = %q\npackage.cpath = %q\n"):format(
    "./?.lua;./?/init.lua;" .. package.path, "./?.so;" .. package.cpath)
    .. (body or 'require "akkar"\n') .. [[
    local names = {}
    for name in pairs(package.loaded) do names[#names + 1] = name end
    table.sort(names)
    print(table.concat(names, "\n"))
  ]]
  local path = os.tmpname()
  local file = assert(io.open(path, "w"))
  file:write(script)
  file:close()

  local pipe = assert(io.popen(
    portable.timeout(20, ("%s %q"):format(portable.lua, path)) .. " 2>/dev/null"))
  local out = pipe:read "a"
  pipe:close()
  os.remove(path)

  local loaded = {}
  for name in out:gmatch "[^\n]+" do loaded[name] = true end
  assert(loaded["akkar"], "the subprocess did not boot akkar at all")
  return loaded
end

describe("what booting akkar loads", function()
  local loaded
  setup(function() loaded = boot_modules() end)

  -- Each of these is reached lazily, at the call site that needs it. The
  -- reason is the same in every case: the capability is optional, and an
  -- application that never uses it should not pay to have it available.
  local MUST_NOT_LOAD = {
    ["akkar.crypto"] = "hashing and the CSPRNG; reached from idempotency, "
                    .. "limit and jobs at first use",
    ["openssl.digest"] = "pulled in by akkar.crypto",
    ["openssl.hmac"]   = "pulled in by akkar.crypto",
    ["openssl.kdf"]    = "pulled in by akkar.crypto",
    ["akkar.websocket"] = "deferred deliberately; it was measured at 96 ms and "
                       .. "65 modules on boots that never open a socket",
    -- THE h2 HALF. `akkar/vendor/http/server.lua` used to require
    -- `h2_connection` at the top of the file for two per-connection call
    -- sites, both of them already guarded. It is now loaded in `new_server`,
    -- and only for a server that could actually speak h2 -- `version == 2`,
    -- `h2c`, or anything but `tls = false`. The four below arrive behind it
    -- and nowhere else on the boot path, so they are the evidence that the
    -- deferral is really deferring rather than moving the require one file up.
    ["akkar.vendor.http.h2_connection"] =
      "deferred to `new_server`; ~19 ms of 47.6 and 5 modules of 69, on every "
      .. "boot of every application, most of which never see an h2 connection",
    ["akkar.vendor.http.h2_stream"] = "reached only through h2_connection",
    ["akkar.vendor.http.hpack"] =
      "HPACK's static table and huffman codes are built at load time, and "
      .. "reached only through h2_connection",
    ["akkar.vendor.http.h2_error"] = "reached only through h2_connection",
    ["akkar.vendor.http.bit"] =
      "the bit shim the h2 framing uses; reached only through h2_connection",
  }

  for name, why in pairs(MUST_NOT_LOAD) do
    it(("does not load %s"):format(name), function()
      assert.is_nil(loaded[name],
        ("%s is on the boot path. %s. If that is now deliberate, say so in the "
         .. "commit and move it out of this list; if it is not, reach it "
         .. "lazily at the call site."):format(name, why))
    end)
  end

  it("loads OpenSSL for TLS and for nothing else", function()
    -- The first version of this asserted NO OpenSSL at boot, and that was
    -- simply wrong: nineteen of its modules -- ssl, x509, pkey, rand and their
    -- C halves -- come in with the HTTP stack's TLS support, and did so before
    -- any of this work. Written down because the wrong assertion is the
    -- tempting one, and the next person to read this file will think of it.
    --
    -- What must NOT be there is the cryptography half: digest, hmac and kdf
    -- arrive only through `akkar.crypto`, so their presence means something
    -- put it on the boot path.
    for _, name in ipairs { "openssl.digest", "openssl.hmac", "openssl.kdf",
                            "_openssl.digest", "_openssl.hmac", "_openssl.kdf" } do
      assert.is_nil(loaded[name], name .. " is on the boot path")
    end
  end)

  it("still loads the things it is supposed to", function()
    -- The other half, and the one that makes the assertions above mean
    -- something: a fix that simply stopped loading would pass all of them.
    assert.is_truthy(loaded["akkar.execution"])
    assert.is_truthy(loaded["akkar.vendor.http.server"])
    assert.is_truthy(loaded["cqueues"])
    -- ALPN STAYS EAGER, and this is where that is written down.
    --
    -- `alpn_select` in `server.lua` is a pure function over strings, and the
    -- context that installs it is built from `akkar.vendor.http.tls`. Neither
    -- touches `h2_connection`, so h2 is still OFFERED over TLS from the first
    -- handshake -- what got deferred is the connection machinery, not the
    -- negotiation. A "tidy-up" that deferred this module too would take h2
    -- off the wire while every h2 test that dials in explicitly kept passing.
    assert.is_truthy(loaded["akkar.vendor.http.tls"])
  end)
end)

--[[
The other side of the deferral, and the one assertion here that protects
production rather than boot time.

`server.lua` documents `wrap_socket` as a function that *should never throw*,
and `add_socket` runs it under an `xpcall` -- so a `require` that failed inside
it would be swallowed, reported as one connection's error, and h2 would be
silently broken while HTTP/1.1 kept serving. That is why the load is forced in
`new_server`, which already throws twice, and not lazily at the call sites.

A change that quietly removed that forcing -- inlining it back into
`wrap_socket`, moving it to `listen`, or making it conditional on
`http_tls.has_alpn` -- would pass every other test in this file and in the
suite. It would fail only here.
]]
describe("constructing a server that could speak h2", function()
  -- `tls = false` and no `h2c`, so nothing forces the load: the counterweight
  -- for the two cases below, and the configuration the saving is actually for.
  local CLEARTEXT = [[
    require "akkar"
    require("akkar.vendor.http.server").new {
      tls = false, onstream = function() end,
    }
  ]]

  local H2C = [[
    require "akkar"
    require("akkar.vendor.http.server").new {
      tls = false, h2c = true, onstream = function() end,
    }
  ]]

  local TLS = [[
    require "akkar"
    require("akkar.vendor.http.server").new {
      tls = true, onstream = function() end,
      ctx = require("akkar.vendor.http.tls").new_server_context(),
    }
  ]]

  it("loads h2 for h2c = true, before any connection arrives", function()
    local loaded = boot_modules(H2C)
    assert.is_truthy(loaded["akkar.vendor.http.h2_connection"],
      "a cleartext h2c server was constructed and the h2 half was NOT loaded. "
      .. "The load must be forced in `new_server`, where throwing is already "
      .. "the contract -- deferred into `wrap_socket` it is caught by the "
      .. "`xpcall` in `add_socket`, and h2 fails silently in production while "
      .. "HTTP/1.1 keeps working.")
  end)

  it("loads h2 for a TLS server, because ALPN can hand it one", function()
    local loaded = boot_modules(TLS)
    assert.is_truthy(loaded["akkar.vendor.http.h2_connection"],
      "a TLS server was constructed and the h2 half was NOT loaded. ALPN can "
      .. "settle on h2 at any handshake, and there is no honest way to be "
      .. "ready for that without the module. An application with TLS pays the "
      .. "~19 ms here and saves nothing; that is the design, not a defect.")
  end)

  it("does not load h2 for a cleartext server without h2c", function()
    local loaded = boot_modules(CLEARTEXT)
    assert.is_truthy(loaded["akkar.vendor.http.server"],
      "the child did not build a server at all")
    assert.is_nil(loaded["akkar.vendor.http.h2_connection"],
      "a cleartext, non-h2c server loaded the h2 half. This is the one shape "
      .. "the deferral exists for -- the process-per-tenant case `akkar/init.lua` "
      .. "names as the reason boot time matters -- so if the forcing predicate "
      .. "now covers it, the deferral saves nobody anything.")
  end)
end)
