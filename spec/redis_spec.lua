--[[
akkar.redis tests.

Two halves.  The protocol half needs no server: encoding a command and parsing
a reply are pure functions over strings, and testing them against a live Redis
would prove less, not more.  The integration half needs a real server and skips
when there is none.

  docker run -d --name akkar-redis -p 6379:6379 redis:7-alpine
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local redis = require "akkar.redis"

describe("RESP encoding", function()
  local encode = redis.Redis._encode

  it("sends a command as an array of bulk strings", function()
    assert.equal("*1\r\n$4\r\nPING\r\n", encode "PING")
    assert.equal("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n", encode("SET", "k", "v"))
  end)

  it("keeps a value containing spaces and newlines intact", function()
    -- Length-prefixed, so a value that looks like protocol is still a value.
    -- The same reason SQL parameters are bound rather than spliced.
    local hostile = "a b\r\n*1\r\n$4\r\nPING"
    local wire = encode("SET", "k", hostile)
    assert.equal("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$" .. #hostile .. "\r\n" .. hostile .. "\r\n",
                 wire)
  end)

  it("stringifies non-string arguments", function()
    assert.equal("*3\r\n$6\r\nEXPIRE\r\n$1\r\nk\r\n$2\r\n60\r\n", encode("EXPIRE", "k", 60))
  end)
end)

describe("RESP reply parsing", function()
  local read_reply = redis.Redis._read_reply

  -- A fake socket serving a canned reply, so the parser is what is under test.
  local function feeding(payload)
    local offset = 1
    return {
      read = function(_, spec)
        if spec == "*L" then
          local stop = payload:find("\n", offset, true)
          if not stop then return nil end
          local line = payload:sub(offset, stop)
          offset = stop + 1
          return line
        end
        local chunk = payload:sub(offset, offset + spec - 1)
        offset = offset + spec
        return chunk
      end,
    }
  end

  it("reads a simple string", function()
    assert.equal("PONG", read_reply(feeding "+PONG\r\n"))
  end)

  it("reads an integer", function()
    assert.equal(42, read_reply(feeding ":42\r\n"))
  end)

  it("reads a bulk string, including an empty one", function()
    assert.equal("hello", read_reply(feeding "$5\r\nhello\r\n"))
    assert.equal("", read_reply(feeding "$0\r\n\r\n"))
  end)

  it("reads a bulk string that contains CRLF", function()
    -- Length-prefixed, so the parser must not stop at the first newline.
    assert.equal("a\r\nb", read_reply(feeding "$4\r\na\r\nb\r\n"))
  end)

  it("turns a nil reply into nil rather than a sentinel", function()
    assert.is_nil(read_reply(feeding "$-1\r\n"))
    assert.is_nil(read_reply(feeding "*-1\r\n"))
  end)

  it("reads a nested array", function()
    local value = read_reply(feeding "*2\r\n$1\r\na\r\n*2\r\n:1\r\n:2\r\n")
    assert.equal("a", value[1])
    assert.same({ 1, 2 }, value[2])
  end)

  it("returns a Redis error as an error value, not a raise", function()
    local value, err = read_reply(feeding "-WRONGTYPE not a list\r\n")
    assert.is_nil(value)
    assert.equal("WRONGTYPE not a list", err)
  end)

  it("reports an unexpected tag instead of guessing", function()
    local _, err = read_reply(feeding "?what\r\n")
    assert.is_truthy(tostring(err):match "unexpected RESP tag")
  end)
end)

-- ---------------------------------------------------------------------------

local function reachable()
  local ok, conn = pcall(redis.connect { pool_size = 0 })
  if ok then conn:close() end
  return ok
end

if not reachable() then
  describe("akkar.redis (integration)", function()
    pending("Redis is not reachable on 127.0.0.1:6379; skipping")
  end)
  return
end

describe("a handshake the server refuses", function()
  -- AUTH and SELECT run on a socket that is already open. Raising out of
  -- `open` left it with nothing in this process referencing it: the pool
  -- restores its slot on the error path, and the descriptor does not come
  -- back. A wrong password therefore leaked one socket per attempt -- and a
  -- pool under load retries, so that is one per request.
  --
  -- Counted rather than reasoned about, and deliberately WITHOUT forcing a
  -- collection first: a descriptor that only returns when the collector runs
  -- is the trap this project already recorded once, where an OS limit was
  -- quietly tied to the pace of the GC.
  local function open_fds()
    local pid = io.open("/proc/self/stat"):read "n"
    local n = 0
    for _ in io.popen("ls /proc/" .. pid .. "/fd 2>/dev/null"):lines() do n = n + 1 end
    return n
  end

  it("does not leave the socket open", function()
    local before = open_fds()
    for _ = 1, 25 do
      local ok = pcall(function()
        return redis.connect { pool_size = 0, password = "definitely-not-the-password" }()
      end)
      assert.is_false(ok, "Redis accepted a password it should not have")
    end
    local after = open_fds()

    assert.is_true(after - before < 10,
      ("25 refused handshakes leaked descriptors: %d -> %d"):format(before, after))
  end)
end)

describe("akkar.redis against a real server", function()
  local conn
  before_each(function() conn = redis.connect { pool_size = 0 }() end)
  after_each(function() if conn then conn:del "akkar:spec" conn:close() end end)

  it("returns nil for a missing key", function()
    conn:del "akkar:spec"
    assert.is_nil(conn:get "akkar:spec")
  end)

  it("round-trips a value that looks like protocol", function()
    local hostile = "*1\r\n$4\r\nPING\r\n"
    conn:set("akkar:spec", hostile)
    assert.equal(hostile, conn:get "akkar:spec")
  end)

  it("counts with incr and expires with a ttl", function()
    conn:del "akkar:spec"
    assert.equal(1, conn:incr "akkar:spec")
    assert.equal(2, conn:incr "akkar:spec")
    conn:expire("akkar:spec", 60)
    assert.is_true(conn:ttl "akkar:spec" > 50)
  end)

  it("raises a Redis error as an error, with the server's message", function()
    conn:del "akkar:spec"
    conn:set("akkar:spec", "not a number")
    local ok, err = pcall(function() return conn:incr "akkar:spec" end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "redis:")
  end)
end)
