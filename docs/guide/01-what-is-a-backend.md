# 1. What a backend even is

By the end of this page you will be able to picture what a backend does, in
enough detail to read the next page and know what you are building.

There is no code here. Nothing to install, nothing to run. Read it once.

## A backend is a program that waits

Most programs you have written start, do something, and finish.

A backend does not finish. It starts, opens a door on the network, and then it
waits. Someone knocks, it answers, and it goes back to waiting. It does that
for months.

That is the whole shape. The rest of this page is about what "knocks" and
"answers" mean.

## The knock is called a request

A request is a short message. Three parts matter to you right now.

**A method.** One word saying what kind of thing the caller wants:

| Method | Means |
|---|---|
| `GET` | give me something. Do not change anything |
| `POST` | here is something new, create it |
| `PUT` / `PATCH` | change something that already exists |
| `DELETE` | remove something |

These are conventions, not rules the network enforces. But everybody follows
them, and so should you, because tools and browsers assume it.

**A path.** Which thing: `/tasks`, `/tasks/7`, `/users/3/settings`.

**Sometimes a body.** Extra data attached to the request. A `GET` normally has
no body. A `POST` normally does, because you have to say what to create.

Put together, a request is a sentence: `GET /tasks` is "give me the tasks".
`POST /tasks` with a body is "create a task, here are the details".

## The answer is called a response

A response has two parts that matter right now.

**A status code.** A three digit number saying how it went. The first digit is
the summary:

| Starts with | Means | Example |
|---|---|---|
| `2` | it worked | `200 OK`, `201 Created` |
| `4` | the caller got something wrong | `404 Not Found` |
| `5` | the server got something wrong | `500 Internal Server Error` |

The difference between `4` and `5` matters more than it looks, and page 4 is
entirely about it.

**A body.** The actual data. For the kind of backend this guide builds, that
body is always JSON.

## A route is one path plus one method

Your backend will answer some requests and not others. Each combination it
agrees to answer is a **route**.

`GET /tasks` is one route. `POST /tasks` is a different route, even though the
path is the same, because the method is different. `GET /tasks/7` is a third.

Writing a backend is mostly: deciding what routes exist, and writing the code
that answers each one.

## JSON is data written as text

Two programs cannot pass a table or an object to each other. They can only
send bytes down a wire. So they agree on a way to write data as text, and JSON
is the way almost everyone agrees on.

It looks like this:

```
{"id": 1, "title": "buy milk", "done": false}
```

That is one object with three fields. A field name is always in double quotes.
Values can be text (in quotes), numbers, `true`, `false`, `null`, another
object, or a list in square brackets:

```
{"tasks": [{"id": 1, "title": "buy milk"}, {"id": 2, "title": "walk the dog"}]}
```

That is it. JSON has no more features than that. Every programming language can
read it and write it, which is exactly why it won.

akkar reads JSON out of incoming requests for you, and turns what your code
returns into JSON on the way out. You will rarely type JSON by hand.

## Why a browser cannot just talk to the database

This is the question that makes the whole job make sense, so it is worth two
minutes.

A database is a program too. It also waits for connections. So a fair question
is: why not let the web page connect to the database directly and skip the
backend entirely?

**Because everything a browser holds is public.** Code you send to a browser
can be read by whoever is using that browser. If the page carries the database
password, then every visitor has the database password. Not "could get it with
effort". Has it. Two clicks in the developer tools.

And a database password is not a small key. It is usually permission to read
every row belonging to every user, and to delete all of it.

**Because the database has no idea who anyone is.** A database checks one
thing: does this connection have a valid password. It cannot check "is this
person allowed to see task 7". That rule lives in your application, not in the
database, so something has to be in the middle to apply it.

**Because a database connection is expensive.** Each one costs the database
real memory. A server keeps a small pool of connections and shares them across
thousands of callers. Ten thousand browsers each opening their own connection
would fall over immediately.

So the backend sits in the middle. It is the only thing holding the password,
the only thing that knows who the caller is, and the only thing allowed to
decide what they may see.

```
browser  ---- request ---->  backend  ---- query ---->  database
         <--- response ----           <--- rows -----
```

The browser asks the backend. The backend decides. The backend asks the
database. Nobody skips a step.

## What you are about to build

A task list. Over the next pages it will grow like this:

- **Page 2:** one route that returns a fixed list of tasks
- **Page 3:** ask for one task by id, filter the list, and create a task
- **Page 4:** answer properly when something goes wrong

The tasks live in a plain Lua table for now, which means they disappear when
you stop the server. A real database comes later in the guide. Everything you
write before then keeps working when it arrives.

## Checkpoint

You should now be able to answer these without looking:

- What are the two parts of a response that matter? (a status code and a body)
- What is a route? (one path plus one method)
- Why does the backend exist instead of letting the browser talk to the
  database? (the browser cannot keep a secret, cannot be trusted to enforce
  rules, and there would be far too many connections)

If those feel clear, go to [2. Your first route](02-your-first-route.md).
