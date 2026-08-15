--[[
Streaming responses — readiness item 6.

The design tension this had to resolve: "handlers return the response; they
never mutate a context" is akkar's central invariant, and streaming appears to
break it. It does not, because the handler still returns a value — one that
describes a body produced on demand.

What is worth testing is not that bytes come out. It is the three things the
shape costs: the status commits with the first byte, capabilities have to
outlive the handler, and a producer that fails cannot become a 500.
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"
local cjson = require "cjson"

describe("akkar.stream through the test client", function()
  it("returns what the producer wrote, in order", function()
    local app = akkar.new()
    app:get("/export", function()
      return akkar.stream(function(write)
        write '{"rows":['
        for i = 1, 3 do
          if i > 1 then write "," end
          write(cjson.encode { id = i })
        end
        write ']}'
      end)
    end)

    local res = app:test():get("/export")
    assert.equal(200, res.status)
    assert.same({ rows = { { id = 1 }, { id = 2 }, { id = 3 } } },
                cjson.decode(res.raw))
  end)

  it("still lets the handler answer normally before the first write", function()
    -- The escape route the docstring promises: validate first, and an ordinary
    -- response still works because nothing has been committed.
    local app = akkar.new()
    app:get("/export", function(req)
      if not req.query.token then return akkar.unauthorized() end
      return akkar.stream(function(write) write "ok" end)
    end)

    local client = app:test()
    assert.equal(401, client:get("/export").status)
    assert.equal("ok", client:get("/export?token=x").raw)
  end)

  it("takes a status and content type", function()
    local app = akkar.new()
    app:get("/csv", function()
      return akkar.stream(function(write) write "id,name\n1,ada\n" end,
                          { content_type = "text/csv", status = 201 })
    end)
    local res = app:test():get("/csv")
    assert.equal(201, res.status)
    assert.equal("id,name\n1,ada\n", res.raw)
  end)

  it("refuses anything that is not a function", function()
    local ok, err = pcall(akkar.stream, "not a function")
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "needs a function")
  end)

  it("raises rather than returning a partial body when the producer fails", function()
    -- On a socket this is a truncated response, which the test client cannot
    -- express.  Silently returning the partial body would let a broken
    -- producer pass its own tests.
    local app = akkar.new()
    app:get("/broken", function()
      return akkar.stream(function(write)
        write "half"
        error "the cursor died"
      end)
    end)

    local ok, err = pcall(function() app:test():get("/broken") end)
    assert.is_false(ok)
    assert.is_truthy(tostring(err):match "stream producer failed")
    assert.is_truthy(tostring(err):match "the cursor died")
  end)
end)

describe("akkar.stream and capabilities", function()
  it("keeps the database alive until the last byte, then releases it", function()
    -- The bug this prevents: releasing when the handler returns hands a live
    -- cursor to the next request.
    local released, used_after_return = false, false
    local fake_db = {
      one = function() return { n = 1 } end,
      many = function() return {} end,
      exec = function() end,
      transaction = function(_, fn) return fn() end,
      release = function() released = true end,
    }

    local app = akkar.new()
    app:get("/export", function(req)
      local db = req.db
      return akkar.stream(function(write)
        -- If the connection had been released already, this is use-after-free.
        used_after_return = not released
        write(cjson.encode(db:one "select 1"))
      end)
    end)

    local res = app:test { db = function() return fake_db end }:get("/export")
    assert.equal('{"n":1}', res.raw)
    assert.is_true(used_after_return, "the connection was released too early")
    assert.is_true(released, "the connection was never released")
  end)

  it("releases even when the producer fails", function()
    local released = false
    local fake_db = {
      one = function() end, many = function() return {} end,
      exec = function() end, transaction = function(_, fn) return fn() end,
      release = function() released = true end,
    }

    local app = akkar.new()
    app:get("/broken", function(req)
      local _ = req.db
      return akkar.stream(function() error "boom" end)
    end)

    pcall(function() app:test { db = function() return fake_db end }:get("/broken") end)
    assert.is_true(released, "a failing stream leaked its connection")
  end)
end)

describe("akkar.stream over a real socket", function()
  -- Chunked framing is lua-http's job, and whether akkar hands it the right
  -- signals is not observable from the test client.
  local cqueues = require "cqueues"
  local request = require "http.request"
  local PORT = 8395
  local answers = {}

  setup(function()
    local app = akkar.new()
    app:get("/export", function()
      return akkar.stream(function(write)
        write '{"rows":['
        for i = 1, 500 do
          if i > 1 then write "," end
          write(cjson.encode { id = i, name = "user " .. i })
        end
        write ']}'
      end)
    end)

    local cq = cqueues.new()
    cq:wrap(function()
      pcall(function()
        app:run { port = PORT, check_capabilities = false,
                  log = akkar.log.new { level = "error" } }
      end)
    end)
    cq:wrap(function()
      cqueues.sleep(0.15)
      for _, method in ipairs { "GET", "HEAD" } do
        local req = request.new_from_uri("http://127.0.0.1:" .. PORT .. "/export")
        req.headers:upsert(":method", method)
        local h, stream = assert(req:go(10))
        answers[method] = {
          status = tonumber(h:get ":status"),
          content_type = h:get "content-type",
          content_length = h:get "content-length",
          body = stream:get_body_as_string(),
        }
      end
      app:stop(1)
    end)
    assert(cq:loop(30))
  end)

  it("delivers the whole body, reassembled from its chunks", function()
    local got = answers.GET
    assert.equal(200, got.status)
    local decoded = cjson.decode(got.body)
    assert.equal(500, #decoded.rows)
    assert.equal(500, decoded.rows[500].id)
    assert.equal("user 1", decoded.rows[1].name)
  end)

  it("sends no content-length, because the length is not known", function()
    -- Its absence is what makes the response chunked.  A content-length here
    -- would be a number akkar invented.
    assert.is_nil(answers.GET.content_length)
    assert.equal("application/json", answers.GET.content_type)
  end)

  it("answers HEAD with the headers and no body", function()
    assert.equal(200, answers.HEAD.status)
    assert.equal("", answers.HEAD.body)
  end)
end)

describe("a streamed response the server cannot write", function()
  -- A stream's release is deferred onto the response and called by the server
  -- once the body has gone out. It sat AFTER `write_headers` and after the
  -- terminating chunk, both of which are outside the producer's own pcall --
  -- so anything raising there skipped the release entirely and leaked one
  -- pool slot, permanently, per occurrence.
  --
  -- The suite could not see it. Every other release test goes through
  -- `App:test`, which releases on both paths where the server did not, so the
  -- copy that was correct is the copy that was tested.
  local cqueues = require "cqueues"
  local request = require "http.request"
  local PORT = 8391

  it("still releases what the request acquired", function()
    local acquired, released = 0, 0
    local function db_factory()
      acquired = acquired + 1
      return {
        release = function() released = released + 1 end,
        one = function() end, many = function() end,
        exec = function() end, transaction = function() end,
      }
    end

    local app = akkar.new()
    app:get("/export", function(req)
      local _ = req.db                  -- acquire, so there is something to leak
      -- A header value that is not a string. It is refused when the headers
      -- are written, which is after the handler returned and after the
      -- capability was taken: an ordinary handler bug that must not cost a
      -- connection for the life of the process.
      return akkar.stream(function(write) write '{"ok":true}' end,
                          { headers = { ["x-rows"] = 12 } })
    end)

    local cq = cqueues.new()
    cq:wrap(function()
      pcall(function()
        app:run { port = PORT, check_capabilities = false, db = db_factory,
                  log = akkar.log.new { level = "error", sink = function() end } }
      end)
    end)
    cq:wrap(function()
      cqueues.sleep(0.15)
      pcall(function()
        local req = request.new_from_uri("http://127.0.0.1:" .. PORT .. "/export")
        local _, stream = req:go(5)
        if stream then pcall(function() stream:get_body_as_string(2) end) end
      end)
      cqueues.sleep(0.2)
      app:stop(2)
    end)
    assert(cq:loop(30))

    assert.equal(1, acquired, "the handler never took the capability")
    assert.equal(acquired, released,
      "the response could not be written and the capability leaked with it")
    assert.equal(0, app.in_flight, "the in-flight count never came back")
  end)
end)
