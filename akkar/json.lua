--[[
akkar.json — the serializer, behind a contract like everything else.

## The boundary this closes

akkar's rule is that the public API never depends on the implementation of
the substrate: `app:get`, `req.db` and `akkar.stream` are akkar, while
cqueues, lua-http, pgmoon and cjson are replaceable details. Serialization was
the one capability with no contract and no adapter, and it leaked in two
measured ways.

`cjson` was required DIRECTLY by five modules -- `log`, `work`, `jobs`,
`idempotency` and `etag` -- none of which has any business knowing which JSON
library is installed.

And `akkar.null` re-exported cjson's C sentinel as akkar's own public API,
compared by IDENTITY in dispatch. A value users hold, whose identity belongs
to a dependency.

## What a serializer must answer

    json.encode(value)   -> string, or raises
    json.decode(text)    -> value, or raises
    json.null            -> the sentinel a decoded JSON null becomes

The third is the interesting one, and it is in the contract rather than
hidden behind it, deliberately. A JSON null has to become SOMETHING in a Lua
table, and `nil` is not available -- it would be indistinguishable from an
absent key, which is the difference between "set this field to null" and "do
not touch this field". So every serializer has a sentinel, and akkar's answer
is that the sentinel belongs to the contract: swap the serializer and
`akkar.null` is that serializer's null, by definition rather than by accident.

The alternative was translating sentinels on the way in, and that is not
available either: walking every decoded body to replace nulls was measured at
**1.47x** of a request and removed for it. A contract that costs half a
request is not a contract, it is a tax.

## Swapping it

    akkar.json.use(require "my.json")     -- at boot, before app:run

Boot time only. The sentinel is captured by `akkar.null` when akkar loads, so
a swap after that would leave two identities in play -- exactly the bug this
module exists to prevent.
]]

local M = {}

local impl = require "cjson"

--- Installs a serializer. Returns the previous one.
function M.use(replacement)
  for _, method in ipairs { "encode", "decode" } do
    if type(replacement[method]) ~= "function" then
      error("akkar.json: a serializer must answer :" .. method, 2)
    end
  end
  if replacement.null == nil then
    error("akkar.json: a serializer must declare `null`, the value a decoded " ..
          "JSON null becomes -- nil is not available, because it cannot be " ..
          "told apart from an absent key", 2)
  end
  local previous = impl
  impl = replacement
  M.null = impl.null
  return previous
end

function M.encode(value) return impl.encode(value) end
function M.decode(text)  return impl.decode(text)  end

--- The current serializer, for the one place that legitimately needs it: a
--- test asserting which one is installed.
function M.implementation() return impl end

M.null = impl.null


--- Marks a table as a JSON ARRAY, so an empty one encodes as `[]` and not `{}`.
---
--- THE AMBIGUITY IS LUA'S AND SOMEBODY HAS TO RESOLVE IT. An empty Lua table
--- is both an empty list and an empty object, and every JSON encoder has to
--- guess. cjson guesses `{}`, so a handler returning `{ tasks = rows }` with
--- no rows answered `{"tasks":{}}` -- and a frontend doing `tasks.map(...)`
--- gets a TypeError on a response that looked fine to whoever wrote it.
---
--- Found by someone writing the guide's frontend page, who could not paste an
--- honest example: the browser code they were teaching would have crashed on
--- an empty list, and there was no way at akkar's level to say "array".
---
--- Only the EMPTY case is ambiguous -- a table with elements encodes as an
--- array already -- so this costs nothing on the path that has data, which is
--- why it is a marker rather than a walk over every response.
function M.array(value)
  return setmetatable(value or {}, impl.array_mt)
end

--- An empty array, ready to return.
M.empty_array = M.array {}

return M
