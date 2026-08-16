# akkar.config

Typed configuration read from a table and from the environment, checked once
at startup. A value declared `secret = true` is stored in a wrapper that holds
nothing, so printing, logging or JSON-encoding the configuration cannot leak
it.

**When you need it.** A service that reads a database URL, a session secret
and a few timeouts from its environment, and should refuse to start when one
of them is missing rather than discover it on the first request.

```lua no-run
local config = require "akkar.config"
```

## Contents

- [config.is_secret(value)](#configis_secretvalue)
- [config.load(options)](#configloadoptions)
- [config.REDACTED](#configredacted)
- [config.secret(value)](#configsecretvalue)
- [The schema](#the-schema)
- [Where a value comes from](#where-a-value-comes-from)
- [Config](#config)
  - [config:redacted()](#configredacted-1)
  - [tostring(config)](#tostringconfig)
- [Secret](#secret)
  - [secret:reveal()](#secretreveal)
- [Not here](#not-here)

## config.is_secret(value)

Whether `value` is a secret wrapper. For a logger or a serialiser that wants
to write the word rather than an empty object.

**Returns** `true` or `false`.

```lua
local config = require "akkar.config"

print(config.is_secret(config.secret "abc"))   --> true
print(config.is_secret "abc")                  --> false
```

## config.load(options)

Reads the configuration, or raises. Every leaf in the schema is coerced to its
declared type, and every missing required value is reported at once.

| field | type | default | meaning |
|---|---|---|---|
| `schema` | table | none, required | the shape. See [The schema](#the-schema). |
| `values` | table | `{}` | values from a file or a literal, in the same shape as the schema. |
| `env` | table | the real environment | where environment lookups go. Pass a plain table to test without setting variables. |

**Returns** a sealed config table. Reading a declared key that was never set
gives `nil`; reading an undeclared key raises.

**Raises**, all with the prefix `akkar.config:`

| when | message |
|---|---|
| an option other than `schema`, `values` or `env` | `unknown option '<key>'; use schema, values or env` |
| `schema` is not a table | `load needs a schema` |
| a leaf declares an option outside `type`, `default`, `required`, `secret`, `env` | `<path> declares unknown option '<key>'; use type, default, required, secret or env` |
| a leaf has a `type` outside the four | `<path> has unknown type "<name>" -- use string, number, boolean or duration` |
| a schema entry is not a table | `<path> must be a table -- either a section or a declaration with a \`type\`` |
| `values` holds a key the schema does not declare | `unknown setting '<path>'`, plus `; did you mean '<near>'?` when one is close |
| a section's value is not a table | `<path> is a section, so its value must be a table, got <type>` |
| a value does not coerce | see [The schema](#the-schema) for the message per type |
| a required value is absent | `<n> required setting(s) missing`, then one line per setting naming the variable to set |

```lua
local config = require "akkar.config"

local settings = config.load {
  schema = {
    port     = { type = "number",   default = 8080 },
    timeout  = { type = "duration", default = "30s" },
    database = {
      url      = { type = "string", required = true },
      password = { type = "string", required = true, secret = true },
    },
  },
  values = { port = 3000 },
  env    = { DATABASE_URL = "postgres://localhost/akkar",
             DATABASE_PASSWORD = "hunter2" },
}

print(settings.port)                     --> 3000
print(settings.timeout)                  --> 30
print(settings.database.url)             --> postgres://localhost/akkar
print(settings.database.password)        --> [redacted]
print(settings.database.password:reveal())
```

## config.REDACTED

The string `"[redacted]"`. What a secret renders as, exported so a caller can
compare against it instead of repeating the literal.

## config.secret(value)

Wraps a value that did not come from a schema, such as a token minted at
runtime, in the same wrapper a `secret = true` leaf gets.

**Returns** a secret.

```lua
local config = require "akkar.config"

local token = config.secret "a-token-minted-at-runtime"

print(tostring(token))               --> [redacted]
print("bearer " .. token)            --> bearer [redacted]
print(config.is_secret(token))       --> true
print(config.is_secret "plain")      --> false
print(config.REDACTED)               --> [redacted]
print(token:reveal())                --> a-token-minted-at-runtime
```

## The schema

A schema is a table of sections and leaves. A table with a string `type` field
is a leaf; any other table is a section, and sections nest to any depth.

A leaf takes these keys and no others.

| key | type | default | meaning |
|---|---|---|---|
| `type` | string | none, required | `string`, `number`, `boolean` or `duration` |
| `default` | any | none | used when neither the environment nor `values` supplies one |
| `required` | boolean | `false` | absence is a startup failure |
| `secret` | boolean | `false` | store the value in a wrapper that prints as `[redacted]` |
| `env` | string or `false` | derived from the path | the variable to read. `false` means never read the environment for this leaf. |

The four types, and what each accepts.

| type | accepts | result | message when it does not |
|---|---|---|---|
| `string` | a string only. A number is not coerced. | the string | `<path> must be a string, got <type>` |
| `number` | a number, or a string `tonumber` accepts | a number | `<path> must be a number, got "<raw>"` |
| `boolean` | a boolean, or `true`/`1`/`yes`/`on` and `false`/`0`/`no`/`off`, any case | a boolean | `<path> is not a boolean: "<raw>" -- use true/false, 1/0, yes/no or on/off` |
| `duration` | a number, or a string with a unit: `ms`, `s`, `m`, `h`, `d`. A bare number is seconds. | **seconds**, always a number | `<path> is not a duration: "<raw>" -- write 500ms, 30s, 5m, 2h or 1d`, or `<path> has unknown duration unit "<unit>" -- use ms, s, m, h or d` |

The message names the setting and, when the value came from the environment,
the variable it came from:

```
akkar.config: database.port (from PGPORT) must be a number, got "abc"
```

```lua no-run
{
  port    = { type = "number", default = 8080 },
  timeout = { type = "duration", default = "500ms" },   -- reads back as 0.5
  db      = {
    url      = { type = "string", required = true, env = "PGURL" },
    password = { type = "string", required = true, secret = true },
    debug    = { type = "boolean", default = false, env = false },
  },
}
```

## Where a value comes from

Precedence is **environment, then `values`, then `default`**. The environment
wins because `values` is what is checked into the repository and the
environment is what the deploy sets.

The variable name is the path, with dots replaced by underscores and upcased:
`database.url` reads `DATABASE_URL`, and `db.pool.size` reads `DB_POOL_SIZE`.
An explicit `env = "PGURL"` replaces the derivation. `env = false` means the
leaf never reads the environment.

A required value that is absent everywhere is collected rather than raised on
the spot, so one failure lists all of them:

```
akkar.config: 2 required settings are missing
  database.password -- set DATABASE_PASSWORD in the environment, or values.database.password
  database.url -- set DATABASE_URL in the environment, or values.database.url
```

## Config

The value `config.load` returns. Sections are configs too, with the same
methods.

Reading an undeclared key raises
`akkar.config: no such setting '<key>'`, with `; did you mean '<near>'?`
when a declared key is close. Assigning a key that is not already present
raises `akkar.config: configuration is read-only; '<key>' is not a setting and
cannot be added after load`. Assigning over a key that IS present is not
caught: Lua offers no write barrier there.

### config:redacted()

A plain table of the same shape with the string `"[redacted]"` in place of
every secret. Sections are converted recursively.

Encoding the config itself is already safe, because the wrapper contains
nothing. This is for when the word is wanted in the output rather than `{}`.

**Returns** a table.

```lua
local config = require "akkar.config"
local json   = require "akkar.json"

local settings = config.load {
  schema = { token = { type = "string", required = true, secret = true } },
  values = { token = "s3cret" },
  env    = {},
}

print(json.encode(settings))              -- the wrapper is empty
print(json.encode(settings:redacted()))   -- the word instead
print(tostring(settings))
```

```
{"token":{}}
{"token":"[redacted]"}
akkar.config
  token = [redacted]
```

### tostring(config)

Every declared setting, one per line, sorted, with nested sections written as
dotted paths and secrets shown as `[redacted]`. A setting that was never set
reads `<unset>`. The first line is `akkar.config`.

## Secret

The wrapper a `secret = true` leaf holds, and what `config.secret` returns. It
is an empty table: the value lives in a private weak-keyed store outside it.

| operation | result |
|---|---|
| `tostring(secret)` | `[redacted]` |
| `string.format("%s", secret)` | `[redacted]` |
| `"url=" .. secret` | `url=[redacted]` |
| `json.encode(secret)` | `{}`, because a JSON encoder consults no metamethod |
| `getmetatable(secret)` | the string `akkar.config: secret` |
| `secret.field = 1` | raises `akkar.config: a secret is immutable` |

The defence is against printing a table, which is how secrets actually escape.
`debug.getmetatable` and `debug.getupvalue` still reach the value, and nothing
in Lua stops them.

### secret:reveal()

The real value.

A method rather than a field so that reading a secret is something written on
purpose and a reviewer can grep for.

**Returns** the wrapped value.

## Not here

- **File parsing.** `values` is a Lua table. Reading YAML, TOML or JSON off
  disk and handing over the result is the caller's job.
- **Reloading.** A config is read once. There is no watch and no reload.
- **Encryption or a secret manager.** A secret is protected from being
  printed, not from being read by the process that holds it.
- **Validation beyond the four types.** No ranges, no enums, no patterns.
- **A command line surface.** There is no `akkar config` subcommand; the only
  external input is the environment.

## See also

- [akkar.doctor](doctor.md) for checking what a running configuration
  actually resolved to
- [akkar.log](log.md) for `logger:info("boot", { config = config:redacted() })`
- the module source, `akkar/config.lua`, for why the secret wrapper is empty
  rather than clever
