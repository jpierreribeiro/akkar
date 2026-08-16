# 7. Accounts

By the end of this page your application will have accounts. Someone can sign
up, log in, ask who they are, and log out. Passwords will be stored in a form
that is useless to a thief.

The tasks are still shared by everybody after this page. Making a task belong
to one person is [page 8](08-only-your-own.md). This page is about knowing who
is asking.

You need the database from [page 5](05-a-database.md) and the application from
[page 6](06-storing-and-reading.md).

## Never store the password

An account is an email, a password, and a way to prove later that the same
person came back.

The first rule is the one that matters: **the password is never stored.** Not
encrypted, not hidden, not in a column called `secret`. Databases leak. They
leak through a backup left on a laptop, an old copy nobody deleted, a mistake
in one query. When yours leaks, the people in it must not lose anything except
your service, and most of them used that password somewhere else too.

What you store instead is a **hash**: the output of a one way function. You can
go from password to hash, and there is no way back. When somebody logs in, you
hash what they typed and compare the two hashes.

### Why not write it yourself

Hashing looks easy. A hash function is one call. It is the details around it
that decide whether the result is worth anything, and every one of those
details is invisible when you get it wrong. Nothing crashes. The tests pass.
The login page works.

Three of them, so that "do not invent this" is a reason instead of an order:

**A fast hash is not enough.** SHA-256 is built to be fast, and a graphics card
runs billions of them a second. Against a leaked table, that means guessing
every common password for every user in an afternoon. A password hash has to be
built to be slow.

**Two people with the same password must not get the same hash.** Otherwise one
look at the table tells you which accounts share a password, and cracking one
cracks all of them. The fix is a **salt**: random bytes, different for every
password, stored next to the hash.

**Comparing with `==` leaks the answer.** String comparison stops at the first
byte that differs, so a wrong guess that shares the first ten characters takes
measurably longer to reject. Over enough tries that difference tells an
attacker the secret one byte at a time.

`akkar.crypto` has all three handled. Use it.

### What it looks like

Create `hash.lua` in the `akkar` folder. This is the whole file.

```lua
local crypto = require "akkar.crypto"

local started = os.clock()
local hash = crypto.hash_password "correct horse battery staple"
print(hash)
print(("hashing took %.0f ms"):format((os.clock() - started) * 1000))

print("right password:", crypto.verify_password("correct horse battery staple", hash))
print("wrong password:", crypto.verify_password("hunter2", hash))
```

```sh
lua5.4 hash.lua
```

```
pbkdf2-sha256$600000$895ddfacd6bf6ab42c9a3f6842d4b4c5$37652a68a1d6f67c4d1e3f6cbb4a33a6a007d1d281ebc9fe3ba6a457162ebb19
hashing took 771 ms
right password:	true	false
wrong password:	false	false
```

Run it twice and the hash is different both times, even though the password is
the same. That is the salt doing its job.

That one line is four fields joined by `$`:

| Field | Is |
|---|---|
| `pbkdf2-sha256` | which algorithm made it |
| `600000` | how many times it was repeated, to make it slow |
| `c999f3...` | the salt, random, different every time |
| `b3f207...` | the hash itself |

The whole thing goes in one `text` column. It describes itself, so the day you
decide 600,000 rounds is not enough any more, old hashes keep working and get
upgraded as people log in.

`verify_password` gives back **two** values. The first is what you want: did the
password match. The second says whether that hash was made with fewer rounds
than today's setting, which is how the upgrade above happens. `if
crypto.verify_password(...)` reads the first one and ignores the second, which
is what this guide does.

## It is slow on purpose, and that is your problem to plan for

Those 600,000 rounds are not an accident. Slow is the defence. Look again at
the line `hash.lua` printed:

```
hashing took 771 ms
```

Three quarters of a second, and checking a password at login costs the same,
because it does the same work. Now remember what akkar is: **one process, one
core, one thing at a time.** While that hash runs, your server is not answering
anybody. Not slowly. Not at all.

You can watch it happen once the application at the bottom of this page is
running. Come back and try it then. One request signs up, and a second request
that does nothing at all is sent a tenth of a second later:

```sh
curl -s -o /dev/null -X POST http://127.0.0.1:3000/accounts \
  -H "content-type: application/json" \
  -d '{"email":"grace@example.com","password":"correct horse battery"}' &
sleep 0.1
curl -s -o /dev/null -w "logout answered in %{time_total}s\n" \
  -X POST http://127.0.0.1:3000/logout
```

```
logout answered in 0.694522s
```

The same request against a server with nothing else to do:

```
logout on an idle server: 0.001002s
```

Seven hundred times slower, and the second request did no work whatsoever. It
was simply waiting for its turn.

**This is what `akkar.work` is for**, and it is worth reading its own
documentation before you need it. It takes work that would hold the process and
breaks it into pieces, giving other requests a turn in between.

It cannot break up this one, and the module says so itself. Splitting a job
into pieces needs somewhere to split it, and the hashing is a single call down
into C that does not come back until it is finished. akkar's watchdog, which
normally warns you about exactly this, does not even see it: the watchdog
counts Lua instructions, and no Lua instructions run in there.

So the honest options are these, and none of them is a helper you can import:

- **Accept it.** Signing up and logging in are rare compared to everything else
  your service does. For a small application this is a real answer.
- **Run several processes.** With four processes, one blocked worker is a
  quarter of your capacity instead of all of it. Page 12 gets there.
- **Move it out of the request.** Hand the work to a background job and answer
  the caller straight away, which changes what your endpoint promises. Page 10
  covers jobs.

Saying that plainly is more use than a function that pretends the cost is gone.

## Two ways to remember somebody: sessions and tokens

The password proves who they are once. Then the browser makes a hundred more
requests and each one arrives knowing nothing. Something has to carry the
answer forward.

There are two shapes, and the difference is one sentence long.

**A token carries the answer with it.** The server signs a small piece of data
saying "this is account 1, valid until Friday" and hands it over. Every later
request brings it back, the server checks the signature, and that is all. The
server keeps nothing.

**A session keeps the answer on the server.** The server stores "this is
account 1" under a random id, and hands over only the id. Every later request
brings the id back, and the server looks it up.

They look similar, and then somebody has to be logged out.

**A session can be revoked. A token cannot.** Deleting the session is one
delete: the id still exists, and it now points at nothing. A token stays valid
until it expires, because everything it needs is inside it and the server has
nothing to delete. There is no such thing as taking one back. That matters on
the day it matters most: a stolen laptop, a shared machine, a password change,
an account you have to shut down now.

akkar does sessions, and keeps the id in a cookie. Cookies get one more thing
right that is easy to miss: a cookie marked `HttpOnly` cannot be read by
JavaScript at all, so a script that manages to run on your page cannot steal
it. A token kept in `localStorage` can be read by any script on the page.

## The session needs somewhere to put the state

The server has to keep "session abc belongs to account 1" somewhere. akkar
calls that place the **cache**, and it is a separate capability just like the
database:

```lua no-run
local memory = require "akkar.cache.memory"

app:run { port = 3000, db = open, cache = memory.factory() }
```

`akkar.cache.memory` is a real cache that lives in the memory of this process.
Nothing to install. Two consequences worth knowing before they surprise you:

- **Restart the server and everybody is logged out**, because the memory went
  with the process. In development that is fine. It is also why a page you just
  restarted answers `log in first` until you log in again.
- **It belongs to one process.** Run two copies of your server and they have
  two separate sets of sessions. Redis is the answer when that day comes, and
  it is a one line change, because `cache` is a capability.

Forget the cache entirely and the first request that touches a session says so:

```
ERROR middleware raised detail=...akkar/session.lua:106: req.cache is not configured; pass cache = ... to app:run{} request_id=d722f1e1000001
```

## Middleware, which is new here

So far every route has been one function. **Middleware is a function that runs
around your handlers**, before and after, for every request.

```lua no-run
app:use(function(req, next)
  -- anything here happens before the handler
  local res = next(req)
  -- anything here happens after it, and `res` is the response
  return res
end)
```

`next(req)` means "carry on", and what it gives back is the response the
handler produced. Not calling `next` at all is how middleware refuses a request
outright.

Two pieces of middleware appear on this page.

**`auth.middleware { ... }`** runs on every request. It opens the session,
reads who is logged in, and puts them on `req.auth`. With `optional = true` a
request with no session is allowed through with `req.auth` left as `nil`, which
is what you want when `/login` itself is a route.

**`require_login`** is four lines you write, attached to one route with
`before`, so that route refuses anybody without an account:

```lua no-run
local function require_login(req, next)
  if not req.auth then
    return akkar.unauthorized "log in first"
  end
  return next(req)
end

app:get("/me", { before = { require_login } }, function(req)
  return { id = req.auth.user_id }
end)
```

`before` takes a list, and they run in order, before the handler.

## The whole application

Here it is, with the new parts sitting alongside what you already had. This is
`app.lua`.

The `002_create_accounts.sql` migration is applied at startup, the way a real
deployment does it: bring the schema forward, then start serving. It only names
the migration this page introduces. `001` is already in your ledger from
[page 5](05-a-database.md).

```lua
local akkar   = require "akkar"
local db      = require "akkar.db"
local migrate = require "akkar.migrate"
local crypto  = require "akkar.crypto"
local session = require "akkar.session"
local auth    = require "akkar.auth"
local memory  = require "akkar.cache.memory"
local v       = akkar.v

local open = db.connect {
  host     = "127.0.0.1",
  port     = 55432,
  database = "akkar",
  user     = "postgres",
  password = "akkar",
  statement_timeout = 30,
}

local conn = open()
local runner = migrate.new(conn, {
  files = {
    { name = "002_create_accounts.sql", sql = [[
      create table accounts (
        id            serial primary key,
        email         text not null unique,
        password_hash text not null
      )
    ]] },
  },
})
for _, name in ipairs(runner:apply()) do print("applied " .. name) end
conn:release()

local sessions = session.new {
  secret = os.getenv "SESSION_SECRET" or crypto.token(32),
}

local app = akkar.new()

app:use(auth.middleware { sessions = sessions, optional = true })

local function require_login(req, next)
  if not req.auth then
    return akkar.unauthorized "log in first"
  end
  return next(req)
end

app:post("/accounts", {
  body = {
    email    = v.string { min = 3, max = 200, match = "^[^@]+@[^@]+$" },
    password = v.string { min = 8, max = 200 },
  },
}, function(req)
  local hash = crypto.hash_password(req.body.password)
  local account = req.db:one(
    "insert into accounts (email, password_hash) values ($1, $2) " ..
    "on conflict (email) do nothing returning id, email",
    req.body.email, hash)

  if not account then
    return akkar.conflict "that email already has an account"
  end
  return akkar.created(account)
end)

app:post("/login", {
  body = { email = "string", password = "string" },
}, function(req)
  local account = req.db:one(
    "select id, email, password_hash from accounts where email = $1",
    req.body.email)

  if not account or not crypto.verify_password(req.body.password,
                                               account.password_hash) then
    return akkar.unauthorized "wrong email or password"
  end

  auth.login(req, account.id)
  return { logged_in_as = account.email }
end)

app:get("/me", { before = { require_login } }, function(req)
  return req.db:one("select id, email from accounts where id = $1",
                    req.auth.user_id)
end)

app:post("/logout", function(req)
  auth.logout(req)
  return { logged_out = true }
end)

app:run { port = 3000, db = open, cache = memory.factory() }
```

```sh
lua5.4 app.lua
```

```
applied 002_create_accounts.sql
INFO  listening url=http://127.0.0.1:3000
```

### Six things in that file worth a sentence each

**`email text not null unique`.** `unique` is the database refusing two rows
with the same email, whatever your code does. Rules you can enforce down there
are rules that cannot be got around by a second request arriving at the same
moment.

**`on conflict (email) do nothing returning id, email`.** If that email exists,
insert nothing and return nothing, so `account` is `nil` and the handler answers
`409 Conflict`. One statement, no separate "does this exist" query, no gap
between checking and inserting.

**The insert never selects `password_hash` back.** Only the columns you name in
`returning` come back, so the hash cannot end up in a response by accident.

**`secret = os.getenv "SESSION_SECRET" or crypto.token(32)`.** The secret signs
the cookie. In development you get a fresh random one at every start, which
logs everybody out when you restart. In production you set `SESSION_SECRET` in
the environment and keep it out of your source, which page 12 covers.

**`auth.login(req, account.id)`** does two things: it throws away the old
session id and issues a new one, then records the account. The first half
matters. If somebody can plant a cookie in your browser before you log in, and
the id does not change when you do, they are now logged in as you. Rotating at
that exact moment is the fix, and making it one call is how it stops being
forgotten.

**`req.auth.user_id`** is where akkar puts the logged in account. The name is
akkar's, not yours: `auth.login` stores what you give it under `user_id`, so
that is the field every later page reads.

## Try it

**Sign up:**

```sh
curl -s -i -X POST http://127.0.0.1:3000/accounts \
  -H "content-type: application/json" \
  -d '{"email":"ada@example.com","password":"correct horse battery"}'
```

```
HTTP/1.1 201 Created
x-request-id: 7aab4f95000001
content-type: application/json
content-length: 34

{"email":"ada@example.com","id":1}
```

**A password that is too short never reaches your handler:**

```sh
curl -s -i -X POST http://127.0.0.1:3000/accounts \
  -H "content-type: application/json" \
  -d '{"email":"grace@example.com","password":"secret"}'
```

```
HTTP/1.1 422 Unprocessable Entity
x-request-id: 7aab4f95000002
content-type: application/json
content-length: 71

{"fields":{"body.password":"min length 8"},"error":"validation failed"}
```

**The same email twice:**

```sh
curl -s -i -X POST http://127.0.0.1:3000/accounts \
  -H "content-type: application/json" \
  -d '{"email":"ada@example.com","password":"correct horse battery"}'
```

```
HTTP/1.1 409 Conflict
x-request-id: 7aab4f95000003
content-type: application/json
content-length: 45

{"error":"that email already has an account"}
```

**Log in.** `-c jar.txt` tells curl to write the cookies it receives into a
file, which is what your browser does for you:

```sh
curl -s -i -X POST http://127.0.0.1:3000/login \
  -H "content-type: application/json" \
  -d '{"email":"ada@example.com","password":"correct horse battery"}' \
  -c jar.txt
```

```
HTTP/1.1 200 OK
set-cookie: akkar_session=88d1af7f017fd7fe8021af725e13e0b88beaab810563b7ce08ed2241538a13f4.95ef24bc5fda77d19bc8f25a858c35b34507636e28c0bac37a5ca7a81b3ac2c6; Path=/; Max-Age=1209600; HttpOnly; Secure; SameSite=Lax
x-request-id: 7aab4f95000004
content-type: application/json
content-length: 34

{"logged_in_as":"ada@example.com"}
```

That header is the whole session mechanism, so it is worth reading once:

| Part | Means |
|---|---|
| `akkar_session=<id>.<signature>` | a random id, and proof akkar issued it |
| `Max-Age=1209600` | keep it for two weeks |
| `HttpOnly` | JavaScript on the page cannot read it |
| `Secure` | only send it over https (browsers allow localhost) |
| `SameSite=Lax` | do not send it on requests started by another site |

The id means nothing by itself. It is a long random number, and the account it
belongs to is on the server. The signature after the dot is there so that a
made up cookie is thrown away immediately, instead of costing a lookup.

**Now use it.** `-b jar.txt` sends the cookies back:

```sh
curl -s -i http://127.0.0.1:3000/me -b jar.txt
```

```
HTTP/1.1 200 OK
x-request-id: 7aab4f95000005
content-type: application/json
content-length: 34

{"email":"ada@example.com","id":1}
```

**Without the cookie, the same route refuses:**

```sh
curl -s -i http://127.0.0.1:3000/me
```

```
HTTP/1.1 401 Unauthorized
x-request-id: 7aab4f95000006
content-type: application/json
content-length: 24

{"error":"log in first"}
```

`401` means "I do not know who you are". Compare it with `403 Forbidden`, which
means "I know who you are and you still may not". You will want the second one
on page 8.

**A wrong password:**

```sh
curl -s -i -X POST http://127.0.0.1:3000/login \
  -H "content-type: application/json" \
  -d '{"email":"ada@example.com","password":"hunter2"}'
```

```
HTTP/1.1 401 Unauthorized
x-request-id: 7aab4f95000007
content-type: application/json
content-length: 35

{"error":"wrong email or password"}
```

The message says "email or password" and not which one. An error that says "no
such account" tells a stranger which of your addresses are real, and that list
has value to them.

## Logging out really logs out

This is the difference between a session and a token, shown rather than
claimed.

```sh
curl -s -i -X POST http://127.0.0.1:3000/logout -b jar.txt
```

```
HTTP/1.1 200 OK
set-cookie: akkar_session=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax
x-request-id: 7aab4f95000008
content-type: application/json
content-length: 19

{"logged_out":true}
```

`Max-Age=0` tells the browser to throw the cookie away. But that half only
covers a browser that cooperates. The half that matters is that akkar also
deleted the session from the cache on the server.

So send the **old cookie value again**, exactly as a thief would:

```sh
curl -s -i http://127.0.0.1:3000/me -b jar.txt
```

```
HTTP/1.1 401 Unauthorized
x-request-id: 7aab4f95000009
content-type: application/json
content-length: 24

{"error":"log in first"}
```

The cookie is still a perfectly formed, correctly signed cookie. It points at a
session that no longer exists, so it is worth nothing. **With a signed token
carrying its own claims, that same request would still work**, until the day it
expired, and there would be no server side thing to delete.

## What is in the table now

```sh
docker exec akkar-pg psql -U postgres -d akkar -c 'select id, email, password_hash from accounts'
```

```
 id |      email      |                                                     password_hash                                                      
----+-----------------+------------------------------------------------------------------------------------------------------------------------
  1 | ada@example.com | pbkdf2-sha256$600000$72e852161d577a79879440dfb338b12b$047260a3ba8270a732d2ef0f8b8b9b1e082735ebc647cba437f548f0148b3a5e
(1 row)
```

Take that row, hand it to a stranger, and they still cannot log in as Ada. That
is the whole job of this page.

## Checkpoint

You have this if:

- signing up returns `201` and puts a `pbkdf2-sha256$...` string in the table
- logging in returns a `set-cookie` header and `/me` then works with `-b jar.txt`
- `/me` without the cookie returns `401`
- after `/logout`, the same cookie no longer works

And you can say the difference between a session and a token in one sentence: a
session can be revoked, because the server is holding the only copy of what it
means.

Every logged in person still sees every task, including tasks that are not
theirs. That is the last thing to fix:
[8. Only your own tasks](08-only-your-own.md).
