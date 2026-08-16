# Why sessions are kept on the server

akkar's answer to "keep this user logged in" is an opaque random id in a
cookie, and the state on the server. It is not a JWT, and `akkar/jwt.lua`
deliberately has no way to make one.

That is a strong position, so this page gives the argument, gives JWT its due,
and states what the choice costs you.

## The one property that decides it

`akkar/session.lua` opens with the whole design in one sentence:

> A session is an id in a cookie and state on the server. It is not a JWT.

The reason is revocation. **A signed token that carries its own claims cannot
be revoked before it expires**, and revocation is the thing a session most
needs:

- log out
- change password
- ban an account
- rotate after a privilege change

Every workaround reintroduces exactly what the token was supposed to remove. A
deny-list is a server-side lookup on every request. A short expiry with a
refresh token is a server-side lookup on every refresh, plus a second
credential with its own storage and its own theft story. In both cases the
system now has two mechanisms where it had one, and the second one is the thing
the first was meant to replace.

If you are going to do a lookup anyway, do the simple lookup.

## The second half: where the credential lives in a browser

A token in a browser has to be stored somewhere. `localStorage` is readable by
any script on the page, so **one XSS is every session**. A cookie marked
`HttpOnly` is not readable by script at all.

`akkar/session.lua` puts it bluntly: "The browser has done this correctly since
1994 and akkar is not going to improve on it."

So the defaults are on rather than available. `HttpOnly`, `Secure` and
`SameSite=Lax` are all default true in `akkar/session.lua`, on the principle
that "an option nobody sets is the option everybody gets".

## What the cookie actually contains

The value is `<id>.<hmac>`. The id is 32 random bytes and means nothing by
itself.

The signature is not there to hide anything, because there is nothing in it to
hide. It is there so that a forged string is rejected by an HMAC comparison
instead of by a round trip to Redis. That is the difference between a nuisance
and a denial of service. The comparison is constant time, through
`akkar.crypto.equal`.

The signing secret must be at least 32 bytes and akkar refuses to start
without one, because "a signing key somebody typed by hand is a signing key an
attacker guesses".

```lua
local sessions = require "akkar.session"
local cache    = require("akkar.cache.memory").new()

local manager = sessions.new { secret = require("akkar.crypto").token(32) }

-- First request: nobody is logged in yet.
local first = manager:open(cache, nil)
first:set("user", "ada")
local set_cookie = first:commit()
print(set_cookie:find "HttpOnly" ~= nil)     --> true

-- Second request, carrying the cookie the browser stored.
local value  = set_cookie:match "^akkar_session=([^;]+)"
print(manager:open(cache, "akkar_session=" .. value):get "user")   --> ada

-- Logging out removes the state on the SERVER, not only in the browser.
local out = manager:open(cache, "akkar_session=" .. value)
out:destroy()
out:commit()
print(manager:open(cache, "akkar_session=" .. value):get "user")   --> nil
```

That last line is the entire argument, executed. With a self-contained token,
the equivalent line still prints the user until the token expires.

## Three details that are not obvious

**Log out clears both halves.** Clearing the cookie alone leaves the state in
the store, so a stolen cookie value keeps working after the user pressed "log
out". `Session:destroy` removes the server state too.

**The id rotates on login.** Session fixation is an attacker who can plant a
cookie in your browser before you log in, and therefore knows your session id
after you log in. `:regenerate()` issues a new id and moves the data;
`akkar.auth` calls it for you. For the same reason, an unknown cookie gets a
**new** id rather than the one the client supplied, because accepting an
attacker chosen id for an empty session is fixation with extra steps.

**The cookie is only rewritten when something changed.** `Session:commit`
returns nil when the session is clean. That is not an optimisation, it is a
correctness property: rewriting the cookie on every response resets its expiry
on every poll, and a session that never expires while a tab is open is a
session that outlives the laptop being stolen.

## Sessions live in `cache`, not in the database

This is a real trade, and `akkar/session.lua` records both sides.

A session is expiring key and value data, which is what a cache *is*. Putting
it in Postgres makes every request that touches a session a database round
trip.

- **Cost of the cache**: a cache flush logs everybody out. Annoying, not
  dangerous.
- **Cost of the database**: paid on every single request.

The choice went to the annoying one.

## Being fair to JWT

JWT is not banned, and pretending it has no honest use would be dishonest.

Its honest use is **a short-lived assertion issued by somebody else, which you
verify**. An identity provider (Auth0, Okta, Keycloak, Google, your company's
SSO) states who the caller is, signs it, and it expires in minutes. You did not
mint it. You could not revoke it if you wanted to, because it is not yours.
Verifying it at your edge is exactly the right thing to do.

Service to service calls are the same shape: short lifetime, no logout, no
"ban this token" requirement, and no shared session store between the two
services.

So akkar ships `akkar/jwt.lua` with `verify`, and **nothing that signs**. Its
own docstring explains why the missing half is the design:

> An `issue` function here would be picked up within a week by somebody who
> wanted a login that did not need Redis, and the argument in `session.lua`
> would be lost to a convenience. The only way to make that argument hold is to
> not ship the function.

You may reasonably think that is paternalistic. It is. It is also the only
version of the rule that survives contact with a deadline.

### What verifying properly means, since the module exists

Two attacks are older than most of the libraries that still fall for them, and
both come from the same root: **a JWT tells you which algorithm to use to check
it, and that field is the attacker's to fill in.**

- **`alg: none`.** The specification has an unsecured JWT whose signature is
  the empty string. A verifier that dispatches on the header's `alg` reports
  its claims as verified. Every one of them was written by the sender.
- **RS256 to HS256 confusion.** A service configured for RS256 holds the
  issuer's *public* key. An attacker rewrites the header to HS256 and signs
  with that public key as an HMAC secret. A verifier that dispatches on `alg`
  computes HMAC with the key it has, which is the key the attacker used, and
  the signature matches.

The fix is structural rather than a check: **the caller states the algorithm
and the header must agree with it.** `alg` is a required option, not a default.
`spec/jwt_spec.lua` runs both attacks against a correctly configured verifier
and asserts the refusal.

Three more refusals rather than warnings, because a caller who reads
`claims.sub` after a warning has already trusted the token:

- `exp` is required, since a bearer assertion with no expiry is a permanent
  credential handed to a system that cannot revoke it.
- `aud` must be checked when the token carries one, or you accept a token the
  user obtained for a different service.
- RSA and ECDSA are refused with a message. HMAC only. Falling through to an
  HMAC comparison would *be* the confusion attack.

## What the server-side choice costs

**You need a store, and which store you have decides whether it works.**
`akkar.cache.memory` is per process. akkar's answer to more CPU is more
processes. So a two process deployment with the memory cache gives a user a
session that only works on whichever process happens to accept the next
connection. For anything beyond one process, sessions mean Redis. This is the
same limit that applies to rate limiting and idempotency, and it is stated in
the README's known gaps rather than discovered.

**Every authenticated request costs a store round trip.** This is the cost JWT
exists to remove, and it is real. It is a Redis GET, not a database join, and
the HMAC check on the cookie means forged ids never reach the store at all, but
it is not zero.

**Cookies bring CSRF with them.** A JSON API on bearer tokens does not need
CSRF defence; a cookie authenticated one absolutely does.
`docs/ROADMAP.md` puts it plainly: the module that introduces cookies is the
module that owes the defence. `akkar/csrf.lua` is that defence.

**Cross-domain gets harder.** `SameSite=Lax` and a browser cookie are a
same-site story. A mobile app, a third-party client or an API consumed from
another origin is where a bearer token is genuinely more convenient.
`akkar/auth.lua` carries three schemes for that reason, and its bearer strategy
is verified by a function you supply: akkar does not decide what the token
means. If it is a JWT from an identity provider you verify it there; if it is
an opaque token you look it up.

## What to read next

- `akkar/session.lua` and `akkar/jwt.lua`, both of which argue for themselves
  at length.
- `docs/guide/07-accounts.md`, which builds a login rather than discussing one.
- `docs/why/adapters.md`, for why `cache` is a capability and not a `require`.
