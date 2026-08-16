# Reference

One page per module. Every public function, its signature, its arguments and
their types, what it returns, what it raises, and a minimal example.

This is the part of the documentation you look things up in. It does not teach.
If you are learning akkar, start with [the guide](../guide/00-quickstart.md),
which builds one application across twelve pages and explains as it goes.

Every fenced Lua example on every page below is run by `spec/docs_spec.lua`.
A block marked `no-run` is compiled but not executed, and it is marked that way
because it is a fragment: a `require` line, a value, or a field to add to a
table you already have.

## Where to start

| you want to | read |
|---|---|
| declare routes, return responses, run the server | [akkar](akkar.md) |
| talk to Postgres | [akkar.db](db.md), [akkar.sql](sql.md), [akkar.migrate](migrate.md) |
| put work off the request path | [akkar.jobs](jobs.md), [akkar.work](work.md) |
| know who the caller is | [akkar.session](session.md), [akkar.auth](auth.md) |
| stop one caller taking the whole server | [akkar.limit](limit.md) |
| see what the server is doing | [akkar.log](log.md), [akkar.metrics](metrics.md), [akkar.trace](trace.md) |
| ship it | [akkar.build](build.md), [akkar.config](config.md), [akkar.health](health.md) |

## Every module

### Core

| module | what it is |
|---|---|
| [akkar](akkar.md) | applications, routes, responses, validation, the server |
| [akkar.scope](scope.md) | rows one tenant may see, enforced at the connection |
| [akkar.strict](strict.md) | makes a global variable an error |
| [akkar.substrate](substrate.md) | repairs the known defects in lua-http before they are hit |

### Data

| module | what it is |
|---|---|
| [akkar.db](db.md) | the Postgres adapter and its pool |
| [akkar.migrate](migrate.md) | schema changes, applied in order, once |
| [akkar.pool](pool.md) | the generic resource pool the adapters are built on |
| [akkar.sql](sql.md) | builds statements with parameters, never with concatenation |

### State and background work

| module | what it is |
|---|---|
| [akkar.cache](cache.md) | the cache capability, in memory or on Redis |
| [akkar.jobs](jobs.md) | a queue with at least once delivery |
| [akkar.redis](redis.md) | the Redis client the other modules use |
| [akkar.storage](storage.md) | files, somewhere other than this disk |
| [akkar.work](work.md) | work that must happen after the response is sent |

### HTTP

| module | what it is |
|---|---|
| [akkar.compress](compress.md) | response compression |
| [akkar.etag](etag.md) | conditional requests, and the write that would vanish |
| [akkar.http](http.md) | the outbound client, as a capability |
| [akkar.idempotency](idempotency.md) | the same request twice, charged once |
| [akkar.multipart](multipart.md) | file uploads |
| [akkar.openapi](openapi.md) | a document describing the routes that exist |
| [akkar.static](static.md) | files served from disk |

### Security

| module | what it is |
|---|---|
| [akkar.auth](auth.md) | password hashing and the authentication middleware |
| [akkar.crypto](crypto.md) | hashing, random bytes, constant time comparison |
| [akkar.csrf](csrf.md) | the cross site request forgery defence |
| [akkar.jwt](jwt.md) | verifying tokens somebody else issued |
| [akkar.limit](limit.md) | rate and concurrency limits |
| [akkar.session](session.md) | who the caller is, across requests |

### Operations

| module | what it is |
|---|---|
| [akkar.config](config.md) | settings from the environment, checked at boot |
| [akkar.doctor](doctor.md) | what is wrong with this installation |
| [akkar.health](health.md) | liveness and readiness |
| [akkar.log](log.md) | structured logging |
| [akkar.metrics](metrics.md) | counters and histograms, in Prometheus text |
| [akkar.trace](trace.md) | W3C trace context, in and out |

### Utilities and tooling

| module | what it is |
|---|---|
| [akkar.build](build.md) | one directory that runs anywhere |
| [akkar.email](email.md) | sending mail |
| [akkar.json](json.md) | encoding and decoding, and the empty array problem |
| [akkar.time](time.md) | clocks, and the one to use for a deadline |
| [akkar.vm](vm.md) | running code that is not yours |
| [akkar.watch](watch.md) | restart on change, in development |

## Conventions on every page

**Signatures.** `akkar.new()` is called with a dot. `app:get(...)` is called
with a colon, which passes the thing on the left in as a hidden first argument.
The page always shows which.

**Tables of fields.** A `required` in the default column means the call raises
without it. An empty default column means the field is optional and has no
value when absent.

**Raises.** akkar raises for programmer mistakes, found at boot or at
registration: an unknown option, a duplicate route, an adapter that cannot
answer its contract. It returns a status for anything the caller did: a body
that fails a schema is 422, not an error. Each page says which is which.

**Not here.** Where a reader would reasonably look for a function that does not
exist, the page says so and gives the reason in one line, rather than leaving
them to search.

**Finding a symbol on a page.** A page with more than about six entries opens
with a list of them, and entries are alphabetical below it. [akkar](akkar.md)
carries around sixty and uses a table instead of a bullet list, because a
sixty-item bullet list is not something you scan.

**Where the reasons are.** These pages say what a function does, not why it was
built that way. Most modules carry a long comment at the top that makes the
argument, and every page ends by pointing at its own source file for it. The
[why pages](../why/) collect the biggest of those arguments.
