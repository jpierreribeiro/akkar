# A typed client, generated from the routes

This directory is the smallest complete loop of akkar's typed contract: one
`app.lua` whose routes declare their schemas, and one `client.ts` generated
from them that a TypeScript frontend imports. A wrong field, a wrong type, a
missing required field or a typo'd key in a call is a `tsc` error before the
request is ever sent.

    akkar gen app.lua -o client.ts        # regenerate after a schema change
    akkar gen app.lua -o client.ts --check   # what CI runs: exit 1 on drift

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
