# Read config from the environment

Declares every setting the service has in one place, reads them from the
environment, and refuses to start when one that matters is missing.

## The whole file

This block is marked `no-run`. What it does depends on the environment it is
started in, and the documentation's test suite has no fixed one, so the suite
checks that it compiles and the two runs below are what it actually does.

```lua no-run
local akkar  = require "akkar"
local config = require "akkar.config"
local db     = require "akkar.db"

local settings = config.load {
  schema = {
    port = { type = "number", default = 3000 },
    request_timeout = { type = "duration", default = "5s" },
    database = {
      host     = { type = "string", default = "127.0.0.1" },
      port     = { type = "number", default = 55432 },
      name     = { type = "string", default = "akkar", env = "PGDATABASE" },
      user     = { type = "string", default = "postgres", env = "PGUSER" },
      password = { type = "string", required = true, secret = true,
                   env = "PGPASSWORD" },
    },
  },
}

local app = akkar.new()

app:get("/config", function()
  -- `redacted` is what makes this safe to answer at all: the password comes
  -- back as "[redacted]" rather than as itself.
  return settings:redacted()
end)

app:run {
  port = settings.port,
  timeout = settings.request_timeout,
  db = db.connect {
    host = settings.database.host,
    port = settings.database.port,
    database = settings.database.name,
    user = settings.database.user,
    password = settings.database.password:reveal(),
    statement_timeout = 5,
  },
}
```

A setting's environment variable name is its path in capitals with dots
turned into underscores, so `port` is `PORT` and `database.host` is
`DATABASE_HOST`. `env = "PGPASSWORD"` overrides that when the variable
already has a name of its own. A `duration` accepts `500ms`, `5s`, `10m` and
gives you seconds.

## Try it

With nothing set:

```sh
lua5.4 app.lua
```

```
lua5.4: app.lua:5: akkar.config: 1 required setting is missing
  database.password -- set PGPASSWORD in the environment, or values.database.password
```

It names the setting, the variable to set, and the other way to supply it.
Now with the variable:

```sh
PGPASSWORD=akkar lua5.4 app.lua
```

```
INFO  listening url=http://127.0.0.1:3000
```

```sh
curl http://127.0.0.1:3000/config
```

```
{"port":3000,"database":{"user":"postgres","host":"127.0.0.1","port":55432,"password":"[redacted]","name":"akkar"},"request_timeout":5}
```

## Why a schema instead of `os.getenv` where it is needed

`os.getenv` scattered through the code has no list, so nothing can tell you
what this service needs until the request that needs it fails, and a typo
reads as nil rather than as a mistake. A schema is that list: every setting is
declared once, missing required values are all reported together at startup
rather than one per restart, `PORT=abc` is refused as not a number, and
reading a setting that was never declared raises instead of quietly being
nil. Marking a value `secret` wraps it so it cannot be printed by accident,
which is why `settings:redacted()` is safe to return from a route and
`password` needs `:reveal()` at the one place that genuinely uses it.
[Page 12](../guide/12-deploying.md) of the guide does the same job with a
hand written `required` helper and no dependency, which is the right amount of
machinery for one or two variables.
