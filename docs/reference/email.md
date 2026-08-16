# akkar.email

Sends mail through a provider's HTTP API. A transport is a function that takes
a normalised message; one is supplied for the JSON shape that Resend, Postmark,
Loops, Plunk and several others already have.

**When you need it.** Your application has to send a welcome email, a password
reset or a receipt, and there is a provider account behind it. Sending goes on
whatever the application already uses for work that must not fail the request,
which is usually `akkar.jobs`.

```lua no-run
local email = require "akkar.email"
```

## A failed send is a returned value, always

Nothing in this module raises on a send. Not on a bad argument, not on a
transport that throws, not on a provider returning a document nobody expected.
`Mailer:send` answers `id, nil, details` or `nil, reason, details`, and the
transport runs inside a `pcall` so that a third party function that raises
comes back as the same returned error as everything else.

The corollary is that ignoring the result is silent. `Mailer:send_or_log`
exists for the common case.

The two constructors do raise, on purpose. They run once, from configuration
code, and a missing URL is a deployment that should refuse to start rather than
a request that fails at three in the morning.

## Index

Every public symbol on this page, in alphabetical order.

| symbol | kind |
|---|---|
| [`email.Mailer`](#emailmailer) | metatable |
| [`email.address_list`](#emailaddress_listvalue) | function |
| [`email.connect`](#emailconnectconfig) | function |
| [`email.json_api`](#emailjson_apiconfig) | transport |
| [`email.new`](#emailnewconfig) | function |
| [`email.plausible`](#emailplausibleaddress) | function |
| [`email.resend`](#emailresendconfig) | transport |
| [`email.validate`](#emailvalidatemessage-defaults) | function |
| [`Mailer:send`](#mailersendmessage) | method |
| [`Mailer:send_or_log`](#mailersend_or_logmessage-log) | method |

## email.Mailer

The metatable `email.new` sets, exported so a caller can extend it. `__index`
is itself.

## email.address_list(value)

One address or many, always as a list of strings.

**Returns** a list, or `nil` when the value cannot be one: it is not a string
and not a table, it is a table containing a non-string, or it is a table that
produced no entries. `nil` in gives `nil` out.

Accepting both is not sugar. `to = "a@b.c"` is what a caller writes nine times
in ten.

```lua
local email = require "akkar.email"

assert(email.address_list("a@b.c")[1] == "a@b.c")
assert(#email.address_list { "a@b.c", "d@e.f" } == 2)
assert(email.address_list(nil) == nil)
assert(email.address_list {} == nil)
assert(email.address_list { 42 } == nil)
assert(email.address_list(42) == nil)
```

## email.connect(config)

`email.new`, wrapped in a factory, so this reads the same as `db.connect` and
`http.connect` where it is wired as a capability.

**Returns** a function of no arguments that answers the same mailer every time.

**Raises** whatever `email.new` raises.

```lua
local email = require "akkar.email"

local connect = email.connect {
  from = "hello@example.com",
  transport = function() return "id_1" end,
}
local mailer = connect()
assert(connect() == mailer)
assert(mailer:send { to = "ada@example.com", subject = "Hi", text = "there" }
       == "id_1")
```

## email.json_api(config)

A transport for the shape most JSON email APIs have: POST a JSON object to one
URL with a bearer token, get an object with an id back.

| field | type | default | meaning |
|---|---|---|---|
| `url` | string | required | where the POST goes |
| `token` | string | none | the credential. Nothing is sent when it is absent |
| `token_header` | string | `"authorization"` | which header the token goes in |
| `token_prefix` | string | `"Bearer "` | prefixed to the token. The trailing space is part of it |
| `headers` | table | `{}` | copied onto every request before the token |
| `fields` | table | `{}` | renames body fields: `[canonical name] = provider's name` |
| `extra` | table | `{}` | copied into every body after the message's own fields |
| `idempotency_header` | string | `"idempotency-key"` | where a message's `idempotency_key` goes |
| `http` | client | a new one | an already connected `akkar.http` client |
| `timeout` | number | `15` | seconds, used only when building the default client |

The default client is built with `retries = 0`. `akkar.http` already refuses to
retry a POST; this states the intent at the one call site where a duplicate is
a duplicate email in somebody's inbox.

The body carries `from`, `to` and `subject` always, and `text`, `html`, `cc`,
`bcc`, `reply_to`, `headers` and `tags` when the message has them. Each name
goes through `fields`. `extra` is applied last, so it wins over all of them.

**Returns** a transport function. It answers:

| answer | when |
|---|---|
| `nil, why` | the client could not make the request |
| `nil, "the email provider refused it (<status>): <said>", { status, body, decoded }` | a non-2xx. `said` is the decoded `message`, `error` or `Message`, falling back to the raw body |
| `<id>, nil, { status, decoded }` | a 2xx with a decodable `id`, `MessageID` or `message_id` |
| `true, nil, { status, decoded }` | a 2xx with no id in it. The send succeeded, and `nil` would make success indistinguishable from failure |

**Raises** `akkar.email: a transport needs a url` when `url` is missing. This
happens at construction, not at send time.

A provider that does not fit is not a problem this needs to solve. A transport
is a function, so an unusual one is fifteen lines in the application.

```lua
local email = require "akkar.email"

-- An akkar.http client stands in here, so nothing leaves the process.
local seen = {}
local fake = {
  post = function(_, url, options)
    seen.url, seen.headers, seen.body = url, options.headers, options.body
    return { status = 200, body = '{"id":"re_abc"}' }
  end,
}

local transport = email.json_api {
  url = "https://api.example.com/emails",
  token = "a-secret",
  http = fake,
  fields = { text = "TextBody" },
}

local mailer = email.new { transport = transport, from = "hello@example.com" }
local id, why = mailer:send {
  to = "ada@example.com", subject = "Welcome", text = "Glad you are here.",
}

assert(id == "re_abc", why)
assert(seen.url == "https://api.example.com/emails")
assert(seen.headers.authorization == "Bearer a-secret")
assert(seen.body.TextBody == "Glad you are here.")
assert(seen.body.to[1] == "ada@example.com")
```

## email.new(config)

Builds a mailer.

| field | type | default | meaning |
|---|---|---|---|
| `transport` | function | required | called with a normalised message |
| `from` | string | none | the default `from` for every message |
| `reply_to` | string | none | the default `reply_to` for every message |

**Returns** the mailer itself, not a factory, despite what the docstring above
it in the source says. `email.connect` is the one that returns a factory.

**Raises** `akkar.email: a transport function is required` when `transport` is
missing or is not a function.

```lua
local email = require "akkar.email"

local sent = {}
local mailer = email.new {
  from = "hello@example.com",
  reply_to = "support@example.com",
  transport = function(message)
    sent[#sent + 1] = message
    return "msg_1"
  end,
}

assert(mailer:send { to = "ada@example.com", subject = "Hi", text = "there" }
       == "msg_1")
assert(sent[1].from == "hello@example.com")
assert(sent[1].reply_to == "support@example.com")

local ok, why = pcall(email.new, { from = "a@b.c" })
assert(ok == false)
assert(why:find("a transport function is required", 1, true))
```

## email.plausible(address)

A very loose sanity check.

**Returns** `true` when the address has an `@` at position 2 or later, that `@`
is not the last character, and there is no whitespace anywhere in it. `false`
otherwise.

Loose on purpose. Validating properly means RFC 5322, and every email regex on
the internet gets it wrong in the direction of rejecting valid addresses, which
means a real user cannot sign up. That is far worse than sending one message
that bounces, so this catches only the shapes that cannot possibly be an
address and the provider decides the rest.

```lua
local email = require "akkar.email"

assert(email.plausible "ada@example.com" == true)
assert(email.plausible "a@b" == true)             -- deliberately permitted
assert(email.plausible "nope" == false)
assert(email.plausible "@example.com" == false)   -- nothing before the @
assert(email.plausible "ada@" == false)
assert(email.plausible "ada @example.com" == false)
```

## email.resend(config)

Resend, pre-wired. One concrete provider, so the interface has a worked example
and nobody has to guess the field names.

| field | type | default | meaning |
|---|---|---|---|
| `api_key` | string | required | becomes the bearer token |
| `url` | string | `"https://api.resend.com/emails"` | |
| `http` | client | a new one | passed through to `email.json_api` |
| `timeout` | number | `15` | passed through |

**Returns** a transport function, the same as `email.json_api`.

**Raises** `akkar.email: resend needs an api_key` when the key is missing.

```lua
local email = require "akkar.email"

-- No network: a stand-in client, so the transport is built and exercised
-- without a Resend account.
local fake = {
  post = function() return { status = 200, body = '{"id":"re_1"}' } end,
}
local transport = email.resend { api_key = "re_test_key", http = fake }
local mailer = email.new { transport = transport, from = "hello@example.com" }

assert(mailer:send { to = "ada@example.com", subject = "Hi", text = "there" }
       == "re_1")

local ok, why = pcall(email.resend, {})
assert(ok == false)
assert(why:find("resend needs an api_key", 1, true))
```

## email.validate(message, defaults)

Checks a message and returns it normalised. Called by `Mailer:send`, and
exported so a caller can check a message before queueing it.

`defaults` supplies `from` and `reply_to` where the message has none.

**Returns** the normalised message, or `nil` and a reason:

| reason | when |
|---|---|
| `a message must be a table` | `message` is not a table |
| `a message needs at least one `to` address` | `address_list(message.to)` answered `nil` |
| `not an email address: <address>` | any `to` address fails `email.plausible` |
| `a message needs a `from` address` | neither the message nor `defaults` has a non-empty string |
| `a message needs a `subject`` | missing, not a string, or empty |
| `a message needs `text`, `html`, or both` | both are `nil`. A message with neither is an empty email, which some providers accept silently |

Only the `to` addresses are checked for plausibility. `cc`, `bcc`, `from` and
`reply_to` are not.

**Raises** nothing.

```lua
local email = require "akkar.email"

local valid = email.validate({
  to = "ada@example.com", subject = "Hi", html = "<p>there</p>",
}, { from = "hello@example.com" })

assert(valid.to[1] == "ada@example.com")
assert(valid.from == "hello@example.com")
assert(valid.text == nil)

assert(select(2, email.validate { subject = "Hi", text = "x" })
       == "a message needs at least one `to` address")
assert(select(2, email.validate({ to = "a@b.c", subject = "Hi" }, { from = "x@y.z" }))
       == "a message needs `text`, `html`, or both")
assert(select(2, email.validate({ to = "nope", subject = "Hi", text = "x" }, { from = "x@y.z" }))
       == "not an email address: nope")
```

## Mailer

What `email.new(config)` returns.

### Mailer:send(message)

Validates and sends.

**Returns** `id, nil, details` on success and `nil, reason, details` on
failure. `details` is whatever the transport returned in its third position,
and is `nil` when validation failed or when the transport raised.

| answer | when |
|---|---|
| `nil, <validation reason>` | `email.validate` refused. No `details` |
| `nil, "the email transport raised: <error>"` | the transport raised. No `details` |
| `nil, <transport reason>, <details>` | the transport answered a falsy first value. The reason falls back to `the email was not sent` |
| `<id>, nil, <details>` | anything else the transport returned |

**Raises** nothing, ever. A welcome email failing must not un-create the
account.

```lua
local email = require "akkar.email"

local raising = email.new {
  from = "hello@example.com",
  transport = function() error "the provider SDK blew up" end,
}
local id, why = raising:send { to = "a@b.c", subject = "Hi", text = "x" }
assert(id == nil)
assert(why:find("the email transport raised:", 1, true) == 1)

local refusing = email.new {
  from = "hello@example.com",
  transport = function() return nil end,
}
assert(select(2, refusing:send { to = "a@b.c", subject = "Hi", text = "x" })
       == "the email was not sent")
```

### Mailer:send_or_log(message, log)

The same send, with the failure already logged. `log` is anything with a
`warn` method; nothing is logged when it is absent.

The log line is `email failed`, with fields `reason`, `to` (the message's own
`to`, before normalisation) and `status` (from `details`, so `nil` unless the
transport supplied one).

**Returns** `id, why`. Two values, not the three `Mailer:send` returns:
`details` is dropped.

```lua
local email = require "akkar.email"

local warned = {}
local log = { warn = function(_, message, fields)
  warned[#warned + 1] = { message = message, fields = fields }
end }

local mailer = email.new {
  from = "hello@example.com",
  transport = function() return nil, "the provider is down" end,
}

local id, why = mailer:send_or_log({
  to = "ada@example.com", subject = "Hi", text = "x",
}, log)

assert(id == nil)
assert(why == "the provider is down")
assert(warned[1].message == "email failed")
assert(warned[1].fields.reason == "the provider is down")
assert(warned[1].fields.to == "ada@example.com")
```

## The message

What `Mailer:send` accepts, and what a transport is handed after
normalisation.

| field | type | required | notes |
|---|---|---|---|
| `to` | string or list | yes | always a list by the time a transport sees it |
| `from` | string | yes, or a default on the mailer | |
| `subject` | string | yes, non-empty | |
| `text` | string | one of `text` and `html` | |
| `html` | string | one of `text` and `html` | |
| `cc` | string or list | no | a list, or `nil`, after normalisation |
| `bcc` | string or list | no | the same |
| `reply_to` | string | no | falls back to the mailer's default |
| `headers` | table | no | passed through to the transport untouched |
| `tags` | anything | no | passed through untouched |
| `idempotency_key` | string | no | passed through. `email.json_api` puts it in a header |

Nothing else survives normalisation. A field the transport needs that is not in
this list has to reach it another way, such as `email.json_api`'s `extra`.

## Not here

**SMTP.** Deliberately. ESMTP negotiation, STARTTLS, AUTH in three mechanisms,
dot-stuffing, MIME assembly and RFC 5322 address parsing, and none of it gets
mail delivered without SPF, DKIM and a warmed sending IP. If it is ever wanted
it belongs in `akkar/smtp.lua` as a transport this module can be handed. The
seam is already here.

**Retries.** A send that times out may have been delivered, and there is no way
to tell from here. A caller that wants a retry has to say so with the
provider's own `idempotency_key`, which is the only mechanism that can make it
safe.

**Attachments.** No field for them, and nothing is passed through that could
carry one except a transport-specific `extra`.

**Templates.** The message carries `text` and `html` as strings.

**A built-in fake for testing.** A transport is a function, so a test writes
`transport = function(message) recorded = message return "id" end` and needs
nothing from this module. Every example on this page does exactly that.

## See also

- [akkar.http](http.md), whose client `email.json_api` uses and accepts
- [akkar.jobs](jobs.md), which is where a retry queue belongs
- `spec/email_spec.lua`
- the module source, `akkar/email.lua`, for why a failed send is a returned
  value
