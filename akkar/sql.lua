--[[
akkar.sql — SQL you can compose from data without being able to concatenate.

akkar's thesis is that a common mistake becomes an impossible state: a double
response cannot happen because handlers return, an orphaned `BEGIN` cannot
happen because transactions are closure-scoped. This is the same move applied
to the mistake that ends companies.

## The mistake

`db:many(sql, ...)` takes a string. The moment a filter arrives as data — from
a query string, from a saved view, from a tenant's own configuration — someone
writes this:

    local where = ""
    for field, value in pairs(req.query.filters) do
      where = where .. " and " .. field .. " = '" .. value .. "'"
    end
    return req.db:many("select * from users where 1=1" .. where)

It reviews fine. It works. It is a full compromise of the database, and every
SQL injection in history looks exactly like it.

Telling people not to do that is not a defence, because the reason they do it
is that the safe path did not exist.

## The shape

A fragment carries its text and its values together, and the values are never
text. Numbering happens once, at the end, when the whole statement is
assembled — so fragments compose without anyone tracking `$1` by hand, which
is the other half of why people give up and concatenate.

    local sql = require "akkar.sql"

    local q = sql.select("id, name, email"):from "users"
    if req.query.name then q:where("name like ?", req.query.name .. "%") end
    if req.query.min then q:where("age >= ?", req.query.min) end
    q:order("name"):limit(req.query.limit or 20)

    return req.db:many(q:build())

## What is a value and what is not

A value can never become SQL. An identifier — a table or column name — is not a
value and cannot be parameterised; Postgres has no placeholder for one. So
identifiers are checked against an allow-list the route declares, and anything
else is refused:

    q:order_by(req.query.sort, { "id", "name", "created_at" })

There is no escape hatch that takes an unchecked identifier. That is the point:
an escape hatch is where the injection goes.
]]

local M = {}

local Query = {}
Query.__index = Query

-- A Postgres identifier: letters, digits, underscore, optionally one dot for
-- a qualified name.  Deliberately narrower than what Postgres accepts, since
-- the cost of refusing an unusual-but-valid name is a clear error, and the
-- cost of accepting a crafted one is the database.
local IDENTIFIER = "^[%a_][%w_]*$"
local QUALIFIED  = "^[%a_][%w_]*%.[%a_][%w_]*$"

local function valid_identifier(name)
  return type(name) == "string"
     and (name:match(IDENTIFIER) ~= nil or name:match(QUALIFIED) ~= nil)
end

--- Checks an identifier against a list the caller declared.
--- Both tests matter: the pattern rejects a crafted string, the allow-list
--- rejects a real column the route never meant to expose.
local function checked_identifier(name, allowed, what)
  if not valid_identifier(name) then
    error(("akkar.sql: %s is not a valid identifier: %s")
          :format(what, tostring(name)), 0)
  end
  if allowed then
    for _, ok in ipairs(allowed) do
      if name == ok then return name end
    end
    error(("akkar.sql: %s '%s' is not in the allowed list (%s)")
          :format(what, name, table.concat(allowed, ", ")), 0)
  end
  return name
end

M.identifier = checked_identifier

-- PostgreSQL does not implicitly coerce a parameter declared as text into a
-- UUID column.  pgmoon deliberately declares Lua strings as text, so UUIDs
-- need an explicit SQL type while remaining bound values.  A small closed set
-- avoids turning this into a raw-cast escape hatch.
local CASTS = { uuid = true, jsonb = true, timestamptz = true }
local TYPED_VALUE = {}

function M.cast(value, postgres_type)
  if not CASTS[postgres_type] then
    error("akkar.sql: unsupported parameter cast: " .. tostring(postgres_type), 0)
  end
  return setmetatable({ value = value, postgres_type = postgres_type }, TYPED_VALUE)
end

function M.uuid(value) return M.cast(value, "uuid") end
function M.jsonb(value) return M.cast(value, "jsonb") end
function M.timestamptz(value) return M.cast(value, "timestamptz") end

local function typed_value(value)
  if type(value) == "table" and getmetatable(value) == TYPED_VALUE then
    return value.value, value.postgres_type
  end
  return value, nil
end

-- ==================================================================== builder
local function new_query(kind)
  return setmetatable({
    _kind = kind,
    _select = "*",
    _from = nil,
    _joins = {},
    _join_values = {},
    _where = {},
    _values = {},
    _set = {},
    _set_values = {},
    _insert = nil,
    _returning = nil,
    _group = nil,
    _order = nil,
    _limit = nil,
    _offset = nil,
    _for_update = false,
    _skip_locked = false,
    _on_conflict = nil,
    _scoped = false,
  }, Query)
end

function M.select(columns)
  local q = new_query "select"
  q._select = columns or "*"
  return q
end

--- `update`, `delete` and `insert` are here for one reason: an unscoped write
--- is worse than an unscoped read.  A tenant scope that only covered `select`
--- would leave the dangerous half of the surface outside it.
function M.update(table_name, allowed)
  local q = new_query "update"
  q._from = checked_identifier(table_name, allowed, "table name")
  return q
end

function M.delete_from(table_name, allowed)
  local q = new_query "delete"
  q._from = checked_identifier(table_name, allowed, "table name")
  return q
end

--- The column names come from the row's own keys, which on a real route means
--- they came from a request body.  They are identifiers, so they cannot be
--- parameterised -- every one is checked, and an allow-list is how a route
--- says which columns a client may write at all.
function M.insert_into(table_name, row, allowed_columns, allowed_table)
  local q = new_query "insert"
  q._from = checked_identifier(table_name, allowed_table, "table name")
  q._insert = {}
  local names = {}
  for column in pairs(row) do names[#names + 1] = column end
  table.sort(names)          -- `pairs` has no order; the SQL text must have one
  for _, column in ipairs(names) do
    checked_identifier(column, allowed_columns, "column name")
    q._insert[#q._insert + 1] = { column = column, value = row[column] }
  end
  return q
end

function Query:from(table_name, allowed)
  self._from = checked_identifier(table_name, allowed, "table name")
  return self
end

--- Sets a column on an update.  The column is an identifier, the value is a
--- value, and they can never trade places.
function Query:set(column, value, allowed)
  checked_identifier(column, allowed, "column name")
  self._set[#self._set + 1] = column .. " = ?"
  self._set_values[#self._set_values + 1] = value
  return self
end

function Query:returning(columns)
  self._returning = columns or "*"
  return self
end

--- A join's values live in their own list, not in the one `where` uses.
---
--- `build` emits every join before any condition, but both used to append to
--- the same flat `_values`, so the numbering ran in call order while the text
--- ran in clause order.  Confirmed:
---
---   :where("project_id = ?", 999):join("... acl.project_id = ?", 7)
---   -> join ... acl.project_id = $1 where (project_id = $2)   VALUES: 999, 7
---
--- The ACL check ran against the tenant id and the tenant filter against the
--- user id.  It survives review because the order only diverges when a
--- conditional `where` precedes an unconditional `join`: with the optional
--- filter absent the statement is correct, so the bug shows up as
--- mis-authorisation on exactly the requests that carry a filter.
function Query:join(clause, ...)
  -- `build` writes joins only into a SELECT.  Accepting one anywhere else
  -- would keep the values and drop the text they belong to, which is the same
  -- mis-binding from the other direction.
  if self._kind ~= "select" then
    error("akkar.sql: join is only valid on select queries", 0)
  end
  self._joins[#self._joins + 1] = { text = clause, n = select("#", ...) }
  for i = 1, select("#", ...) do
    self._join_values[#self._join_values + 1] = (select(i, ...))
  end
  return self
end

--- Adds a condition.  `?` marks a value; the value goes in the values list and
--- never into the text.  Conditions are joined with AND.
---
--- There is no `where_raw`.  A raw-SQL escape hatch is exactly the door this
--- module exists to close.
-- A condition may describe a row.  It may not change the SHAPE of the clause
-- it is joined into.
--
-- Wrapping each condition in parentheses stops a handler's own `or` from
-- capturing the tenant scope by precedence, but parentheses supplied by the
-- caller close the ones added here and reopen the hole:
--
--   :where "1=1) or (1=1"   ->   where (1=1) or (1=1) and (tenant_id = $1)
--
-- which is a scope bypass again, and was demonstrated returning other tenants'
-- rows.  So the structural characters are refused outright.  Depth may never go
-- negative and must end at zero, which every honest fragment satisfies -- and a
-- comment introducer or a statement separator has no business in a condition at
-- all.  This is the check the module's own "there is no where_raw" claim always
-- needed: the previous test asserted only that no key by that name existed on
-- the table, which checks the nameplate rather than the door.
local function refuse_structure(condition)
  local depth = 0
  for index = 1, #condition do
    local char = condition:sub(index, index)
    if char == "(" then depth = depth + 1
    elseif char == ")" then
      depth = depth - 1
      if depth < 0 then
        error(("akkar.sql: condition closes a parenthesis it did not open, "
            .. "which would restructure the where clause: %s"):format(condition), 0)
      end
    end
  end
  if depth ~= 0 then
    error(("akkar.sql: condition leaves %d parenthesis/es open: %s")
          :format(depth, condition), 0)
  end
  for _, forbidden in ipairs { "--", "/*", "*/", ";" } do
    if condition:find(forbidden, 1, true) then
      error(("akkar.sql: condition contains %q, which cannot appear in a "
          .. "condition: %s"):format(forbidden, condition), 0)
    end
  end
end

function Query:where(condition, ...)
  local count = select("#", ...)
  local placeholders = 0
  for _ in tostring(condition):gmatch "%?" do placeholders = placeholders + 1 end
  if placeholders ~= count then
    error(("akkar.sql: condition has %d placeholder(s) but %d value(s) were given: %s")
          :format(placeholders, count, tostring(condition)), 0)
  end
  refuse_structure(tostring(condition))

  self._where[#self._where + 1] = condition
  for i = 1, count do
    self._values[#self._values + 1] = (select(i, ...))
  end
  return self
end

--- `column IN (...)` with one placeholder per element, so a list arriving as
--- data stays data.  An empty list becomes `false` rather than invalid SQL --
--- `IN ()` is a syntax error in Postgres, and silently dropping the condition
--- would return every row instead of none.
function Query:where_in(column, values, allowed)
  checked_identifier(column, allowed, "column name")
  if #values == 0 then
    self._where[#self._where + 1] = "false"
    return self
  end
  local marks = {}
  for i = 1, #values do
    marks[i] = "?"
    self._values[#self._values + 1] = values[i]
  end
  self._where[#self._where + 1] = column .. " in (" .. table.concat(marks, ", ") .. ")"
  return self
end

--- Ordering takes an identifier, not a value, so it must be allow-listed.
function Query:order_by(column, allowed, direction)
  checked_identifier(column, allowed, "order column")
  local dir = tostring(direction or "asc"):lower()
  if dir ~= "asc" and dir ~= "desc" then
    error("akkar.sql: order direction must be asc or desc, got " .. tostring(direction), 0)
  end
  self._order = column .. " " .. dir
  return self
end

function Query:group_by(column, allowed)
  self._group = checked_identifier(column, allowed, "group column")
  return self
end

--- Limit and offset are values, so they are bound rather than written in.
function Query:limit(n)
  if math.type(n) ~= "integer" or n < 0 then
    error("akkar.sql: limit must be a non-negative integer, got " .. tostring(n), 0)
  end
  self._limit = n
  return self
end

function Query:offset(n)
  if math.type(n) ~= "integer" or n < 0 then
    error("akkar.sql: offset must be a non-negative integer, got " .. tostring(n), 0)
  end
  self._offset = n
  return self
end

--- Locks the selected rows until the surrounding transaction completes.
--- Only SELECT accepts the clause; making it a named builder operation keeps
--- handlers from reaching for a raw SQL suffix during inventory reservation.
function Query:for_update()
  if self._kind ~= "select" then
    error("akkar.sql: for_update is only valid on select queries", 0)
  end
  self._for_update = true
  return self
end

--- Takes the rows nobody else is holding, instead of waiting behind them.
---
--- Only meaningful with `for_update`, and only correct for a claim whose mark
--- is DURABLE -- a queue that, in the same transaction that locks the rows,
--- writes something (a lease, a status) that removes them from its own
--- predicate. Without that mark the two claimers read the same rows the moment
--- the first one commits, and skipping buys nothing.
---
--- With it, a second claimer takes a DIFFERENT batch rather than blocking on
--- the first and then finding its own rows filtered out by the re-evaluated
--- predicate -- which is how a queue ends up serialising N workers into one and
--- holding a pool connection to do it.
function Query:skip_locked()
  if self._kind ~= "select" then
    error("akkar.sql: skip_locked is only valid on select queries", 0)
  end
  self._skip_locked = true
  return self
end

--- Says out loud that every row is the intent, for the one case where it is.
function Query:all_rows()
  self._all_rows = true
  return self
end

--- Makes an INSERT idempotent without exposing a raw SQL suffix. Conflict
--- columns are identifiers and therefore checked with the same discipline as
--- every other client-selected identifier in this builder.
function Query:on_conflict_do_nothing(columns, allowed)
  if self._kind ~= "insert" then
    error("akkar.sql: on_conflict_do_nothing is only valid on inserts", 0)
  end
  if columns ~= nil then
    if type(columns) ~= "table" or #columns == 0 then
      error("akkar.sql: conflict columns must be a non-empty list", 0)
    end
    local checked = {}
    for index, column in ipairs(columns) do
      checked[index] = checked_identifier(column, allowed, "conflict column")
    end
    self._on_conflict = "(" .. table.concat(checked, ", ") .. ") do nothing"
  else
    self._on_conflict = "do nothing"
  end
  return self
end

--- Binds the query to one tenant.
---
--- On a read or a write with a where clause it adds `column = value` as a
--- condition; on an insert it sets the column on the row, overriding whatever
--- the client sent -- a body claiming another tenant's id must not be able to
--- write into it.
---
--- Marks the query as scoped, which is what `db:scope()` checks before it will
--- run anything at all.
function Query:scope(column, value, allowed)
  checked_identifier(column, allowed, "scope column")
  if value == nil then
    error("akkar.sql: scope value for '" .. column .. "' is nil", 0)
  end

  if self._kind == "insert" then
    for _, entry in ipairs(self._insert) do
      if entry.column == column then
        entry.value = value           -- the client does not get a say
        self._scoped = true
        return self
      end
    end
    self._insert[#self._insert + 1] = { column = column, value = value }
  else
    self._where[#self._where + 1] = column .. " = ?"
    self._values[#self._values + 1] = value
  end

  self._scoped = true
  return self
end

function Query:is_scoped()
  return self._scoped
end

--- Assembles the statement.  Returns (sql, value1, value2, ...) ready to hand
--- straight to `db:many`.
---
--- Numbering happens here, once, so fragments compose without anyone tracking
--- `$1` by hand -- which is the other half of why people give up and
--- concatenate.
function Query:build()
  if not self._from then error("akkar.sql: no table; call :from()", 0) end

  local parts, values = {}, {}

  if self._kind == "insert" then
    -- Sorted here rather than at construction, so an insert produces the same
    -- text whether or not the client happened to supply the scope column --
    -- one statement shape instead of two, which is what a plan cache wants.
    table.sort(self._insert, function(a, b) return a.column < b.column end)
    local columns, marks = {}, {}
    for i, column in ipairs(self._insert) do
      columns[i] = column.column
      marks[i] = "?"
      values[i] = column.value
    end
    if #columns == 0 then error("akkar.sql: insert with no columns", 0) end
    parts[#parts + 1] = "insert into " .. self._from
                     .. " (" .. table.concat(columns, ", ") .. ")"
                     .. " values (" .. table.concat(marks, ", ") .. ")"

  elseif self._kind == "update" then
    if #self._set == 0 then error("akkar.sql: update with no columns; call :set()", 0) end
    parts[#parts + 1] = "update " .. self._from
                     .. " set " .. table.concat(self._set, ", ")
    for i = 1, #self._set_values do values[i] = self._set_values[i] end

  elseif self._kind == "delete" then
    parts[#parts + 1] = "delete from " .. self._from

  else
    parts[#parts + 1] = "select " .. self._select .. " from " .. self._from
    for _, join in ipairs(self._joins) do
      parts[#parts + 1] = " " .. join.text
    end
  end

  -- An UPDATE or DELETE with no WHERE is the shape that empties a table.  It
  -- is legitimate in a migration and almost never legitimate in a handler, so
  -- it has to be asked for by name rather than reached by forgetting a line.
  if #self._where == 0 and (self._kind == "update" or self._kind == "delete")
     and not self._all_rows then
    error(("akkar.sql: %s with no where clause would affect every row; "
        .. "add a condition or call :all_rows() to say you meant it")
        :format(self._kind), 0)
  end

  if self._kind ~= "insert" then
    -- Join values before where values, because the TEXT is emitted in that
    -- order and `?` is numbered by position in the text.  Appending both to
    -- one list in call order is what bound a join's parameter to a condition.
    for i = 1, #self._join_values do values[#values + 1] = self._join_values[i] end
    for i = 1, #self._values do values[#values + 1] = self._values[i] end
    if #self._where > 0 then
      -- Each condition is parenthesised before it is joined.  Without this,
      -- a handler's own `or` silently captures everything appended after it:
      -- `where("a = ? or b = ?")` plus a tenant scope builds
      -- `a = $1 or b = $2 and tenant_id = $3`, and SQL binds `and` tighter than
      -- `or`, so the scope applies to one branch and the other returns every
      -- tenant's rows.  The scope is present in the text and absent from the
      -- meaning -- which is the one failure akkar.scope exists to make
      -- impossible.  Parenthesising is what makes appending a condition
      -- actually mean "and also this".
      local wrapped = {}
      for i = 1, #self._where do wrapped[i] = "(" .. self._where[i] .. ")" end
      parts[#parts + 1] = " where " .. table.concat(wrapped, " and ")
    end
  end
  if self._group then parts[#parts + 1] = " group by " .. self._group end
  if self._order then parts[#parts + 1] = " order by " .. self._order end

  if self._limit then
    parts[#parts + 1] = " limit ?"
    values[#values + 1] = self._limit
  end
  if self._offset then
    parts[#parts + 1] = " offset ?"
    values[#values + 1] = self._offset
  end
  if self._for_update then
    parts[#parts + 1] = self._skip_locked and " for update skip locked" or " for update"
  elseif self._skip_locked then
    -- Checked here rather than in `skip_locked` so the two calls can arrive in
    -- either order: a builder that rejected `skip_locked():for_update()` would
    -- be rejecting a query that is perfectly well formed by the time it runs.
    error("akkar.sql: skip_locked requires for_update", 0)
  end
  if self._on_conflict then parts[#parts + 1] = " on conflict " .. self._on_conflict end
  if self._returning then
    parts[#parts + 1] = " returning " .. self._returning
  end

  -- Replace each `?` with its position, left to right.
  local text = table.concat(parts)
  local index = 0
  text = text:gsub("%?", function()
    index = index + 1
    local raw, cast = typed_value(values[index])
    values[index] = raw
    return "$" .. index .. (cast and "::" .. cast or "")
  end)

  if index ~= #values then
    error(("akkar.sql: %d placeholder(s) but %d value(s) -- this is a bug in akkar.sql")
          :format(index, #values), 0)
  end

  return text, table.unpack(values)
end

--- The statement text alone, for tests and for logging.  The values are
--- deliberately not interpolated into it -- a log line showing the real values
--- spliced into SQL is how a "safe" query gets copied into an unsafe one.
function Query:to_string()
  return (self:build())
end

--- The bound values as a list, for assertions.
function Query:values()
  return { select(2, self:build()) }
end

M.Query = Query
return M
