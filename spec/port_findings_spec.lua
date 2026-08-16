--[[
Defects found by porting a real service to akkar.

## Why this file is separate

`docs/UNKNOWNS.md` §10 has said since it was written that the largest gap in
this project is that **nobody has built an application with akkar**. Every
defect found so far was found by engineering an exposure -- a fuzzer, a
benchmark gate, an audit -- and none by use.

This file is the first evidence from the other kind of instrument. It is kept
apart from `spec/akkar_spec.lua` on purpose: the value of these cases is not
that they test validation, it is that a person building something ran into
them within an hour, which is a different claim about the framework and worth
being able to read on its own.

The service is an escrow platform: 223 Go files, 105 routes, 26 migrations,
money in integer cents. The slice ported was authentication, a fee quote,
invoice creation with an `Idempotency-Key`, listing and cancellation.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"
local cjson = require "cjson"
local v     = akkar.v

describe("a constraint nobody spelled correctly", function()
  -- WHAT HAPPENED. The first schema written against the real API used
  --
  --     v.string { pattern = "@" }
  --
  -- because `pattern` is what the rest of Lua calls it. akkar calls it
  -- `match`. The rule was accepted, built, and validated nothing: every
  -- string passed, including ones with no `@` in them.
  --
  -- The danger is not the typo. It is that the schema READS as though it
  -- validates. Nothing in the request, the response or the logs says
  -- otherwise, and the first evidence would be a row in the database.
  it("is refused when the rule is built, not ignored", function()
    local ok, why = pcall(function() return v.string { pattern = "@" } end)
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("unknown constraint 'pattern'", 1, true),
      "the message should name the constraint, got: " .. tostring(why))
    assert.is_truthy(tostring(why):find("match", 1, true),
      "and it should list the real ones, got: " .. tostring(why))
  end)

  it("names the type it was building, so the message is actionable", function()
    local ok, why = pcall(function() return v.integer { mn = 5 } end)
    assert.is_false(ok)
    assert.is_truthy(tostring(why):find("v.integer", 1, true),
      "expected the builder in the message, got: " .. tostring(why))
  end)

  it("still accepts every constraint that exists", function()
    assert.has_no.errors(function()
      return v.string { min = 1, max = 9, match = "^a", one_of = { "a" },
                        optional = true, default = "a" }
    end)
    assert.has_no.errors(function()
      return v.integer { min = 1, max = 9, optional = true, default = 1 }
    end)
  end)

  -- The check lives in the BUILDER, which runs once at startup, and not in
  -- `validate`, which runs on every request. Asserted structurally rather
  -- than by timing: a rule table written by hand, bypassing `v.integer`,
  -- still validates without complaint, which is only possible if `validate`
  -- never looks at the constraint names.
  --
  -- That is also the honest limit of the fix. A schema assembled
  -- programmatically, without going through `v.*`, is not covered.
  it("is checked when the rule is built and never again", function()
    local hand_written = { kind = "integer", min = 1, pattern = "ignored" }
    local out, err = akkar.validate({ n = 5 }, { n = hand_written })
    assert.is_nil(err)
    assert.equal(5, out.n)
  end)
end)

describe("a mounted app's middleware", function()
  -- WHAT HAPPENED, and it is the most serious thing the port found.
  --
  -- The service has public routes and private ones. The shape every framework
  -- teaches is: put the private routes in a sub-app, apply the auth middleware
  -- to that sub-app, mount it under a prefix.
  --
  --     local private = akkar.new()
  --     private:use(auth.middleware { bearer = ... })
  --     private:get("/invoices", ...)
  --     app:mount("/api", private)
  --
  -- akkar answered **200 with no credential**. `App:match` descended into the
  -- mount and returned the route, and the request then ran inside the PARENT's
  -- chain; everything `sub:use()` registered was discarded. No error, no
  -- warning, and the application reads as though it is protected.
  --
  -- `docs/HANDOFF.md` carried this among the open items as "app:mount not
  -- running sub-app middleware", beside ergonomic gaps. It is not one. It is a
  -- way to publish an authenticated API to the internet.
  local function guard(header, value)
    return function(req, next)
      if req.headers[header] ~= value then
        return akkar.response(401, { error = "unauthorized" })
      end
      return next(req)
    end
  end

  it("runs, so a mounted route is actually protected", function()
    local sub = akkar.new()
    sub:use(guard("x-token", "good"))
    sub:get("/secret", function() return { ok = true } end)

    local app = akkar.new()
    app:get("/public", function() return { ok = true } end)
    app:mount("/private", sub)

    local c = app:test()
    assert.equal(200, c:get("/public").status)
    assert.equal(401, c:get("/private/secret").status)
    assert.equal(200, c:get("/private/secret",
      { headers = { ["x-token"] = "good" } }).status)
  end)

  it("does not leak into the routes of the app that mounted it", function()
    local sub = akkar.new()
    sub:use(guard("x-token", "good"))
    sub:get("/secret", function() return { ok = true } end)

    local app = akkar.new()
    app:get("/public", function() return { ok = true } end)
    app:mount("/private", sub)

    -- The parent's own route must not inherit the child's guard.
    assert.equal(200, app:test():get("/public").status)
  end)

  it("runs the parent's middleware first, then the child's", function()
    local order = {}
    local sub = akkar.new()
    sub:use(function(req, next) order[#order + 1] = "child" return next(req) end)
    sub:get("/x", function() order[#order + 1] = "handler" return { ok = true } end)

    local app = akkar.new()
    app:use(function(req, next) order[#order + 1] = "parent" return next(req) end)
    app:mount("/m", sub)

    app:test():get "/m/x"
    assert.same({ "parent", "child", "handler" }, order)
  end)

  it("runs both levels when a mount contains a mount", function()
    local order = {}
    local inner = akkar.new()
    inner:use(function(req, next) order[#order + 1] = "inner" return next(req) end)
    inner:get("/deep", function() return { ok = true } end)

    local middle = akkar.new()
    middle:use(function(req, next) order[#order + 1] = "middle" return next(req) end)
    middle:mount("/b", inner)

    local app = akkar.new()
    app:mount("/a", middle)

    assert.equal(200, app:test():get("/a/b/deep").status)
    assert.same({ "middle", "inner" }, order)
  end)

  it("lets a mounted middleware short-circuit without reaching the handler", function()
    local reached = false
    local sub = akkar.new()
    sub:use(guard("x-token", "good"))
    sub:get("/x", function() reached = true return { ok = true } end)

    local app = akkar.new()
    app:mount("/m", sub)

    assert.equal(401, app:test():get("/m/x").status)
    assert.is_false(reached, "the handler ran behind a middleware that refused")
  end)
end)

describe("a client asking not to be charged twice", function()
  -- WHAT HAPPENED. The service's own Postman collection sends
  -- `Idempotency-Key` on `POST /invoices`. The port did not install
  -- `akkar.idempotency`, because nothing says you have to -- and posting the
  -- same key twice created two invoices, with two different ids, for the same
  -- payment. The only evidence anywhere was a row count.
  --
  -- Installing the middleware fixes it, and that is not the finding. The
  -- finding is that akkar was SILENT: it has the module, the header went past
  -- it, and it said nothing.
  --
  -- Against a REAL SERVER, because framework warnings go through akkar's
  -- internal logger and only `app:run` redirects it -- `app:test` does not, so
  -- a warning like this one is invisible to the in-process client. That is
  -- itself worth knowing and is why `spec/watchdog_spec.lua` does the same.
  local cqueues = require "cqueues"
  local request = require "http.request"

  it("is warned about once, and not at all when no key was sent", function()
    -- The check is skipped once `akkar.idempotency` is loaded, which is the
    -- cheap proxy for "somebody wired it". Another spec may have loaded it.
    local was = package.loaded["akkar.idempotency"]
    package.loaded["akkar.idempotency"] = nil

    local PORT = 8386
    local lines = {}
    local app = akkar.new()
    app:post("/charge", function() return { ok = true } end)

    local cq = cqueues.new()
    cq:wrap(function()
      pcall(function()
        app:run { port = PORT, check_capabilities = false,
                  log = akkar.log.new { level = "warn", format = "text",
                                        sink = function(l) lines[#lines + 1] = l end } }
      end)
    end)
    cq:wrap(function()
      cqueues.sleep(0.15)
      local function post(key)
        local r = request.new_from_uri("http://127.0.0.1:" .. PORT .. "/charge")
        r.headers:upsert(":method", "POST")
        r.headers:upsert("content-type", "application/json")
        if key then r.headers:upsert("idempotency-key", key) end
        r:set_body "{}"
        local h, s = r:go(10)
        assert(h, "no response")
        s:get_body_as_string()
      end
      post(nil)                      -- no key: must stay quiet
      post "abc"                     -- first key: one warning
      post "abc"
      post "def"                     -- still one warning, not three
      cqueues.sleep(0.1)
      app:stop(1)
    end)
    assert(cq:loop(30))

    package.loaded["akkar.idempotency"] = was

    local out = table.concat(lines, "\n")
    local count = select(2, out:gsub("carried Idempotency%-Key", ""))
    assert.equal(1, count,
      "expected exactly one warning, got " .. count .. ":\n" .. out)
  end)
end)

describe("the bytes a webhook was signed over", function()
  -- WHAT HAPPENED. The service receives signed webhooks from its payment
  -- provider, and its own test collection has a case asserting that an
  -- UNSIGNED delivery is refused with 401. The scheme is an HMAC over the raw
  -- request body:
  --
  --     signing_key = hex(sha256(secret))
  --     expected    = hex(hmac_sha256(signing_key, RAW BODY))
  --
  -- akkar read the body, decoded it, and threw the bytes away. `req.body` was
  -- all a handler ever saw, and a digest over `req.body` re-encoded is a
  -- DIFFERENT digest -- JSON key order is undefined and whitespace is not
  -- preserved. So signature verification was not awkward in akkar, it was
  -- impossible, and `docs/HANDOFF.md` recorded that as an open item.
  --
  -- Fixed by carrying the bytes through as `req.raw_body`. It allocates
  -- nothing new -- the string was already built in order to be decoded -- and
  -- costs retention, bounded by `body_limit` times the requests in flight.
  local crypto = require "akkar.crypto"

  local SECRET = "whsec_test_12345"
  local RAW = '{"event":"payment_completed","eventId":"evt_1",' ..
              '"data":{"externalReference":"tx_1"}}'

  local function sign(raw, secret)
    local key = crypto.to_hex(crypto.sha256(secret))
    return crypto.to_hex(crypto.hmac(key, raw, "sha256"))
  end

  local function app_with_guard()
    local ran = { count = 0 }
    local app = akkar.new()
    app:post("/hook", { before = { function(req, next)
      local raw = req.raw_body
      local sent = req.headers["x-webhook-signature"]
      if not raw or raw == "" or not sent then
        return akkar.response(401, { error = "INVALID_SIGNATURE" })
      end
      if not crypto.equal(sign(raw, SECRET), sent) then
        return akkar.response(401, { error = "INVALID_SIGNATURE" })
      end
      return next(req)
    end } }, function()
      ran.count = ran.count + 1
      return { ok = true }
    end)
    return app, ran
  end

  local function post(app, headers)
    return app:test():post("/hook",
      { raw_body = RAW, body = cjson.decode(RAW), headers = headers })
  end

  it("reaches the handler as req.raw_body, byte for byte", function()
    local seen
    local app = akkar.new()
    app:post("/hook", function(req) seen = req.raw_body return { ok = true } end)
    app:test():post("/hook", { raw_body = RAW, body = cjson.decode(RAW) })
    assert.equal(RAW, seen)
  end)

  it("lets a correctly signed delivery through", function()
    local app, ran = app_with_guard()
    assert.equal(200, post(app, { ["x-webhook-signature"] = sign(RAW, SECRET) }).status)
    assert.equal(1, ran.count)
  end)

  it("refuses an unsigned delivery without running the handler", function()
    local app, ran = app_with_guard()
    assert.equal(401, post(app, {}).status)
    assert.equal(0, ran.count, "the handler ran on an unsigned webhook")
  end)

  it("refuses a wrong signature without running the handler", function()
    local app, ran = app_with_guard()
    assert.equal(401, post(app, { ["x-webhook-signature"] = string.rep("a", 64) }).status)
    assert.equal(0, ran.count, "the handler ran on a forged signature")
  end)

  -- The reason raw bytes are not a convenience.
  --
  -- The first version of this case re-encoded the same compact document and
  -- asserted the bytes differed. It PASSED as a probe and FAILED in the suite,
  -- because Lua's table iteration put the keys back in the original order that
  -- time. Key order is undefined in both directions, so "the order changes" is
  -- not a fact to assert -- it is a coin.
  --
  -- What is deterministic: an encoder does not reproduce the sender's
  -- whitespace, and it does not reproduce `1.0`. Either is enough to make the
  -- digest unreachable from the decoded value, and both are things a real
  -- provider sends.
  it("could not be done from the decoded body", function()
    local spaced = '{"amount": 1.0, "ref": "tx_1"}'
    local reencoded = cjson.encode(cjson.decode(spaced))
    assert.are_not.equal(spaced, reencoded,
      "re-encoding preserved the sender's bytes, which it must not be relied on to do")
    assert.are_not.equal(sign(spaced, SECRET), sign(reencoded, SECRET))
  end)

  it("is nil when no body arrived, rather than an empty string", function()
    local seen, called = "unset", false
    local app = akkar.new()
    app:get("/x", function(req) called = true seen = req.raw_body return { ok = true } end)
    app:test():get "/x"
    assert.is_true(called)
    assert.is_nil(seen)
  end)
end)

describe("a retry schedule a webhook dispatcher can use", function()
  -- WHAT HAPPENED. The third slice was the outbound dispatcher: the worker
  -- that POSTs an event to whatever endpoint a seller registered and retries
  -- when it fails. The original's schedule is the one every retrying system
  -- uses -- a first delay, doubling, capped:
  --
  --     BaseBackoff * 2^(attempt-1), capped at MaxBackoff
  --     one minute -> four hours, twenty attempts
  --
  -- akkar computed `base ^ attempt`, which cannot say that. The two things it
  -- could say were both wrong: `base = 2` retries a customer's dead endpoint
  -- after two seconds, and `base = 60` goes 60s, then an hour, then two and a
  -- half days.
  local jobs = require "akkar.jobs"

  local function schedule(opts, n)
    local out = {}
    for attempt = 1, n do
      opts.jitter = false
      out[attempt] = jobs.delay_for(attempt, opts)
    end
    return out
  end

  it("can express a first delay that doubles", function()
    assert.same({ 60, 120, 240, 480, 960 },
      schedule({ first = 60, factor = 2, max = 4 * 60 * 60 }, 5))
  end)

  it("caps where it is told to", function()
    local s = schedule({ first = 60, factor = 2, max = 300 }, 6)
    assert.same({ 60, 120, 240, 300, 300, 300 }, s)
  end)

  -- The compatibility claim, checked rather than asserted in a comment: for
  -- any `base`, the old formula and the new one agree exactly.
  it("moves no existing configuration by a microsecond", function()
    for _, base in ipairs { 2, 3, 5, 10 } do
      local got = schedule({ base = base, max = math.huge }, 5)
      for attempt = 1, 5 do
        assert.equal(base ^ attempt, got[attempt],
          ("base = %d, attempt %d"):format(base, attempt))
      end
    end
  end)
end)

describe("a delay shorter than a second", function()
  -- WHAT HAPPENED, and it was found by a probe misbehaving rather than by
  -- reading anything. A dispatcher test with a 10ms backoff reported that an
  -- endpoint failing every time was tried ONCE and then vanished -- not
  -- retried, not dead-lettered, gone.
  --
  -- It had been rescheduled correctly. `Store:schedule` computed
  -- `time.now() + delay`, and `time.now()` is `os.time`, which counts whole
  -- seconds. `run_at` was `N + 0.01`; `promote` compared it against `N` until
  -- the second ticked over. Every sub-second delay meant "the next second
  -- boundary".
  --
  -- The consequence in production is not about tests. `jobs.delay_for` returns
  -- a FRACTIONAL delay on purpose -- full jitter, a uniform draw across the
  -- window, which exists so that a hundred jobs failing against a database
  -- that has just come back do not all retry on the same second. With
  -- one-second resolution and a two-second default window, they retried on one
  -- of two.
  --
  -- The memory store now schedules against `monotime`, which is sub-second and
  -- immune to a wall clock being stepped -- the same argument deadlines
  -- already won. The Redis store reads the microseconds from `TIME` that it
  -- was already fetching and throwing away.
  local jobs   = require "akkar.jobs"
  local memory = require "akkar.jobs.memory"
  local time   = require "akkar.time"

  it("comes due before the next whole second", function()
    local queue = jobs.new(memory.store(), "port_subsecond", {
      retries = 3,
      backoff = { first = 0.02, factor = 2, max = 0.05, jitter = false },
    })
    queue:push("work", { n = 1 })

    local job = queue:pop(0)
    assert.is_truthy(job, "nothing to pop")
    queue:fail(job, "boom")

    -- Nothing yet: the backoff has not elapsed.
    assert.is_nil(queue:pop(0), "the job came back before its backoff")

    -- Wait past 20ms of WALL time without relying on the second boundary.
    local started = time.monotime()
    while time.monotime() - started < 0.08 do end

    assert.is_truthy(queue:pop(0),
      "a sub-second backoff did not come due; scheduling is quantised to seconds")
  end)

  it("keeps the fraction the jitter produced", function()
    -- `delay_for` returning fractions is only meaningful if the store can
    -- store them. Two delays 30ms apart must not land on the same instant.
    local store = memory.store()
    store:schedule("k", "a", 0.01)
    store:schedule("k", "b", 0.04)
    assert.equal(0, store:promote "k", "both were due immediately")

    local started = time.monotime()
    while time.monotime() - started < 0.02 do end
    assert.equal(1, store:promote "k",
      "the two delays were indistinguishable, so the jitter did nothing")
  end)
end)

describe("an integer that arrived as JSON", function()
  -- WHAT HAPPENED. The service computes fees in integer cents and says so in
  -- its own source: "ALL arithmetic is integer-only ... eliminates IEEE 754
  -- representation errors from the previous float64 path."
  --
  -- JSON has one number type, so `cjson` decodes `120000` as the FLOAT
  -- `120000.0`. `v.integer` accepted it -- correctly, it is integral -- and
  -- passed it through unchanged. The same rule fed from a query string
  -- produced a real integer, because the coercing path runs `tonumber` on a
  -- string.
  --
  -- So one rule returned two subtypes depending on where the value came from,
  -- and `//`, `%`, the bitwise operators and `string.format("%d", ...)` all
  -- behave differently across that line. `%d` on a float with no integer
  -- representation RAISES.
  it("comes back as a Lua integer, not an integral float", function()
    local decoded = cjson.decode '{"amount_cents":120000}'
    assert.equal("float", math.type(decoded.amount_cents))   -- what cjson gives

    local out = akkar.validate(decoded, { amount_cents = v.integer { min = 1 } })
    assert.equal("integer", math.type(out.amount_cents),
      "v.integer should produce an integer, not an integral float")
  end)

  it("agrees with the value the same rule produces from a query string", function()
    local body  = akkar.validate(cjson.decode '{"n":7}', { n = v.integer {} })
    local query = akkar.validate({ n = "7" }, { n = v.integer {} }, true)
    assert.equal(math.type(query.n), math.type(body.n))
    assert.equal(query.n, body.n)
  end)

  it("keeps rejecting a value that is not whole", function()
    local _, err = akkar.validate(cjson.decode '{"n":1.5}', { n = v.integer {} })
    assert.equal("expected integer", err.n)
  end)

  it("leaves a number too large for an integer alone rather than mangling it", function()
    -- `math.tointeger(1e20)` is nil: it does not fit in a 64-bit integer.
    -- Returning the float unchanged is the honest answer -- the alternative
    -- is silently substituting a different number.
    local out = akkar.validate(cjson.decode '{"n":1e20}', { n = v.integer {} })
    assert.equal("float", math.type(out.n))
    assert.equal(1e20, out.n)
  end)

  it("makes the ported money arithmetic exact", function()
    -- The fee calculation from the original, line for line.
    local function calc_fee(gross)
      local fee = (gross * 500 + 9999) // 10000
      if fee < 300 then fee = 300 end
      if fee > gross then fee = gross end
      local seller = (fee * 70 + 99) // 100
      return fee, seller, fee - seller
    end

    local decoded = cjson.decode '{"amount_cents":120000}'
    local out = akkar.validate(decoded, { amount_cents = v.integer { min = 1 } })
    local fee, seller, buyer = calc_fee(out.amount_cents)

    assert.equal(6000, fee)
    assert.equal(4200, seller)
    assert.equal(1800, buyer)
    assert.equal("integer", math.type(fee))
    -- `%d` is the operation that would have raised on a float without an
    -- integer representation, and the reason this matters beyond tidiness.
    assert.equal("6000", string.format("%d", fee))
  end)
end)
