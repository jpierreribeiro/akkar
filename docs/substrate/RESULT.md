# Substrate proof

Run on 2026-08-14, before a line of the framework was written.

The point was to find out whether Lua 5.4 on `cqueues` and `lua-http` can carry
a production JSON API at all — and to find that out in an afternoon rather than
in month three. **All four checks passed.**

| # | Check | Result |
|---|---|---|
| 1 | `lua-http` starts and answers | **ok** |
| 2 | TLS against OpenSSL 3.0.13 — *high risk* | **ok**, TLS 1.3 |
| 3 | The Postgres driver yields the coroutine | **ok**, 7.56x out of 8x |
| 4 | CRUD routes returning real JSON | **ok**, with the invariants |

---

## Environment

LuaRocks was built from source into `~/.local`, with no root. Rocks landed in
`~/.luarocks`:

| Rock | Version | Note |
|---|---|---|
| cqueues | 20200726.54 | **last release in 2020** — six years |
| luaossl | 20250929 | current and maintained |
| http (lua-http) | 0.4 | |
| pgmoon | 1.18.0 | pure Lua, speaks the Postgres wire protocol directly |
| lua-cjson | 2.1.0.10 | |
| luasocket | 3.1.0 | only for the `mime` module — see finding 2 |
| busted | 2.3.0 | |

`libpq` was **not** needed: pgmoon is pure Lua over a socket.

Postgres 16 in Docker on port 55432.

---

## Check 3 — driver concurrency

`01_concurrency.lua`, eight connections running `select pg_sleep(1)`:

```
sequential control       8.035 s
concurrent               1.064 s
speedup                  7.56x   (ideal ~8x)
```

And through the real HTTP path, over TLS, with four requests to a route that
sleeps for a second:

```
sequential   4.270 s
parallel     1.102 s     -> 3.9x out of 4x
```

**pgmoon yields the coroutine under cqueues.** One coroutine per request holds.

## Check 2 — TLS

This was the high risk. Compiling proved nothing: luaossl compiled with
deprecation warnings against OpenSSL 3.0.

The handshake completed, and was confirmed by a **fully independent external
client**:

```
$ openssl s_client -connect 127.0.0.1:8443 -brief
Protocol version: TLSv1.3
Ciphersuite: TLS_AES_256_GCM_SHA384
Verification error: self-signed certificate     (expected, test cert)
```

`curl` over HTTPS returned JSON read from Postgres. **Risk cleared.**

## Check 4 — CRUD and invariants

Every invariant that can be proven without infrastructure was verified by a
real request:

| Case | Expected | Got |
|---|---|---|
| `GET /` | 200 | `{"hello":"world"}` |
| `GET /users` | 200 | rows from the database |
| `GET /users/1` | 200 | one row |
| `GET /users/999` | 404 | `{"error":"user not found"}` |
| `POST /users` | 201 | `{"id":3,...}` |
| `POST` without `name` | 400 | `{"error":"name is required"}` |
| Malformed JSON | 400 | `{"error":"invalid JSON body"}` |
| `DELETE /users/2` | 204 | empty body |
| Unknown route | 404 | `{"error":"no route for GET /nada"}` |

That throwaway CRUD script has since been superseded by `examples/crud.lua`,
which covers ten scenarios instead of four.

## The watchdog works

A CPU-bound handler burning 200 ms without yielding:

```
[akkar] WARNING: handler blocked the loop for 102 ms without yielding
  at examples/crud.lua:65
stack traceback:
	examples/crud.lua:67: in function <examples/crud.lua:65>
  this stalls every request in this process.
```

It named the file, the handler line, and the exact line inside the loop. The
request finished normally in 200 ms — the warning does not interfere.

---

## Findings

1. **A malformed body skipped the middleware.** The parse error short-circuited
   ahead of the chain, so logging middleware never saw the 400. Every request
   must traverse the whole chain, including the ones that fail early. *A design
   defect, found by reading the log.* Fixed by making the end of the chain a
   parameter; there is a test pinning it.

2. **pgmoon has an undeclared dependency.** It requires `mime`, from luasocket,
   without declaring it in its own rockspec. A clean install dies with a
   `require` traceback. `akkar-dev-1.rockspec` declares luasocket explicitly to
   compensate.

3. **pgmoon has no prepared statements.** `akkar/db.lua` interpolates `$1`
   through `escape_literal`, which is safe against injection but is not the
   extended protocol. Still open.

4. **cqueues has had no release since 2020.** It works perfectly with Lua 5.4,
   but this is a confirmed maintenance risk, not a hypothetical one. The
   adapter boundary is what limits the blast radius.

5. **No connection pool.** One connection per request. Still open.

---

## Reproducing

```sh
export PATH="$HOME/.local/bin:$PATH"
eval "$(luarocks path --bin)"

docker run -d --name akkar-pg \
  -e POSTGRES_PASSWORD=akkar -e POSTGRES_DB=akkar \
  -p 55432:5432 postgres:16-alpine

mkdir -p /tmp/akkar-tls
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /tmp/akkar-tls/key.pem -out /tmp/akkar-tls/cert.pem \
  -days 2 -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1"

lua5.4 docs/substrate/01_concurrency.lua
lua5.4 docs/substrate/03_tls.lua
```
