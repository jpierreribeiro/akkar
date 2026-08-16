# Why a handler returns instead of writing a response

A handler in akkar is a function that takes a request and **returns a value**.
It is never handed a connection, a writer, or a response object to fill in.

```lua no-run
app:get("/users/:id", function(req)
  return req.db:one("select id, name from users where id = $1", req.params.id)
end)
```

Most frameworks do the other thing. In Gin you call `c.JSON(200, user)`. In
Express you call `res.json(user)`. In Flask you can do either. The object is
there, in your hand, for the whole handler, and you may call it as many times
as you like.

This page argues that handing you that object is a mistake, says what akkar
pays for refusing it, and names the cases where the refusal is genuinely worse.

## What it makes impossible

### Answering twice

If there is no `c.JSON()` there is no second `c.JSON()`. The bug where a
handler writes a 200, keeps going, hits an error path and writes a 500 into the
same connection cannot be expressed. Neither can its quieter sibling, the
`Abort()` without a `return` after it, where the framework marks the request
finished and the handler carries on running anyway.

This is not a rule that akkar checks. It is a shape. `akkar/init.lua` says it
in its own opening comment:

> Handlers RETURN a response instead of mutating a context, which makes
> writing the response twice structurally impossible.

The distinction matters because a checked rule has an error message and a
shaped API does not need one. There is nothing to warn about.

### An error deep in the stack that cannot answer

The usual price of "return the response" is that every function between the
handler and the failure has to carry the failure back up by hand:

```lua no-run
local user, err = find_user(db, id)
if err then return err end
```

akkar does not pay it. **The same value works as a return and as a raise.**
`docs/DECISIONS.md` section 4 records the alternatives that were on the table
and why this one won:

```lua
local akkar = require "akkar"
local app = akkar.new()

-- Three layers down, and it can still answer HTTP.
local function find_user(db, id)
  local user = db:one("select id, name from users where id = $1", id)
  if not user then error(akkar.not_found "no such user") end
  return user
end

app:get("/users/:id", function(req)
  return find_user(req.db, req.params.id)
end)

local client = app:test {
  db = require("akkar.db.memory").factory(function(fake)
    fake:on("from users", function(_, id)
      if id == "1" then return { id = 1, name = "ada" } end
    end)
  end),
}

print(client:get("/users/1").status)    --> 200
print(client:get("/users/99").status)   --> 404
```

akkar tells a thrown response from a real error, and only turns the second into
a 500. There is no traceback in the body either way.

### Middleware that cannot see the answer

Because a handler returns, `next` returns too. Middleware is an ordinary
function that can look at the response before it goes out:

```lua no-run
app:use(function(req, next)
  local res = next(req)
  log(req.method, req.path, res.status)
  return res
end)
```

In a framework where the handler writes, post-processing means wrapping or
replacing the writer, which is why response-modifying middleware is the part of
those frameworks people get wrong.

### A `BEGIN` nobody closed

`req.db:transaction(fn)` commits when the closure returns and rolls back on any
error, **including a response thrown from inside it**. That only works because
throwing a response is a normal error path. If a handler could write a 404 to
the connection and then return normally, the transaction would commit.

### Three more things that fall out of it

- **A `response` schema can be enforced.** akkar has the whole body in hand
  before anything is written, so it can filter out undeclared fields. A handler
  doing `select *` cannot leak `password_hash`, and a body that breaks its own
  declared contract is a 500, because that is the server's fault.
- **OpenAPI is derivable.** The schema used for validation is the schema in the
  document. Nothing describes itself twice.
- **Tenant scope stays enforceable**, because every read goes through a builder
  rather than through a string assembled next to a writer.

`docs/ROADMAP.md` makes the dependency explicit when it rejects server-rendered
HTML: the return shape "is what makes writing the response twice structurally
impossible, what makes OpenAPI derivable from the schemas, and what keeps
tenant scope enforceable". They are one decision, not three.

## What it costs

This is the half most pages like this one leave out.

### Streaming needs its own value, and it has three sharp edges

A 200 MB export does not fit in "return the body". akkar's answer keeps the
invariant by returning a value that *describes* a body produced on demand:

```lua no-run
return akkar.stream(function(write)
  write '{"rows":['
  for i, row in ipairs(rows) do
    if i > 1 then write "," end
    write(cjson.encode(row))
  end
  write ']}'
end)
```

The producer receives `write` and nothing else. No connection, no status, no
headers, so it still cannot answer twice. What was rejected was the obvious
alternative, handing the handler the stream object, because that would make
every other invariant conditional: one escape hatch undoes the guarantee for
all routes, not only the streaming ones.

The three costs are written into `akkar/init.lua` beside the function and into
`docs/DECISIONS.md` section 10:

1. **The status commits with the first byte.** A producer that raises after
   writing cannot become a 500. The 200 is already on the wire. akkar logs it
   and drops the connection without the terminating chunk, so the client sees a
   truncated response rather than a complete-looking lie. Validate before the
   first `write`.
2. **Capabilities outlive the handler.** A stream reading from `req.db` holds
   that connection until the last byte, because releasing it at return would
   hand a live cursor to the next request. A slow client therefore holds a pool
   slot for as long as it reads.
3. **The deadline covers the handler, not the body.** An export is meant to
   outlive a 30 second request budget.

None of that is free, and none of it is hidden.

### Control flow through exceptions

`error(akkar.not_found())` is an exception used for a non-exceptional outcome.
Some people dislike this on principle and they are not being unreasonable.
`docs/DECISIONS.md` records it as the one honest cost of choice B, and both
styles coexist: a shallow handler still writes `return`.

### It rules out a whole product

A template engine wants to stream into a response that is still being
assembled, which is exactly the mutation this design refuses. So akkar cannot
grow server-rendered HTML as a feature. `docs/ROADMAP.md` decided on
16 Aug 2026 that a server-rendered akkar "would not be akkar with more
features. It would be a different framework that happened to share the event
loop". If you want HTML, this is the wrong tool, and that is a decision rather
than a gap.

WebSocket is the same shape of problem. `docs/ROADMAP.md` Tier 4 lists it as
present in lua-http and still **"Not small"**, because a long-lived connection
outside the request and response model needs its own capability and its own
shutdown story.

### It does not stop you being wrong

The shape removes one class of bug. It does nothing about returning the wrong
status, the wrong body, or the right body for the wrong user. It is worth being
clear that "structurally impossible" applies to answering twice and to nothing
else.

## What to read next

- `docs/why/adapters.md`, because `req.db` in the examples above is the other
  half of the same decision.
- `docs/DECISIONS.md` sections 4 and 10, for the alternatives side by side.
- `docs/guide/04-errors.md`, if you want to be shown rather than argued at.
