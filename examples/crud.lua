--[[
Ten realistic scenarios for a CRUD service, running against a real Postgres.

Each section marked CHOICE has alternatives written up in docs/DECISIONS.md.
What is written here is the option I settled on; the others are recorded there
so they can be compared side by side.

  setup: see "Running the examples" in README.md
  run:   PORT=8099 lua5.4 examples/crud.lua
]]

package.path = "./?.lua;./?/init.lua;" .. package.path

local akkar = require "akkar"
local db    = require "akkar.db"
local redis = require "akkar.redis"
local logging = require "akkar.log"
local openapi = require "akkar.openapi"
local v     = akkar.v

local app = akkar.new()

-- ============================================================================
-- Global middleware.  `next` returns the response, so post-processing works.
-- ============================================================================

app:use(function(req, next)
  local t0 = require("cqueues").monotime()
  local res = next(req)
  -- req.log already carries the request id; nothing here has to pass it.
  req.log:info("request", {
    method = req.method, path = req.path, status = res.status,
    duration_ms = math.floor((require("cqueues").monotime() - t0) * 1000),
  })
  return res
end)

-- ============================================================================
-- Authentication.  CHOICE: middleware populates `req.user`.
--
-- Foolproofing: `req.user` starts out as a guard.  Forget to apply the
-- middleware and read it anyway, and the error says exactly that instead of
-- "attempt to index a nil value".
-- ============================================================================

local function authenticate(req, next)
  -- req.headers is a plain lowercase table whether this request came off a
  -- socket or from the in-process test client.
  if req.headers.authorization ~= "Bearer secret" then
    return akkar.unauthorized "missing or invalid token"
  end
  req.user = { id = 1, name = "ada", role = "admin" }
  return next(req)
end

local function require_admin(req, next)
  if req.user.role ~= "admin" then return akkar.forbidden "admin only" end
  return next(req)
end

-- ============================================================================
-- 1. Validation.  Two spellings of the same thing; both coexist.
-- ============================================================================

-- Short form: rung 3 of the ladder, for someone starting out.
app:post("/users", {
  body = { name = "string", email = "string?" },
}, function(req)
  return akkar.created(req.db:one(
    "insert into users (name, email) values ($1, $2) returning id, name, email",
    req.body.name, req.body.email))
end)

-- Expressive form: same idea with constraints.  `"string?"` is nothing more
-- than sugar for `v.string { optional = true }`.
app:put("/users/:id", {
  params = { id = v.integer { min = 1 } },
  body = {
    name  = v.string { min = 1, max = 100 },
    email = v.string { optional = true, match = "^[^@]+@[^@]+$" },
    role  = v.string { optional = true, one_of = { "admin", "user" } },
  },
}, function(req)
  local user = req.db:one(
    "update users set name = $1, email = $2 where id = $3 returning id, name, email",
    req.body.name, req.body.email, req.params.id)
  return user or akkar.not_found "user not found"
end)

-- ============================================================================
-- 2. Query strings and pagination.  Query values arrive as strings and are
--    coerced by the schema, so `req.query.limit` is already a number here.
-- ============================================================================

app:get("/users", {
  query = {
    limit  = v.integer { optional = true, min = 1, max = 100, default = 20 },
    offset = v.integer { optional = true, min = 0, default = 0 },
    sort   = v.string  { optional = true, one_of = { "id", "name" }, default = "id" },
  },
}, function(req)
  local rows = req.db:many(
    "select id, name, email from users order by " ..
    (req.query.sort == "name" and "name" or "id") .. " limit $1 offset $2",
    req.query.limit, req.query.offset)
  local total = req.db:one "select count(*)::int as n from users"
  return {
    users = rows,
    page  = { limit = req.query.limit, offset = req.query.offset, total = total.n },
  }
end)

-- ============================================================================
-- 3. Response-as-error.  A deep layer signals HTTP without threading a return
--    value back through every frame.
--
--    `return akkar.not_found()` and `error(akkar.not_found())` both give a 404.
-- ============================================================================

local function find_user_or_404(database, id)
  local user = database:one("select id, name, email from users where id = $1", id)
  if not user then error(akkar.not_found("user " .. tostring(id) .. " not found")) end
  return user
end

-- The response schema is not decoration.  This handler does `select *` on
-- purpose: without the schema the password hash would go over the wire.
app:get("/users/:id", {
  params   = { id = v.integer { min = 1 } },
  response = { id = "integer", name = "string", email = "string?" },
}, function(req)
  local user = req.db:one("select * from users where id = $1", req.params.id)
  if not user then error(akkar.not_found("user " .. req.params.id .. " not found")) end
  return user
end)

-- ============================================================================
-- 4. Closure-scoped transaction.  Commit at the end, rollback on any error —
--    including a response thrown from inside it.
-- ============================================================================

app:post("/users/:id/transfer", {
  params = { id = v.integer { min = 1 } },
  body   = { to = v.integer { min = 1 } },
}, function(req)
  return req.db:transaction(function(tx)
    local from = find_user_or_404(tx, req.params.id)
    local to   = find_user_or_404(tx, req.body.to)
    tx:exec("update users set name = $1 where id = $2", from.name .. "*", to.id)
    return { moved_from = from.id, moved_to = to.id }
  end)
end)

-- Proves the rollback: the second user does not exist, so the whole
-- transaction unwinds and the client gets a 404 rather than a 500.
app:post("/users/:id/failing-transfer", {
  params = { id = v.integer { min = 1 } },
}, function(req)
  return req.db:transaction(function(tx)
    tx:exec("insert into users (name) values ('ghost')")
    find_user_or_404(tx, 999999)          -- throws 404, undoes the insert above
    return { never = true }
  end)
end)

-- ============================================================================
-- 5. Route-scoped middleware.  Runs after the global chain, on this route only.
-- ============================================================================

app:get("/me", { before = { authenticate } }, function(req)
  return req.user
end)

app:delete("/users/:id", {
  params = { id = v.integer { min = 1 } },
  before = { authenticate, require_admin },
}, function(req)
  local gone = req.db:one("delete from users where id = $1 returning id", req.params.id)
  if not gone then return akkar.not_found "user not found" end
  return akkar.no_content()
end)

-- Reads `req.user` WITHOUT the middleware — demonstrates the guard.
app:get("/forgotten", function(req)
  return { user = req.user.name }        -- clear error, not "index a nil value"
end)

-- ============================================================================
-- 6. Mounted sub-application.  An ordinary akkar.new(), mounted under a
--    prefix.  Stays testable on its own, without knowing where it lives.
-- ============================================================================

local health = akkar.new()
health:get("/live",  function() return { status = "live" } end)
health:get("/ready", function(req)
  local ok = pcall(function() req.db:one "select 1 as ok" end)
  return ok and { status = "ready" } or akkar.response(503, { status = "not ready" })
end)

app:mount("/health", health)

-- ============================================================================
-- 7. The cache capability.  `req.cache` needed no framework change: `cache`
--    was already a guarded slot, so passing it to app:run{} was enough.
-- ============================================================================

app:get("/users/:id/views", {
  params = { id = v.integer { min = 1 } },
}, function(req)
  local key = "views:" .. req.params.id
  local count = req.cache:incr(key)
  req.cache:expire(key, 3600)
  return { user = req.params.id, views = count }
end)

-- ============================================================================
-- 8. File upload.  A multipart body reaches the handler as an ordinary table,
--    so the schema looks like any other.
-- ============================================================================

app:post("/uploads", {
  body = { title = "string", file = "table" },
}, function(req)
  return akkar.created {
    title = req.body.title,
    filename = req.body.file.filename,
    content_type = req.body.file.content_type,
    bytes = req.body.file.size,
  }
end)

-- ============================================================================
-- 9. OpenAPI, generated from the schemas already declared above.  No route
--    describes itself twice.
-- ============================================================================

openapi.serve(app, "/openapi.json", { title = "akkar CRUD example", version = "0.1.0" })

-- Rung 0 still works.
app:get("/", function() return { hello = "world" } end)

-- ============================================================================

if ... == nil then      -- only start a server when run directly, not required
  app:run {
    port = tonumber(os.getenv "PORT") or 8080,
    db    = db.connect { port = 55432, database = "akkar",
                         user = "postgres", password = "akkar" },
    cache = redis.connect { port = 6379 },
    log   = logging.new { format = os.getenv "AKKAR_LOG_JSON" and "json" or "text" },
  }
end

return app
