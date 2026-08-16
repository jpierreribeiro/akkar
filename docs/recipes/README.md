# Recipes

One page, one problem, one complete solution you can copy. Every page is
independent: nothing here assumes you read the page before it.

If you are learning akkar rather than looking something up, start with the
guide at [00-quickstart.md](../guide/00-quickstart.md) instead. These pages
assume you already know what you want.

Every server here binds port 3000, the same port the guide uses, so stop one
before starting the next.

## Data out

- [Paginate a list](paginate-a-list.md). A page of rows, and a cursor for the
  next page.
- [Return a CSV](return-a-csv.md). A spreadsheet instead of JSON, with a
  filename.
- [Stream a large response](stream-a-large-response.md). An export of any
  size, at the memory cost of one row.

## Data in

- [Upload a file](upload-a-file.md). A file from a form, checked and written
  to disk.
- [Make a write idempotent](make-a-write-idempotent.md). The same POST twice
  charges once.

## Load and cost

- [Cache an expensive query](cache-an-expensive-query.md). Compute once,
  serve everyone else from Redis.
- [Rate limit one endpoint](rate-limit-one-endpoint.md). A limit on one path
  and nowhere else.
- [See what is slow](see-what-is-slow.md). Durations per route, and the
  warning for a handler that blocks.

## Talking to other services

- [Call another API and handle failure](call-another-api.md). A timeout, and
  an answer of your own when they do not have one.
- [Retry safely](retry-safely.md). Retry without turning one order into three.
- [Send email](send-email.md). Through a provider's API, without the request
  falling over when it fails.

## Work that happens later

- [Run a worker in the same process](run-a-worker-in-the-same-process.md).
  `app:task`, an in-memory queue, one process.
- [Schedule a recurring job](schedule-a-recurring-job.md). Every minute, and
  stopping cleanly with the server.

## Configuration and deployment

- [Read config from the environment](read-config-from-the-environment.md).
  One schema, and a refusal to start when a setting is missing.
- [Run migrations on deploy](run-migrations-on-deploy.md). A program that
  migrates and exits.
- [Serve a frontend from the same server](serve-a-frontend.md). One origin,
  no CORS.

## Testing and operating

- [Test a route](test-a-route.md). The whole chain, no socket.
- [Test something that hits the database](test-with-the-database.md). Real
  Postgres, with clean rows between tests.
- [Log usefully](log-usefully.md). Fields, levels, and the request id that
  ties the lines together.

## What is not here

**Accept a webhook and verify its signature.** akkar cannot do this today, so
there is no page pretending otherwise. Providers such as Stripe, GitHub and
Slack sign the exact bytes of the request body, and akkar decodes the body
before a handler runs and does not keep the bytes: `req.body` is a Lua table
and there is no `req.raw_body`. Re-encoding the table produces different
bytes, so the signature will not match. A provider that signs something other
than the raw body, such as the URL plus the form fields in sorted order, can
be verified today with `akkar.crypto.hmac_verify` and `akkar.crypto.equal`.
Verifying the common case needs akkar to keep the undecoded body, which is a
change to the framework rather than a way of using it.

## How these pages stay true

`spec/docs_spec.lua` extracts every fenced Lua block on every page here and
runs it, the same as it does for the guide. A block that raises fails the
suite. Two kinds of block are marked `no-run` and are compiled but not
executed: a busted spec, because busted runs it and `lua5.4` does not, and
the configuration page, because what its file does depends on the environment
it is started in. Each page says so where it happens.
