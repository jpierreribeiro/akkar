local substrate = require "akkar.internal.substrate"
local doctor = require "akkar.doctor"

describe("controlled substrate", function()
  it("reads pins without evaluating shell code", function()
    local manifest = assert(substrate.read("runtime/substrate.env"))
    assert.equal(40, #manifest.CQUEUES_COMMIT)
    assert.equal(64, #manifest.LUA_SHA256)
  end)
  it("fails closed when an explicitly configured manifest is missing", function()
    local report = doctor.check_environment()
    local before = report:count("fail")
    substrate.check(report, "/nonexistent/akkar-substrate.env")
    assert.equal(before + 1, report:count("fail"))
  end)
  it("rejects a loaded cqueues that does not match the pin", function()
    local cq = require "cqueues"
    local original = cq.COMMIT
    local report = doctor.check_environment()
    local before = report:count("fail")
    cq.COMMIT = "wrong"
    local ok, err = pcall(substrate.check, report, "runtime/substrate.env")
    cq.COMMIT = original
    assert.is_true(ok, tostring(err))
    assert.is_true(report:count("fail") > before)
  end)
end)
