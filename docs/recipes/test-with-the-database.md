# Test something that hits the database

Runs your routes against a real Postgres, with the rows cleaned up between
one test and the next.

You need busted, and the database from
[page 5](../guide/05-a-database.md) of the guide. The table this uses is the
one from [Run migrations on deploy](run-migrations-on-deploy.md):

```sql
create table notes (
  id      serial primary key,
  body    text not null,
  created timestamptz not null default now()
)
```

## The application

`notes.lua`:

```lua
local akkar = require "akkar"
local db    = require "akkar.db"
local v     = akkar.v

local app = akkar.new()

app:get("/notes", function(req)
  return { notes = akkar.array(req.db:many "select id, body from notes order by id") }
end)

app:post("/notes", { body = { body = v.string { min = 1 } } }, function(req)
  return akkar.created(req.db:one(
    "insert into notes (body) values ($1) returning id, body", req.body.body))
end)

if ... == nil then
  app:run {
    port = 3000,
    db = db.connect {
      host = "127.0.0.1", port = 55432, database = "akkar",
      user = "postgres", password = "akkar",
      statement_timeout = 5,
    },
  }
end

return app
```

## The spec

`spec/notes_spec.lua`. Marked `no-run` because busted runs it, not `lua5.4`.

```lua no-run
local db  = require "akkar.db"
local app = require "notes"

local SETTINGS = {
  host = "127.0.0.1", port = 55432, database = "akkar",
  user = "postgres", password = "akkar",
  statement_timeout = 5,
}

describe("the notes API", function()
  -- The test client takes its own database, so the spec decides what the
  -- routes talk to and the file under test is not edited for testing.
  local client = app:test { db = db.connect(SETTINGS) }

  -- One connection of the spec's own, for arranging rows and checking them.
  local admin

  setup(function()
    local one_off = {}
    for key, value in pairs(SETTINGS) do one_off[key] = value end
    one_off.pool_size = 0
    admin = db.connect(one_off)()
  end)

  teardown(function() admin:close() end)

  before_each(function() admin:exec "delete from notes" end)

  it("stores what was posted", function()
    local res = client:post("/notes", { body = { body = "buy milk" } })
    assert.equal(201, res.status)

    local row = admin:one "select body from notes order by id"
    assert.equal("buy milk", row.body)
  end)

  it("lists what is already there", function()
    admin:exec("insert into notes (body) values ($1)", "read the guide")

    local res = client:get "/notes"
    assert.equal(200, res.status)
    assert.equal(1, #res.body.notes)
    assert.equal("read the guide", res.body.notes[1].body)
  end)

  it("writes nothing when the body is refused", function()
    local res = client:post("/notes", { body = { body = "" } })
    assert.equal(422, res.status)
    assert.equal(0, admin:one("select count(*)::int as n from notes").n)
  end)
end)
```

## Try it

```sh
busted spec/notes_spec.lua
```

```
+++
3 successes / 0 failures / 0 errors / 0 pending : 0.15714 seconds
```

## Why cleaning between tests and not one transaction around them

Wrapping each test in a transaction and rolling it back is the usual trick,
and it does not work here: akkar takes a connection from the pool per request
and gives it back afterwards, so the request is not inside the transaction
your spec opened on a different connection. Deleting the rows in
`before_each` is what is left, and it is honest about what it costs, which is
one statement per test. Give the spec's own connection `pool_size = 0` so it
is one connection and not a second pool competing with the client's. If a
test does not need a database at all, do not give it one:
`app:test { db = require("akkar.db.memory").factory(function(fake)
fake:on("select id, body from notes", { id = 1, body = "buy milk" }) end) }`
answers programmed rows and raises on any query nobody planned for.
