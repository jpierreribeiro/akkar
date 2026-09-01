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
local function boot_modules()
  local script = ("package.path = %q\npackage.cpath = %q\n"):format(
    "./?.lua;./?/init.lua;" .. package.path, "./?.so;" .. package.cpath) .. [[
    require "akkar"
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
  end)
end)
