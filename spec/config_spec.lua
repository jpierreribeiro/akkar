--[[
Typed configuration, and secrets that cannot be printed.

The redaction half of this file is written the way a leak actually happens.
Nobody writes `print(password)`. What gets written is `log:info("boot",
{ config = config })` while chasing something else, and the secret is in the
aggregator for ever. So the tests below do not ask "does :reveal() work" --
they take every ordinary way a Lua value reaches a string and assert the
secret is not in the output: `tostring`, `%s`, `..`, `akkar.json.encode`, a
real `akkar.log` sink in both of its formats, and a hand-written recursive
walk standing in for any serialiser nobody has written yet.

The value used throughout is a nonsense string chosen to be greppable, so a
leak is a substring match rather than a judgement call.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar  = require "akkar"
local config = require "akkar.config"

local PASSWORD = "hunter2-CORRECT-HORSE-BATTERY"

local function loaded(overrides)
  local options = {
    schema = {
      port = { type = "number", default = 8080 },
      database = {
        url      = { type = "string", required = true },
        password = { type = "string", required = true, secret = true },
      },
    },
    values = {
      database = { url = "postgres://localhost/app", password = PASSWORD },
    },
    env = {},
  }
  for key, value in pairs(overrides or {}) do options[key] = value end
  return config.load(options)
end

-- Every string reachable from `value` by ordinary table traversal.  This is
-- what any serialiser nobody has written yet will do, so it is what the
-- secret has to survive.
local function every_string(value, found, seen)
  found, seen = found or {}, seen or {}
  if type(value) == "string" then
    found[#found + 1] = value
  elseif type(value) == "table" and not seen[value] then
    seen[value] = true
    for k, v in pairs(value) do
      every_string(k, found, seen)
      every_string(v, found, seen)
    end
  end
  return found
end

local function leaks(text)
  return tostring(text):find(PASSWORD, 1, true) ~= nil
end

describe("a secret cannot be printed by accident", function()
  it("prints as [redacted] through tostring", function()
    assert.equal("[redacted]", tostring(loaded().database.password))
  end)

  it("prints as [redacted] through string.format %s", function()
    local formatted = string.format("connecting with %s", loaded().database.password)
    assert.equal("connecting with [redacted]", formatted)
    assert.is_false(leaks(formatted))
  end)

  it("prints as [redacted] through concatenation, on either side", function()
    -- `..` is the one that catches people: it is not `tostring`, it is
    -- `__concat`, and without it this line would raise instead -- which is
    -- safe but arrives in production as a 500 rather than a log line.
    local secret = loaded().database.password
    assert.equal("pw=[redacted]", "pw=" .. secret)
    assert.equal("[redacted]!", secret .. "!")
  end)

  it("contains nothing a table walk can find", function()
    local secret = loaded().database.password
    assert.is_nil(next(secret), "the wrapper holds data a walker will print")
    assert.same({}, every_string(secret))
  end)

  it("survives a recursive walk of the whole config", function()
    local c = loaded()
    for _, text in ipairs(every_string(c)) do
      assert.not_equal(PASSWORD, text,
        "a plain traversal of the config found the secret")
    end
    -- and the walk did find the non-secret values, so it is a real walk
    local found = table.concat(every_string(c), " ")
    assert.is_truthy(found:find("postgres://localhost/app", 1, true))
  end)

  it("survives tostring of the whole config", function()
    local text = tostring(loaded())
    assert.is_false(leaks(text), "tostring(config) printed the secret")
    assert.is_truthy(text:find("database.password = [redacted]", 1, true))
    assert.is_truthy(text:find("database.url = postgres://localhost/app", 1, true))
  end)

  it("survives akkar.json.encode of the whole config", function()
    local encoded = akkar.json.encode(loaded())
    assert.is_false(leaks(encoded), "the serialiser emitted the secret")
    -- Stated exactly, because the guarantee and the display are different
    -- things: cjson consults no metamethod, so it cannot be made to print the
    -- word.  What it prints is an empty object, because the wrapper is empty.
    assert.is_truthy(encoded:find('"password":{}', 1, true))
    -- Decoded rather than matched as text: cjson escapes a forward slash, so
    -- the URL appears as `postgres:\/\/localhost\/app` in the wire form and a
    -- literal find for it fails while the value is perfectly present. Round
    -- tripping asserts the value, not the escaping.
    local back = akkar.json.decode(encoded)
    assert.equal("postgres://localhost/app", back.database.url)
    assert.same({}, back.database.password)
  end)

  it("survives akkar.json.encode of the secret on its own", function()
    assert.equal("{}", akkar.json.encode(loaded().database.password))
  end)

  it("survives a real logger, in JSON format", function()
    local lines = {}
    local log = akkar.log.new { format = "json", sink = function(l) lines[#lines + 1] = l end }
    log:info("boot", { config = loaded() })
    log:info("boot", { password = loaded().database.password })
    local text = table.concat(lines)
    assert.is_false(leaks(text), "the secret reached the log sink")
    assert.is_truthy(text:find("boot", 1, true))     -- the line was written
  end)

  it("survives a real logger, in text format", function()
    -- Text format stringifies differently -- `cjson.encode` for tables,
    -- `tostring` for everything else -- so it is a second code path and gets
    -- a second test rather than an assumption.
    local lines = {}
    local log = akkar.log.new { format = "text", sink = function(l) lines[#lines + 1] = l end }
    log:info("boot", { config = loaded() })
    log:info("boot", { password = loaded().database.password })
    log:info("boot", { password = tostring(loaded().database.password) })
    local text = table.concat(lines)
    assert.is_false(leaks(text), "the secret reached the log sink")
    assert.is_truthy(text:find("[redacted]", 1, true))
  end)

  it("cannot be unwrapped by replacing its metatable", function()
    local secret = loaded().database.password
    assert.equal("akkar.config: secret", getmetatable(secret))
    assert.is_false(pcall(setmetatable, secret,
                          { __tostring = function() return "gotcha" end }))
    assert.equal("[redacted]", tostring(secret))
  end)

  it("is immutable", function()
    local secret = loaded().database.password
    assert.is_false(pcall(function() secret.value = "x" end))
  end)
end)

describe("a secret is still usable", function()
  it("yields the real value when explicitly revealed", function()
    assert.equal(PASSWORD, loaded().database.password:reveal())
  end)

  it("is recognisable, so other code can redact rather than print {}", function()
    local c = loaded()
    assert.is_true(config.is_secret(c.database.password))
    assert.is_false(config.is_secret(c.database.url))
    assert.is_false(config.is_secret "just a string")
  end)

  it("renders as the word through :redacted()", function()
    local plain = loaded():redacted()
    assert.equal("[redacted]", plain.database.password)
    assert.equal("postgres://localhost/app", plain.database.url)
    local encoded = akkar.json.encode(plain)
    assert.is_false(leaks(encoded))
    assert.is_truthy(encoded:find("[redacted]", 1, true))
  end)

  it("wraps a value minted at runtime, not only one from a schema", function()
    local token = config.secret "tok_live_abcdef"
    assert.equal("[redacted]", tostring(token))
    assert.equal("tok_live_abcdef", token:reveal())
  end)

  it("keeps two secrets apart", function()
    local a, b = config.secret "one", config.secret "two"
    assert.equal("one", a:reveal())
    assert.equal("two", b:reveal())
  end)
end)

describe("types", function()
  local function value_of(spec, raw, env)
    return config.load {
      schema = { setting = spec },
      values = raw ~= nil and { setting = raw } or nil,
      env = env or {},
    }.setting
  end

  it("reads numbers from a table and from the environment", function()
    assert.equal(3000, value_of({ type = "number" }, 3000))
    -- The environment only ever supplies strings; the schema is what turns
    -- one into a number, once, instead of at every call site.
    assert.equal(3000, value_of({ type = "number" }, nil, { SETTING = "3000" }))
  end)

  it("reads booleans from the spellings people actually write", function()
    for _, text in ipairs { "true", "1", "yes", "on", "TRUE", "On" } do
      assert.is_true(value_of({ type = "boolean" }, nil, { SETTING = text }), text)
    end
    for _, text in ipairs { "false", "0", "no", "off", "OFF" } do
      assert.is_false(value_of({ type = "boolean" }, nil, { SETTING = text }), text)
    end
    assert.is_true(value_of({ type = "boolean" }, true))
  end)

  it("turns a duration into seconds, always", function()
    -- Not "30s" kept as a string for the reader to parse: that is how one
    -- call site ends up treating it as milliseconds.
    assert.equal(0.5, value_of({ type = "duration" }, "500ms"))
    assert.equal(30, value_of({ type = "duration" }, "30s"))
    assert.equal(300, value_of({ type = "duration" }, "5m"))
    assert.equal(7200, value_of({ type = "duration" }, "2h"))
    assert.equal(86400, value_of({ type = "duration" }, "1d"))
    assert.equal(45, value_of({ type = "duration" }, "45"), "a bare number is seconds")
    assert.equal(45, value_of({ type = "duration" }, 45))
  end)

  it("refuses a duration with a unit nobody defined", function()
    local ok, err = pcall(value_of, { type = "duration" }, "5 fortnights")
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("duration", 1, true))
  end)

  it("refuses a boolean that is neither", function()
    local ok, err = pcall(value_of, { type = "boolean" }, nil, { SETTING = "maybe" })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("maybe", 1, true))
  end)

  it("refuses a number that is not one, naming the setting", function()
    local ok, err = pcall(value_of, { type = "number" }, nil, { SETTING = "eight" })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("setting", 1, true))
    assert.is_truthy(tostring(err):find("eight", 1, true))
  end)

  it("does not silently stringify a number into a string setting", function()
    local ok, err = pcall(value_of, { type = "string" }, 8080)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("must be a string", 1, true))
  end)

  it("names an unknown type at boot", function()
    local ok, err = pcall(config.load, { schema = { x = { type = "ipv6" } } })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("ipv6", 1, true))
  end)
end)

describe("sources and precedence", function()
  local SCHEMA = {
    port = { type = "number", default = 8080 },
    database = { url = { type = "string", default = "postgres://default" } },
  }

  it("falls back to the default", function()
    local c = config.load { schema = SCHEMA, env = {} }
    assert.equal(8080, c.port)
    assert.equal("postgres://default", c.database.url)
  end)

  it("prefers the table over the default", function()
    local c = config.load { schema = SCHEMA, values = { port = 3000 }, env = {} }
    assert.equal(3000, c.port)
  end)

  it("prefers the environment over the table", function()
    -- The table is what is checked into the repository; the environment is
    -- what the deploy sets.  A deploy that cannot override a checked-in value
    -- needs a commit to change a password.
    local c = config.load { schema = SCHEMA, values = { port = 3000 },
                            env = { PORT = "9999" } }
    assert.equal(9999, c.port)
  end)

  it("derives the variable name from the path", function()
    local c = config.load { schema = SCHEMA,
                            env = { DATABASE_URL = "postgres://from-env" } }
    assert.equal("postgres://from-env", c.database.url)
  end)

  it("lets an explicit name win over the derivation", function()
    local c = config.load {
      schema = { database = { url = { type = "string", env = "PGURL", required = true } } },
      env = { PGURL = "postgres://explicit", DATABASE_URL = "postgres://derived" },
    }
    assert.equal("postgres://explicit", c.database.url)
  end)

  it("lets a setting opt out of the environment entirely", function()
    local c = config.load {
      schema = { port = { type = "number", env = false, default = 8080 } },
      env = { PORT = "9999" },
    }
    assert.equal(8080, c.port)
  end)
end)

describe("failing at startup", function()
  it("refuses to load when a required value is missing, and names it", function()
    local ok, err = pcall(config.load, {
      schema = { database = { url = { type = "string", required = true } } },
      env = {},
    })
    assert.is_false(ok)
    err = tostring(err)
    assert.is_truthy(err:find("database.url", 1, true))
    assert.is_truthy(err:find("DATABASE_URL", 1, true),
      "the error did not say which environment variable would supply it")
  end)

  it("reports every missing value, not the first", function()
    -- One at a time turns a first deploy into a sequence of restarts, each
    -- finding the next thing nobody was told about.
    local ok, err = pcall(config.load, {
      schema = {
        token = { type = "string", required = true, secret = true },
        database = {
          url      = { type = "string", required = true },
          password = { type = "string", required = true, secret = true },
        },
      },
      env = {},
    })
    assert.is_false(ok)
    err = tostring(err)
    assert.is_truthy(err:find("database.url", 1, true))
    assert.is_truthy(err:find("database.password", 1, true))
    assert.is_truthy(err:find("token", 1, true))
  end)

  it("names a typo in the values table, the way a route option is named", function()
    local ok, err = pcall(config.load, {
      schema = { timeout = { type = "duration", default = "30s" } },
      values = { timout = "5s" },
      env = {},
    })
    assert.is_false(ok)
    err = tostring(err)
    assert.is_truthy(err:find("timout", 1, true))
    assert.is_truthy(err:find("did you mean 'timeout'", 1, true))
  end)

  it("names a typo in a schema declaration", function()
    local ok, err = pcall(config.load, {
      schema = { timeout = { type = "duration", requried = true } },
      env = {},
    })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("requried", 1, true))
  end)

  it("names an unknown option to load itself", function()
    local ok, err = pcall(config.load, { schema = {}, valus = {} })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("valus", 1, true))
  end)

  it("refuses a scalar where a section was declared", function()
    local ok, err = pcall(config.load, {
      schema = { database = { url = { type = "string", default = "x" } } },
      values = { database = "postgres://oops" },
      env = {},
    })
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("database", 1, true))
  end)
end)

describe("reading the loaded config", function()
  it("errors on a setting that was never declared, and suggests one", function()
    -- Returning nil for `config.databse` is how a typo becomes a nil index
    -- three frames away, in a handler, at request time.
    local c = loaded()
    local ok, err = pcall(function() return c.databse end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("did you mean 'database'", 1, true))
  end)

  it("returns nil for a declared setting that was never set", function()
    -- A legitimate absence, unlike a typo.
    local c = config.load { schema = { port = { type = "number" } }, env = {} }
    assert.is_nil(c.port)
  end)

  it("refuses a setting invented after load", function()
    local c = loaded()
    local ok, err = pcall(function() c.prot = 1 end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):find("read-only", 1, true))
  end)

  it("does NOT stop an existing setting being overwritten, and says so", function()
    -- Asserted rather than wished for. `__newindex` fires only on an absent
    -- key, so a present one is written raw; Lua has no write barrier for it.
    -- The alternative -- a proxy over a private store -- would leave the
    -- config table empty, and `akkar.json.encode(config)` would emit `{}`.
    -- Serialising to say what this process came up with is worth more than an
    -- immutability claim that would then have to be enforced by hope.
    local c = loaded()
    c.port = 1
    assert.equal(1, c.port)
  end)

  it("reads a section the same way", function()
    local c = loaded()
    local ok = pcall(function() return c.database.urrl end)
    assert.is_false(ok)
    assert.equal(8080, c.port)
  end)
end)
