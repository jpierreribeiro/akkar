# 9. Talking to it from a frontend

By the end of this page a web page open in your browser will log in to your
task list and show your tasks.

You will also learn why a request can work perfectly in `curl` and fail in the
browser. That is the single most common way a first frontend goes wrong, and
it has one cause and one fix.

## Two servers, not one

Until now you had one terminal running one server. From here you need two
servers, because that is what a real setup looks like:

| | |
|---|---|
| `http://127.0.0.1:3000` | your akkar app, the one you have been building |
| `http://127.0.0.1:5173` | a plain web server handing out one HTML file |

They are two different **origins**. An origin is the scheme, the host and the
port together. `http://127.0.0.1:3000` and `http://127.0.0.1:5173` differ in
the port, so as far as the browser is concerned they are as different as two
strangers' websites.

That fact is the whole page.

## The application, unchanged for now

Same file as page 8. Nothing new in it yet.

```lua
local akkar   = require "akkar"
local db      = require "akkar.db"
local memory  = require "akkar.cache.memory"
local auth    = require "akkar.auth"
local session = require "akkar.session"
local sql     = require "akkar.sql"
local crypto  = require "akkar.crypto"

local app = akkar.new()

local sessions = session.new {
  secret = os.getenv "SESSION_SECRET" or crypto.token(32),
  secure = false,
}

app:use(auth.middleware { sessions = sessions, optional = true })

local function signed_in(req)
  if not req.auth then
    error(akkar.unauthorized "please log in")
  end
  return req.auth.user_id
end

app:post("/signup", { body = { email = "string", password = "string" } },
function(req)
  local taken = req.db:one("select id from accounts where email = $1",
                           req.body.email)
  if taken then
    return akkar.conflict "that email already has an account"
  end

  local account = req.db:one(
    "insert into accounts (email, password_hash) values ($1, $2) returning id",
    req.body.email, crypto.hash_password(req.body.password))

  auth.login(req, account.id)
  return akkar.created { id = account.id, email = req.body.email }
end)

app:post("/login", { body = { email = "string", password = "string" } },
function(req)
  local account = req.db:one(
    "select id, password_hash from accounts where email = $1", req.body.email)
  if not account
     or not crypto.verify_password(req.body.password, account.password_hash) then
    return akkar.unauthorized "wrong email or password"
  end
  auth.login(req, account.id)
  return { id = account.id, email = req.body.email }
end)

app:post("/logout", function(req)
  auth.logout(req)
  return akkar.no_content()
end)

app:get("/tasks", function(req)
  local mine = req.db:scope("user_id", signed_in(req))
  local rows = mine:many(sql.select("id, title, done"):from "tasks")
  return { tasks = akkar.array(rows) }
end)

app:post("/tasks", { body = { title = "string" } }, function(req)
  local mine = req.db:scope("user_id", signed_in(req))
  return akkar.created(mine:one(
    sql.insert_into("tasks", { title = req.body.title }, { "title" })
       :returning "id, title, done"))
end)

app:run {
  port = 3000,
  db = db.connect {
    host = "127.0.0.1", port = 55432, database = "akkar",
    user = "postgres", password = "akkar",
  },
  cache = memory.new(),
}
```

Start it in terminal one:

```sh
lua5.4 app.lua
```

## An account to log in with

Make one now, so the page has something to talk to.

```sh
curl -s -X POST http://127.0.0.1:3000/signup \
  -H "content-type: application/json" \
  -d '{"email":"grace@example.com","password":"correct horse battery"}'
```

```
{"email":"grace@example.com","id":5}
```

Your `id` will be a different number. That is fine, nothing below depends on
it.

## The web page

Make a folder called `web` next to `app.lua`, and put this in `web/index.html`.
It is the whole frontend. There is no build step and no framework.

```html
<!doctype html>
<meta charset="utf-8">
<title>My tasks</title>

<h1>My tasks</h1>

<form id="login">
  <input id="email" value="grace@example.com">
  <input id="password" type="password" value="correct horse battery">
  <button>Log in</button>
</form>

<button id="load">Load my tasks</button>

<pre id="out">nothing yet</pre>

<script>
const API = "http://127.0.0.1:3000";

login.onsubmit = async (event) => {
  event.preventDefault();
  const res = await fetch(API + "/login", {
    method: "POST",
    headers: { "content-type": "application/json" },
    credentials: "include",
    body: JSON.stringify({ email: email.value, password: password.value }),
  });
  out.textContent = res.status + " " + await res.text();
};

load.onclick = async () => {
  const res = await fetch(API + "/tasks", { credentials: "include" });
  out.textContent = res.status + " " + await res.text();
};
</script>
```

Three things in that file are worth naming, because the rest is ordinary HTML.

**`fetch`** is how a web page makes an HTTP request. It returns a promise, so
`await` waits for the answer. `res.status` is the number you have been reading
in `curl -i` all along.

**`JSON.stringify`** turns a JavaScript object into the JSON text your server
expects, and the `content-type` header tells the server that is what it is.
Exactly what `curl -d` was doing for you.

**`credentials: "include"`** is the line this page exists for. Leave it for
now. It has its own section below, and it will not do anything useful until
CORS is working.

## Serving the page

Do not open the file by double-clicking it. A file opened that way has the
origin `null`, and nothing in this page will work.

Serve it instead. In a **third terminal**:

```sh
cd web
python3 -m http.server 5173 --bind 127.0.0.1
```

```
Serving HTTP on 127.0.0.1 port 5173 (http://127.0.0.1:5173/) ...
```

Any small static server will do. `python3` is used here because it is already
on most machines.

Now open `http://127.0.0.1:5173/index.html` in your browser.

## It does not work, and nothing tells you why

Press **Load my tasks**. Nothing happens. The `nothing yet` text does not
change.

Press **Log in**. Nothing happens either.

This is the worst part of the whole experience, so it is worth saying plainly:
**the page is not broken and neither is your server.** The browser refused to
hand the answer to your JavaScript, and it did not tell the page why.

The reason is in the browser console. Open it with `F12`, or right-click the
page and choose **Inspect**, then the **Console** tab. Press the buttons again.

After **Load my tasks**:

```
Access to fetch at 'http://127.0.0.1:3000/tasks' from origin
'http://127.0.0.1:5173' has been blocked by CORS policy: No
'Access-Control-Allow-Origin' header is present on the requested resource.
```

After **Log in**:

```
Access to fetch at 'http://127.0.0.1:3000/login' from origin
'http://127.0.0.1:5173' has been blocked by CORS policy: Response to preflight
request doesn't pass access control check: No 'Access-Control-Allow-Origin'
header is present on the requested resource.
```

Learn to reach for that console early. It is the only place the real message
appears.

## What CORS is, in one screen

The browser follows a rule called the **same-origin policy**. Code loaded from
one origin may not read the answer from another origin.

The rule exists to protect you rather than the server. Imagine you are logged
in to your bank. You open a page on `evil.example`. Without the rule, that
page's JavaScript could call your bank's API, and your browser would happily
attach your bank cookies to the request. The page would read your balance and
send it anywhere. That is not a hypothetical; it is why the rule was added.

So the browser blocks it by default, and asks the other server for permission.
**CORS**, which stands for cross-origin resource sharing, is the server's way
of granting that permission. It is a set of response headers that say "these
origins may read my answers".

Three things follow, and each one surprises people:

**The server is not refusing.** Your akkar app answered normally. The browser
made the request, got the answer, saw no permission header on it, and threw the
answer away before your JavaScript could see it. The block is on the reading
end, not the sending end.

**So `curl` cannot see the problem.** `curl` is not a browser and has no
same-origin policy. Prove it to yourself while the page is still broken:

```sh
curl -s -i -c cookies.txt -X POST http://127.0.0.1:3000/login \
  -H "content-type: application/json" \
  -d '{"email":"grace@example.com","password":"correct horse battery"}'
```

```
HTTP/1.1 200 OK
set-cookie: akkar_session=f78581c309abe921d47c0fba43ab760933a44ab5732672de13bbafd09e49df13.74bad22e6c02257572e2ce90a86c4884ad7257e0b94aaf8039d59b13a94ab907; Path=/; Max-Age=1209600; HttpOnly; SameSite=Lax
x-request-id: 882325a3000001
content-type: application/json
content-length: 36

{"email":"grace@example.com","id":5}
```

```sh
curl -s -i -b cookies.txt http://127.0.0.1:3000/tasks
```

```
HTTP/1.1 200 OK
x-request-id: 882325a3000002
content-type: application/json
content-length: 57

{"tasks":[{"done":false,"title":"call the bank","id":9}]}
```

Both work. **"It works in curl" is not evidence that a CORS problem is not a
CORS problem.** It is the expected result.

**The second error message mentioned a preflight.** For some requests the
browser asks permission first, with a separate `OPTIONS` request, before
sending yours at all. There is a section on that below. It is one extra step,
not a new idea.

## Granting permission, the wrong way first

akkar has the middleware for this. Add these lines to `app.lua`, right after
`akkar.new()`:

```lua no-run
app:use(akkar.cors {
  origin = "*",
})
```

`*` means "any origin at all". It is what every search result suggests and it
is the first thing everybody tries.

Restart the server and press **Log in** again. The console now says something
different:

```
Access to fetch at 'http://127.0.0.1:3000/login' from origin
'http://127.0.0.1:5173' has been blocked by CORS policy: Response to preflight
request doesn't pass access control check: The value of the
'Access-Control-Allow-Origin' header in the response must not be the wildcard
'*' when the request's credentials mode is 'include'.
```

A different error is progress. The browser is now reading your permission
header, and it is refusing this particular permission.

The rule it is enforcing is simple once stated: **you may say "anyone may read
this", or you may say "and send the cookies too", but never both.** "Anyone may
read this, with the user's cookies attached" is the exact attack the
same-origin policy exists to stop, so the browser will not let a server grant
it even by accident.

Your task list needs cookies. So the wildcard is out.

## Granting permission, the right way

Name the origin, and say that credentials are allowed.

```lua no-run
app:use(akkar.cors {
  origin = "http://127.0.0.1:5173",
  credentials = true,
})
```

Restart the server. Press **Log in**, then **Load my tasks**. The grey box
under the buttons shows, in turn:

```
200 {"email":"grace@example.com","id":5}
```

```
200 {"tasks":[{"title":"call the bank","done":false,"id":9}]}
```

That is a browser, on one origin, logged in to your API on another origin,
reading rows that belong to that account and to nobody else.

Two notes on the options:

- `origin` is one exact origin string. Match it character for character,
  including the scheme and the port. `http://localhost:5173` is **not** the
  same origin as `http://127.0.0.1:5173`, even though they reach the same
  machine.
- `credentials = true` sends the `access-control-allow-credentials` header,
  which is the server's half of the cookie agreement. The page's half is the
  next section.

When you deploy, this becomes your real frontend address. Page 12 reads it
from an environment variable instead of writing it into the file.

## `credentials: "include"`, the thing that catches everyone

Here is the failure that sends people looking in entirely the wrong place.

Take the two `credentials: "include"` lines out of `index.html`, so the fetch
calls look like this:

```js
const res = await fetch(API + "/login", {
  method: "POST",
  headers: { "content-type": "application/json" },
  body: JSON.stringify({ email: email.value, password: password.value }),
});
```

```js
const res = await fetch(API + "/tasks");
```

Reload the page and press the two buttons in order. The grey box shows:

```
200 {"email":"grace@example.com","id":5}
```

```
401 {"error":"please log in"}
```

**Read that twice.** The login said `200`. It worked. The very next request
says you are not logged in.

Nothing is wrong with your server. `curl` does exactly this sequence and gets
`200` both times, which is why hours get lost here.

The cause: **`fetch` does not send or store cookies across origins unless you
tell it to.** By default it behaves as if the `Set-Cookie` on that `200` had
never arrived. The browser received the cookie and dropped it, so the next
request carried nothing, so your server correctly said "please log in".

`credentials: "include"` is what turns cookies on for a cross-origin `fetch`.
It does two jobs at once, and both matter:

- it lets the browser **store** a `Set-Cookie` that comes back from another
  origin;
- it makes the browser **attach** that cookie to later requests to that origin.

Put the two lines back. It works again.

Both halves have to agree, and there is no useful error when they do not:

| | the page sends | the server allows | result |
|---|---|---|---|
| both off | no cookies | no credentials | you are never logged in |
| page only | cookies | no credentials | blocked, CORS error in the console |
| server only | no cookies | credentials | you are never logged in |
| both on | cookies | credentials | it works |

Two of those four rows fail silently as far as the page is concerned, which is
why this is the most-searched question about browsers and APIs.

## The preflight, since you saw it named

Your `POST /login` sends `content-type: application/json`. That is enough to
make the browser ask permission before sending anything.

The permission question is an `OPTIONS` request. You can send one by hand:

```sh
curl -s -i -X OPTIONS http://127.0.0.1:3000/login \
  -H "Origin: http://127.0.0.1:5173" \
  -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: content-type"
```

```
HTTP/1.1 204 No Content
access-control-allow-origin: http://127.0.0.1:5173
allow: OPTIONS, POST
access-control-allow-methods: OPTIONS, POST
access-control-allow-credentials: true
access-control-allow-headers: content-type, authorization
access-control-max-age: 600
x-request-id: 8ab1738b000009
content-length: 0
```

Read it as a conversation. The browser asked "may `http://127.0.0.1:5173` send
a `POST` with a `content-type` header?" and the server answered "yes, and
`OPTIONS` and `POST` are the methods this path has, and do not ask again for
600 seconds".

You wrote no `OPTIONS` route. akkar answers preflights from its own routing
table, so `access-control-allow-methods` lists the methods that really exist on
that path rather than a guess. That is also why `allow` says `OPTIONS, POST`
and not, say, `DELETE`.

**This is the first place to look when a request works in `curl` and not in the
browser.** Run the `OPTIONS` above against the failing path. If it does not
come back with your origin in it, the preflight is the failure.

## Why the task list is wrapped in `akkar.array`

There is one call in `GET /tasks` that has not been explained, and the browser
is where it earns its place.

Make a second account, one with no tasks in it:

```sh
curl -s -c new-cookies.txt -X POST http://127.0.0.1:3000/signup \
  -H "content-type: application/json" \
  -d '{"email":"lovelace@example.com","password":"correct horse battery"}'
```

```
{"email":"lovelace@example.com","id":8}
```

Now imagine the handler without that call, written the plain way:

```lua no-run
app:get("/tasks", function(req)
  local mine = req.db:scope("user_id", signed_in(req))
  return { tasks = mine:many(sql.select("id, title, done"):from "tasks") }
end)
```

```sh
curl -s -b new-cookies.txt http://127.0.0.1:3000/tasks
```

```
{"tasks":{}}
```

`{}`, not `[]`. Add one task and it changes shape:

```sh
curl -s -b new-cookies.txt -X POST http://127.0.0.1:3000/tasks \
  -H "content-type: application/json" -d '{"title":"buy a birthday card"}'
```

```
{"title":"buy a birthday card","done":false,"id":11}
```

```sh
curl -s -b new-cookies.txt http://127.0.0.1:3000/tasks
```

```
{"tasks":[{"title":"buy a birthday card","done":false,"id":11}]}
```

**That is a bug, and it is yours to fix rather than the browser's to survive.**
An endpoint whose type depends on how much data it found is an endpoint every
caller has to write a special case for.

In `curl` it looks like a curiosity. In the browser it is a crash:
`data.tasks.map(...)` on `{}` throws `data.tasks.map is not a function`, and it
throws only for accounts with nothing in them, which is every brand new user.

The cause is a real ambiguity in Lua. An empty Lua table is both an empty list
and an empty object, and nothing in the table says which one you meant. akkar's
JSON encoder has to guess, and it guesses `{}`.

`akkar.array` is how you say which one you meant, and it is why the handler in
your file already reads like this:

```lua no-run
app:get("/tasks", function(req)
  local mine = req.db:scope("user_id", signed_in(req))
  local rows = mine:many(sql.select("id, title, done"):from "tasks")
  return { tasks = akkar.array(rows) }
end)
```

```sh
curl -s -b new-cookies.txt http://127.0.0.1:3000/tasks
```

```
{"tasks":[]}
```

Only the empty case ever changed. A list with rows in it was already an array.

**Wrap every list you return.** It costs one call and it removes a whole class
of frontend bug that only appears for the emptiest, newest accounts, which are
exactly the ones you test with last.

If you are consuming an API somebody else wrote and it does this, the guard on
your side is one line:

```js
const tasks = Array.isArray(data.tasks) ? data.tasks : [];
```

## The whole application

`app.lua`, with the four new lines in it:

```lua
local akkar   = require "akkar"
local db      = require "akkar.db"
local memory  = require "akkar.cache.memory"
local auth    = require "akkar.auth"
local session = require "akkar.session"
local sql     = require "akkar.sql"
local crypto  = require "akkar.crypto"

local app = akkar.new()

app:use(akkar.cors {
  origin = "http://127.0.0.1:5173",
  credentials = true,
})

local sessions = session.new {
  secret = os.getenv "SESSION_SECRET" or crypto.token(32),
  secure = false,
}

app:use(auth.middleware { sessions = sessions, optional = true })

local function signed_in(req)
  if not req.auth then
    error(akkar.unauthorized "please log in")
  end
  return req.auth.user_id
end

app:post("/signup", { body = { email = "string", password = "string" } },
function(req)
  local taken = req.db:one("select id from accounts where email = $1",
                           req.body.email)
  if taken then
    return akkar.conflict "that email already has an account"
  end

  local account = req.db:one(
    "insert into accounts (email, password_hash) values ($1, $2) returning id",
    req.body.email, crypto.hash_password(req.body.password))

  auth.login(req, account.id)
  return akkar.created { id = account.id, email = req.body.email }
end)

app:post("/login", { body = { email = "string", password = "string" } },
function(req)
  local account = req.db:one(
    "select id, password_hash from accounts where email = $1", req.body.email)
  if not account
     or not crypto.verify_password(req.body.password, account.password_hash) then
    return akkar.unauthorized "wrong email or password"
  end
  auth.login(req, account.id)
  return { id = account.id, email = req.body.email }
end)

app:post("/logout", function(req)
  auth.logout(req)
  return akkar.no_content()
end)

app:get("/tasks", function(req)
  local mine = req.db:scope("user_id", signed_in(req))
  local rows = mine:many(sql.select("id, title, done"):from "tasks")
  return { tasks = akkar.array(rows) }
end)

app:post("/tasks", { body = { title = "string" } }, function(req)
  local mine = req.db:scope("user_id", signed_in(req))
  return akkar.created(mine:one(
    sql.insert_into("tasks", { title = req.body.title }, { "title" })
       :returning "id, title, done"))
end)

app:run {
  port = 3000,
  db = db.connect {
    host = "127.0.0.1", port = 55432, database = "akkar",
    user = "postgres", password = "akkar",
  },
  cache = memory.new(),
}
```

One warning about restarting. Sessions live in `akkar.cache.memory`, which
lives inside the process. Stop the server and every session is gone, so the
page has to log in again. Page 11 moves them to Redis, which survives a
restart.

## Checkpoint

You have this if:

- the browser page logs in and lists tasks, with no red text in the console
- you can say why the browser blocked the first attempt and `curl` did not
- you can say what `credentials: "include"` does, and what happens without it
- `curl -X OPTIONS` against `/login` answers with your origin in it

Next in the guide: work that happens after the response has already gone.
