--[[
akkar.email — the failure paths, which are the point.

## What is tested and what is not

**Tested for real:** validation, address normalisation, the JSON body and
headers the transport builds, the mapping from every kind of provider failure
to a returned value, and -- most of all -- that NOTHING here raises. That last
one is asserted on every failure shape there is, including a transport that
raises on purpose, because "returns an error" is the module's whole contract
and a contract nobody tests is a comment.

**NOT tested with a real network call.** No message is sent to a provider by
this file. There is no HTTP server, no Resend, no credentials. The transport
is a function, so the seam is exactly where a fake belongs -- but what that
leaves unverified is real and worth naming: whether Resend's live API accepts
this body, what its rate-limit response looks like, and whether any provider's
error document puts its message somewhere `json_api` does not look. The
transport for the HTTP call itself is `akkar.http`, which `spec/http_spec.lua`
and `spec/http_pool_spec.lua` do exercise against a real server.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local email = require "akkar.email"
local json  = require "akkar.json"

--- A transport that records what it was handed and answers as told.
local function recorder(answer)
  local sent = {}
  return sent, function(message)
    sent[#sent + 1] = message
    if answer == nil then return "msg_1" end
    return answer.id, answer.reason, answer.details
  end
end

--- Stands in for `akkar.http`'s client, so `json_api` can be driven without a
--- socket while still being the real `json_api`.
local function fake_client(answers)
  local calls = {}
  return calls, {
    post = function(_, url, options)
      calls[#calls + 1] = { url = url, options = options }
      local answer = answers[#calls] or answers[1]
      if answer.error then return nil, answer.error end
      if answer.raise then error(answer.raise, 0) end
      return { status = answer.status, headers = {},
               body = answer.body or "" }
    end,
  }
end

describe("akkar.email validation", function()
  local function mailer(transport)
    local _, fn = recorder()
    return email.new { transport = transport or fn, from = "hi@example.com" }
  end

  it("accepts one address or a list", function()
    assert.same({ "a@b.c" }, email.address_list "a@b.c")
    assert.same({ "a@b.c", "d@e.f" }, email.address_list { "a@b.c", "d@e.f" })
    assert.is_nil(email.address_list {})
    assert.is_nil(email.address_list(7))
  end)

  it("sends with the defaults filled in", function()
    local sent, transport = recorder()
    local id, why = mailer(transport):send {
      to = "ada@example.com", subject = "Hello", text = "hi",
    }
    assert.equal("msg_1", id)
    assert.is_nil(why)
    assert.same({ "ada@example.com" }, sent[1].to)
    assert.equal("hi@example.com", sent[1].from)
  end)

  it("returns a reason rather than raising for every bad message", function()
    -- EACH OF THESE IS A RETURN, NOT A RAISE, and that is the module's entire
    -- contract: a template that produced a nil subject must not take down the
    -- request that was otherwise complete.
    local m = mailer()
    local cases = {
      { nil, "not a table" },
      { {}, "no addresses" },
      { { to = "ada@example.com" }, "no subject" },
      { { to = "ada@example.com", subject = "" }, "empty subject" },
      { { to = "ada@example.com", subject = "Hi" }, "no body" },
      { { to = "not-an-address", subject = "Hi", text = "x" }, "bad address" },
      { { to = "ada @example.com", subject = "Hi", text = "x" }, "space in address" },
      { { to = {}, subject = "Hi", text = "x" }, "empty list" },
    }
    for _, case in ipairs(cases) do
      local ok, id, why = pcall(function() return m:send(case[1]) end)
      assert.is_true(ok, "it raised on: " .. case[2])
      assert.is_nil(id, "it accepted: " .. case[2])
      assert.is_string(why)
    end
  end)

  it("needs a from address from somewhere", function()
    local _, transport = recorder()
    local bare = email.new { transport = transport }
    local id, why = bare:send { to = "a@b.c", subject = "Hi", text = "x" }
    assert.is_nil(id)
    assert.is_truthy(why:find("from", 1, true))
  end)

  it("is loose about what an address looks like, on purpose", function()
    -- RFC 5322 permits far stranger things than any regex admits, and being
    -- strict here means a real user cannot sign up -- a much worse outcome
    -- than one message that bounces.
    assert.is_true(email.plausible "a+tag@example.co.uk")
    assert.is_true(email.plausible "o'brien@example.com")
    assert.is_true(email.plausible "ünïcode@exämple.com")
    assert.is_false(email.plausible "@example.com")
    assert.is_false(email.plausible "nobody")
  end)

  it("refuses to be built without a transport", function()
    assert.has_error(function() email.new {} end)
  end)
end)

describe("akkar.email failure handling", function()
  it("turns a transport that RAISES into a returned error", function()
    -- The transport is somebody else's function and owes this module nothing.
    -- A provider SDK that raises on a socket error would otherwise reach the
    -- handler as an error, which is the exact outcome this file exists to
    -- prevent.
    local m = email.new {
      from = "hi@example.com",
      transport = function() error("the sky fell", 0) end,
    }
    local ok, id, why = pcall(function()
      return m:send { to = "a@b.c", subject = "Hi", text = "x" }
    end)
    assert.is_true(ok, "send raised instead of returning")
    assert.is_nil(id)
    assert.is_truthy(why:find("the sky fell", 1, true))
  end)

  it("passes a transport's own reason through", function()
    local _, transport = recorder { id = nil, reason = "provider is down",
                                    details = { status = 503 } }
    local m = email.new { transport = transport, from = "hi@example.com" }
    local id, why, details = m:send { to = "a@b.c", subject = "Hi", text = "x" }
    assert.is_nil(id)
    assert.equal("provider is down", why)
    assert.equal(503, details.status)
  end)

  it("logs and carries on when asked to", function()
    local lines = {}
    local log = { warn = function(_, message, fields)
      lines[#lines + 1] = { message = message, fields = fields }
    end }
    local m = email.new {
      from = "hi@example.com",
      transport = function() return nil, "nope" end,
    }
    local id = m:send_or_log({ to = "a@b.c", subject = "Hi", text = "x" }, log)
    assert.is_nil(id)
    assert.equal(1, #lines)
    assert.equal("nope", lines[1].fields.reason)
  end)
end)

describe("akkar.email json_api transport", function()
  local function transport(answers, config)
    local calls, client = fake_client(answers)
    config = config or {}
    config.url = config.url or "https://api.example.com/emails"
    config.token = config.token or "secret-token"
    config.http = client
    return calls, email.json_api(config)
  end

  it("posts the message as JSON with a bearer token", function()
    local calls, send = transport { { status = 200, body = '{"id":"abc"}' } }
    local m = email.new { transport = send, from = "hi@example.com" }
    local id = m:send {
      to = { "a@b.c", "d@e.f" }, subject = "Hi", text = "plain",
      html = "<p>rich</p>", reply_to = "reply@example.com",
    }
    assert.equal("abc", id)

    local call = calls[1]
    assert.equal("https://api.example.com/emails", call.url)
    assert.equal("Bearer secret-token", call.options.headers["authorization"])

    -- The body is handed to akkar.http as a TABLE, which is what makes it a
    -- JSON request there; encoding it here would set the content type twice.
    local body = call.options.body
    assert.same({ "a@b.c", "d@e.f" }, body.to)
    assert.equal("hi@example.com", body.from)
    assert.equal("plain", body.text)
    assert.equal("<p>rich</p>", body.html)
    assert.equal("reply@example.com", body.reply_to)
    -- Absent fields stay absent rather than becoming null.
    assert.is_nil(body.cc)
    assert.is_nil(body.bcc)
  end)

  it("renames fields for a provider that spells them differently", function()
    local calls, send = transport({ { status = 200, body = "{}" } },
                                  { fields = { text = "TextBody",
                                               html = "HtmlBody",
                                               from = "From" },
                                    extra = { MessageStream = "outbound" } })
    local m = email.new { transport = send, from = "hi@example.com" }
    local id = m:send { to = "a@b.c", subject = "Hi", text = "plain" }

    -- A 200 with no id in it is still a SUCCESS. Returning nil there would
    -- make it indistinguishable from a failure at the call site, which is the
    -- only thing the caller checks.
    assert.is_true(id)

    local body = calls[1].options.body
    assert.equal("plain", body.TextBody)
    assert.equal("hi@example.com", body.From)
    assert.equal("outbound", body.MessageStream)
    assert.is_nil(body.text)
  end)

  it("returns the provider's own message on a refusal", function()
    local _, send = transport {
      { status = 422, body = json.encode { message = "domain not verified" } },
    }
    local m = email.new { transport = send, from = "hi@example.com" }
    local id, why, details = m:send { to = "a@b.c", subject = "Hi", text = "x" }
    assert.is_nil(id)
    assert.is_truthy(why:find("domain not verified", 1, true))
    assert.equal(422, details.status)
  end)

  it("survives a provider answering with something that is not JSON", function()
    -- A gateway returning an HTML error page is the ordinary way a provider
    -- fails, and a decoder raising on it would be a raise reaching the
    -- handler.
    local _, send = transport { { status = 502, body = "<html>bad gateway</html>" } }
    local m = email.new { transport = send, from = "hi@example.com" }
    local ok, id, why = pcall(function()
      return m:send { to = "a@b.c", subject = "Hi", text = "x" }
    end)
    assert.is_true(ok, "it raised on a non-JSON body")
    assert.is_nil(id)
    assert.is_truthy(why:find("502", 1, true))
  end)

  it("returns the transport's error when the request never completed", function()
    local _, send = transport { { error = "connection refused" } }
    local m = email.new { transport = send, from = "hi@example.com" }
    local id, why = m:send { to = "a@b.c", subject = "Hi", text = "x" }
    assert.is_nil(id)
    assert.equal("connection refused", why)
  end)

  it("does not raise when the http client itself raises", function()
    local _, send = transport { { raise = "socket exploded" } }
    local m = email.new { transport = send, from = "hi@example.com" }
    local ok, id, why = pcall(function()
      return m:send { to = "a@b.c", subject = "Hi", text = "x" }
    end)
    assert.is_true(ok, "a raising client escaped send()")
    assert.is_nil(id)
    assert.is_truthy(why:find("socket exploded", 1, true))
  end)

  it("passes an idempotency key through as a header", function()
    -- The ONLY thing that makes retrying a send safe, and the caller's to
    -- choose, because only the caller knows what "the same email" means.
    local calls, send = transport { { status = 200, body = '{"id":"x"}' } }
    local m = email.new { transport = send, from = "hi@example.com" }
    m:send { to = "a@b.c", subject = "Hi", text = "x",
             idempotency_key = "signup-42" }
    assert.equal("signup-42", calls[1].options.headers["idempotency-key"])
  end)

  it("wires resend without needing the field names", function()
    local calls, client = fake_client { { status = 200, body = '{"id":"re_1"}' } }
    local m = email.new {
      transport = email.resend { api_key = "re_test", http = client },
      from = "hi@example.com",
    }
    assert.equal("re_1", m:send { to = "a@b.c", subject = "Hi", text = "x" })
    assert.equal("https://api.resend.com/emails", calls[1].url)
    assert.equal("Bearer re_test", calls[1].options.headers["authorization"])
  end)

  it("refuses to build a transport with no url", function()
    -- Asserting HERE is right even though `send` never may: this runs once,
    -- from configuration, and a deployment missing its url should refuse to
    -- start rather than fail at three in the morning.
    assert.has_error(function() email.json_api {} end)
    assert.has_error(function() email.resend {} end)
  end)
end)
