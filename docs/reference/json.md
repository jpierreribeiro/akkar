# akkar.json

The serializer behind a contract. Everything in akkar that turns a Lua value
into JSON, or JSON text into a Lua value, goes through this module rather than
through a JSON library directly.

**When you need it.** When an empty list must encode as `[]` and not `{}`, when
a decoded JSON `null` has to be told apart from an absent key, or when you are
replacing the JSON library the whole process uses.

```lua no-run
local json = require "akkar.json"
```

The same values are re-exported from the top-level module: `akkar.json` is this
module, `akkar.null` is `json.null`, `akkar.array` is `json.array` and
`akkar.empty_array` is `json.empty_array`. Both spellings are the same value.

## Contents

- [json.array(value)](#jsonarrayvalue)
- [json.decode(text)](#jsondecodetext)
- [json.empty_array](#jsonempty_array)
- [json.encode(value)](#jsonencodevalue)
- [json.implementation()](#jsonimplementation)
- [json.null](#jsonnull)
- [json.use(replacement)](#jsonusereplacement)

## json.array(value)

Marks a table as a JSON array, so an **empty** one encodes as `[]` instead of
`{}`. Sets the current serializer's array metatable on `value` and returns the
same table. `value` may be omitted, in which case a new empty table is marked.

A table that already has elements encodes as an array without this, so the
marker only changes the empty case.

**Returns** the table it was given, with a metatable set on it.

**Raises** nothing.

```lua
local json = require "akkar.json"

local rows = {}
assert(json.encode({ tasks = rows })            == '{"tasks":{}}')
assert(json.encode({ tasks = json.array(rows) }) == '{"tasks":[]}')

-- Non-empty tables already encode as arrays.
assert(json.encode(json.array { 1, 2, 3 }) == "[1,2,3]")

-- Called with no argument it makes a fresh marked table.
assert(json.encode(json.array()) == "[]")
```

The marker lives on the table, so it does not survive an encode and decode
round trip: `json.decode('{"tasks":[]}').tasks` is an ordinary empty table and
re-encodes as `{}`.

## json.decode(text)

Turns JSON text into a Lua value by calling the current serializer's `decode`.

**Returns** the decoded value.

**Raises** whatever the serializer raises on malformed input. With the default
(`cjson`) that is an error whose message names the position.

```lua
local json = require "akkar.json"

local value = json.decode '{"id":1,"tags":["a","b"]}'
assert(value.id == 1)
assert(value.tags[2] == "b")

local ok = pcall(json.decode, "{not json}")
assert(ok == false)
```

## json.empty_array

An empty table already marked by `json.array`, ready to return from a handler.

It is built once, when the module loads. A serializer installed later with
`json.use` does not change it: it keeps the marker of whichever serializer was
current at load time.

```lua
local json = require "akkar.json"

assert(json.encode(json.empty_array) == "[]")
assert(json.encode({ tasks = json.empty_array }) == '{"tasks":[]}')
```

Do not insert into it. It is one shared table, so anything put in it is seen by
every caller. Use `json.array {}` for a table you intend to fill.

## json.encode(value)

Turns a Lua value into JSON text by calling the current serializer's `encode`.

**Returns** a string.

**Raises** whatever the serializer raises. With the default that includes a
value it cannot represent, such as a function, and a table with both array and
object keys.

```lua
local json = require "akkar.json"

assert(json.encode { ok = true } == '{"ok":true}')
assert(json.encode { 1, 2 } == "[1,2]")

local ok = pcall(json.encode, { f = print })
assert(ok == false)
```

Key order in an encoded object is not defined and is not stable between
processes. Do not compare two encodings of the same table for equality.

## json.implementation()

Returns the serializer currently installed. It exists for the one caller that
legitimately needs it: a test asserting which serializer is in place.

**Returns** the serializer table.

**Raises** nothing.

```lua no-run
local json = require "akkar.json"
assert(json.implementation() == require "cjson")
```

## json.null

The value a decoded JSON `null` becomes. With the default serializer it is
cjson's null sentinel, a userdata.

`nil` is not available for this, because a `nil` field cannot be told apart
from an absent key, and that is the difference between "set this field to null"
and "do not touch this field". Compare by identity.

`json.use` re-points `json.null` at the new serializer's sentinel. `akkar.null`
is captured once when `akkar` loads and is **not** re-pointed, so a swap after
that leaves the two spellings holding different values. Swap at boot, before
anything holds either.

```lua
local json = require "akkar.json"

local body = json.decode '{"nickname":null}'
assert(body.nickname == json.null)      -- present, and explicitly null
assert(body.missing  == nil)            -- absent

assert(json.encode { nickname = json.null } == '{"nickname":null}')
```

## json.use(replacement)

Installs a serializer for the whole process. Boot time only, before `app:run`.

`replacement` must answer `encode` and `decode` as functions and must declare
`null`. Nothing else is checked.

| field | type | default | meaning |
|---|---|---|---|
| `encode` | function | required | `encode(value)` returns JSON text |
| `decode` | function | required | `decode(text)` returns a Lua value |
| `null` | any non-nil | required | the value a decoded JSON null becomes |
| `array_mt` | table | not checked | the metatable `json.array` sets; see below |

**Returns** the previous serializer, so a caller can put it back.

**Raises**

- when `encode` is not a function:
  `akkar.json: a serializer must answer :encode`
- when `decode` is not a function:
  `akkar.json: a serializer must answer :decode`
- when `null` is nil:
  `akkar.json: a serializer must declare ...`, the full text naming `null` as
  the value a decoded JSON null becomes and saying nil is not available for it

```lua
local json = require "akkar.json"

-- Capture the current one FIRST. Reading it back inside the replacement's
-- own `encode` would call the replacement, which never terminates.
local inner = json.implementation()

local counted = 0
local previous = json.use {
  encode   = function(value) counted = counted + 1 return inner.encode(value) end,
  decode   = inner.decode,
  null     = inner.null,
  array_mt = inner.array_mt,
}

assert(json.encode { ok = true } == '{"ok":true}')
assert(counted == 1)

json.use(previous)
assert(json.implementation() == previous)
```

`array_mt` is not validated, and `json.array` reads it. A serializer installed
without one makes `json.array` a no-op: `setmetatable(t, nil)` succeeds, and an
empty marked table goes back to encoding as `{}` with no error anywhere. Carry
`array_mt` on any replacement.

## Not here

- **A translation of null sentinels on the way in.** Walking every decoded body
  to replace nulls was measured at 1.47x of a request and removed. The sentinel
  is in the contract instead.
- **A pretty printer, a streaming parser, or a schema.** Request validation is
  `app:post(path, options, handler)` in [akkar](akkar.md).
- **Per-request or per-app serializers.** `json.use` is process-wide.

## See also

- [akkar](akkar.md) for `akkar.null`, `akkar.array` and `akkar.empty_array`,
  which are these values under their top-level names
- [akkar.idempotency](idempotency.md), which stores a response by encoding it
  and replays it by decoding it, so a replayed body is the JSON round trip of
  the original
- the module source, `akkar/json.lua`, for why the sentinel is in the contract
  rather than behind it
