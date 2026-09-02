--[[
TLS to PostgreSQL, attacked rather than configured.

PostgreSQL negotiates TLS in cleartext: the client sends an SSLRequest and the
server answers one byte, `S` for yes or `N` for no.  pgmoon fails on an error
reply, and fails on `N` only when `ssl_required` is set -- otherwise it falls
through and continues on the plain socket.  So a connection configured with
`ssl = true, ssl_verify = true` could be stripped by anyone able to answer that
byte, and would report success, having presented no certificate at all.

The existing db_spec asserts that `tls_client` builds an SSL object with the
right hostname.  That is true and it is not the property that matters: nothing
asserted that the connection was ENCRYPTED.  These tests answer `N` and check
what the adapter does about it.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local cqueues = require "cqueues"
local socket  = require "cqueues.socket"
local db      = require "akkar.db"

-- A server that speaks exactly enough PostgreSQL to refuse TLS: read the
-- SSLRequest, answer "N", and then say nothing.  What the client does next is
-- the whole test.
local function refusing_server(loop)
  local listener = assert(socket.listen("127.0.0.1", 0))
  assert(listener:listen())
  local _, _, port = listener:localname()
  loop:wrap(function()
    local peer = listener:accept()
    if not peer then return end
    peer:setmode("bn", "bn")
    peer:read(8)          -- the 8-byte SSLRequest packet
    peer:write("N")
    peer:flush()
    cqueues.sleep(0.5)    -- stay open so a downgraded client gets further
    peer:close()
  end)
  return port, listener
end

describe("a database connection that asked for TLS", function()
  it("refuses to continue when the server declines TLS", function()
    local loop = cqueues.new()
    local port, listener = refusing_server(loop)
    local outcome
    loop:wrap(function()
      local ok, err = pcall(db.connect {
        host = "127.0.0.1", port = port, database = "akkar",
        user = "postgres", password = "akkar", pool_size = 0,
        ssl = true, ssl_verify = false,
      })
      outcome = { ok = ok, err = tostring(err) }
    end)
    assert(loop:loop(5))
    listener:close()

    assert.is_false(outcome.ok, "the adapter accepted a stripped connection")
    assert.matches("does not support SSL", outcome.err,
      "expected the SSL refusal, got: " .. outcome.err)
  end)

  it("still allows opportunistic TLS when the caller says so out loud", function()
    -- `ssl_required = false` is a deliberate sentence, not a default.  The
    -- connection gets past the SSL step and fails later, on the startup packet
    -- this fake never answers -- which is the proof that it got past it.
    local loop = cqueues.new()
    local port, listener = refusing_server(loop)
    local outcome
    loop:wrap(function()
      local ok, err = pcall(db.connect {
        host = "127.0.0.1", port = port, database = "akkar",
        user = "postgres", password = "akkar", pool_size = 0,
        ssl = true, ssl_verify = false, ssl_required = false,
      })
      outcome = { ok = ok, err = tostring(err) }
    end)
    assert(loop:loop(5))
    listener:close()

    assert.is_false(outcome.ok, "the fake server cannot complete a startup")
    assert.is_nil(outcome.err:find("does not support SSL", 1, true),
      "opportunistic TLS was refused as if it were required: " .. outcome.err)
  end)
end)
