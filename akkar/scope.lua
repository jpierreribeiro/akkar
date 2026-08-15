--[[
akkar.scope — a database handle that cannot issue an unscoped query.

Cross-tenant leakage is the bug that closes a company, and nobody writes it
deliberately. It is one route out of two hundred where `and project_id = $2`
is missing, on a Thursday, in a hurry. Code review does not catch it reliably,
because the query looks exactly like the two hundred correct ones minus five
words.

So it is removed as a possibility rather than as a habit:

    local db = req.db:scope("project_id", req.user.project_id)
    return db:many(sql.select("*"):from "documents")

`db` here refuses raw SQL outright — a string cannot be scoped without
parsing it, and a SQL parser in the framework would be a second, worse
database — and applies the condition itself to every builder that passes
through. The unscoped statement is never assembled, so there is no window in
which it could be sent.

The escape hatch is real work, so it exists, but it is named at the call site:

    req.db:unscoped():many "select count(*) from documents"

which makes `grep -rn ':unscoped()'` the complete list of queries that cross
tenants. A short list someone can actually read is worth more than a rule
nobody can verify.

This lives at the contract level rather than inside `akkar.db`, so the
in-memory adapter scopes identically. A fake whose safety property differs
from the real one is how a test proves the wrong thing.
]]

local Scoped = {}
Scoped.__index = Scoped

local M = {}

local function scoped(self, query)
  if type(query) ~= "table" or not query.scope then
    error(("db: this handle is scoped to %s, so it takes an akkar.sql query "
        .. "rather than raw SQL -- a string cannot be scoped without parsing "
        .. "it. Use db:unscoped() if the query genuinely covers every tenant.")
        :format(self.column), 0)
  end
  return query:scope(self.column, self.value)
end

function Scoped:many(query) return self.db:many(scoped(self, query)) end
function Scoped:one(query)  return self.db:one(scoped(self, query)) end
function Scoped:exec(query) return self.db:exec(scoped(self, query)) end

--- The closure receives the scoped handle, not the connection, so nothing
--- inside a transaction can escape the scope by reaching past it.
function Scoped:transaction(fn)
  return self.db:transaction(function()
    return fn(self)
  end)
end

--- Scoping twice narrows rather than replaces: an organisation and a project
--- are both true at once, and dropping the outer one would widen the query.
function Scoped:scope(column, value)
  return M.wrap(self, column, value)
end

function Scoped:unscoped() return self.db end
function Scoped:release()  return self.db:release() end
function Scoped:close()    return self.db:close() end

function M.wrap(db, column, value)
  if value == nil then
    error("db: scope value for '" .. tostring(column) .. "' is nil; a missing "
       .. "tenant id has to fail here rather than quietly match every row", 0)
  end
  return setmetatable({ db = db, column = column, value = value }, Scoped)
end

M.Scoped = Scoped
return M
