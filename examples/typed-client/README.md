# A typed client, generated from the routes

This directory is the smallest complete loop of akkar's typed contract: one
`app.lua` whose routes declare their schemas, and three clients generated
from them -- `client.ts` for a TypeScript frontend, `client.tl` for a Teal (or
`tl gen`-compiled plain Lua) caller, and `client.d.lua`, a LuaLS meta file
that types that same client for the editor. A wrong field, a wrong type or a
typo'd key in a call is a type error before the request is ever sent.

    akkar gen app.lua --lang ts    -o client.ts       # regenerate after a schema change
    akkar gen app.lua --lang teal  -o client.tl
    akkar gen app.lua --lang luals -o client.d.lua
    akkar gen app.lua --lang ts    -o client.ts --check   # what CI runs, for each: exit 1 on drift

## What the loop is, honestly

tRPC gets this for a TypeScript monorepo with **no codegen**, by letting the
TypeScript compiler infer the client's types from the server's. PUC-Lua has no
shared type to infer from, so akkar **generates** the artifact instead. The
outcome for the person writing the call is the same -- a red squiggle before
runtime -- and two things are different, both of which the generated file says
in its header:

1. **There is a regen step.** `client.ts` is only as current as the last
   `akkar gen`. A schema change nobody regenerated type-checks green against a
   stale contract. `--check` in CI turns that into a failed build; it is a
   process guarantee, not a compiler property.
2. **Value constraints do not cross.** TypeScript has no integer or range
   types, so `amount: -3` type-checks and only the server's 422 refuses it.
   Every such constraint is listed in a comment above the route's types.

Everything is derived from one source: the route table. `akkar.openapi` turns
it into the OpenAPI 3.1 document the server serves at `/openapi.json`; `akkar
gen` reads that document; the runtime validator reads the same tables. They
cannot disagree.

## Using it

```ts
import { postTransfers, getUsers, AkkarError } from "./client";

const created = await postTransfers({ body: { to: "acct_9", amount: 5 } });
created.status;                       // string -- typed from `responses[201]`

const page = await getUsers({ query: { limit: 20 } });
page.users[0].name;                   // typed from `response`

try {
  await postTransfers({ body: { to: "", amount: 5 } });
} catch (e) {
  if (e instanceof AkkarError && e.body.error === "validation failed") {
    e.body.fields["body.to"];         // the reason, by the validator's own path
  }
}
```

Errors are typed too. Every non-2xx response the document declares for a
route -- the 422 and 500 akkar itself produces, plus any `responses[4xx]` the
route adds -- becomes a member of that route's `...Error` union, thrown as an
`AkkarError` carrying the status and the parsed body. Narrowing on `error`
gives you `fields` on the 422 and nothing on the 500, which is exactly what the
server sends.

## From Lua

The other caller of an akkar API is another Lua program, and Lua has two ways
to get static checking today. Both projections read the same document, and
each says in its header what its checker will and will not catch.

**Teal** (`client.tl`): one `record` per declared shape, an `enum` per
`one_of`, and a typed method per route on a `Client`. It speaks HTTP through
the `transport` you hand `new` -- a function from a request to `(status,
decoded body)` -- so it depends on no HTTP library and runs unchanged over a
socket or over `app:test()`. `tl gen client.tl` turns it into plain Lua.

```lua
local client = require("client")
local c = client.new({ transport = my_transport })

local created, err = c:post_transfers({ body = { to = "acct_9", amount = 5 } })
if err and err.body.error == "validation failed" then
  err.body.fields["body.amount"]      -- string: the validator's own reason
end
created.status                        -- string, from `responses[201]`
```

`tl check` rejects a wrong type, a field the route does not declare, a literal
outside an enum, and a non-integer in an `integer` field -- Teal has integers
where TypeScript does not. What it does **not** catch on its own is a
**missing required field**: every Teal record field admits nil. To have the
compiler demand every field, declare the value `<total>`:

```lua
local body <total>: client.PostTransfersBody = { to = "acct_9", amount = 5, memo = nil }
```

The records are also what a Teal handler casts `req.body` to -- the file types
both ends of one route -- and it declares no `Request` or `App`; those live in
akkar's own `types/akkar.d.tl`.

**LuaLS** (`client.d.lua`): a `---@meta` file of `---@class`/`---@field`
annotations and stub signatures for that same client, for a caller who writes
plain Lua and wants the editor's red squiggle with no dialect and no runtime.
The file is inert -- loading it defines nothing but empty functions -- and the
`.d.lua` extension is one the Lua VM never loads. LuaLS reports a wrong type,
a **missing required field** (`missing-fields`) and a read of an undeclared
field (`undefined-field`); it does **not** report an extra field in a table
literal, because it has no excess-property check. Between them the two Lua
checkers cover what `tsc` covers alone; neither covers it all.

Value constraints (`min`, `max`, length, pattern) cross into none of the three
-- they are listed per route in a comment and enforced by the server's 422.

## From any OpenAPI toolchain instead

`akkar gen` is a first-party generator so the loop needs nothing but Lua. The
same `/openapi.json` also feeds any generator that reads OpenAPI 3.1 -- for a
frontend already on `openapi-typescript` and `openapi-fetch`:

    npx openapi-typescript http://localhost:8080/openapi.json -o api.d.ts

```ts
import createClient from "openapi-fetch";
import type { paths } from "./api";
const api = createClient<paths>({ baseUrl: "http://localhost:8080" });
await api.POST("/transfers", { body: { to: "acct_9", amount: 5 } });
```

Same contract, same drift rule: regenerate when the routes change, and gate it
in CI.
