--[[
akkar.migrate — plain SQL files, applied once, in filename order, under a lock.

`docs/BACKLOG.md` listed migrations under "what is deliberately not being
built", permanently, next to ORM and templating. That entry is retracted by
this module and the retraction has an argument behind it: an ORM is a
modelling opinion and akkar refuses opinions about modelling, but a migration
runner holds no opinion about a schema at all. It is a ledger of what has been
applied and a lock so two machines cannot both apply it. `akkar build`
produces a single binary whose whole promise is "copy it to a server", and a
binary that cannot bring its own schema forward has an incomplete promise.

    local migrate = require "akkar.migrate"
    local runner  = migrate.new(db, { dir = "migrations" })

    for _, name in ipairs(runner:apply()) do
      log:info("migrated", { file = name })
    end

## UP ONLY, and this is not laziness

There are no down-migrations here and there will not be. A down-migration is
written against a schema and run against DATA, and the two disagree in the one
direction that matters: `alter table drop column` reverses cleanly on an empty
table and destroys a column's worth of production data on a full one. The
migration that added the column knew what to put there; the one that removes
it does not know what to put back.

The deeper cost is that having a `down` at all encourages the belief that a
deploy is reversible. It usually is not, and a rollback plan that says "run
the down migration" is a plan nobody has tested against real rows. Forward is
the only direction with an honest story: if a migration was wrong, the fix is
another migration that says what should have been said.

## Why this is not a shell script

Everything above -- read a directory, run the files in order, remember which
ones ran -- is thirty lines of `psql` in a loop. The reason it is a module is
the next paragraph.

Two instances of a service start at the same time, which is what every rolling
deploy does on purpose. Both read the ledger, both see the same file pending,
both run it. The lucky outcome is a duplicate-key error on the ledger and one
of them crash-looping; the unlucky one is a migration whose statements are not
themselves unique -- an `insert`, a `update ... set x = x + 1` -- applied
twice with no error anywhere.

So the whole run is wrapped in a Postgres ADVISORY LOCK on a fixed key. The
second instance blocks at the lock, and when it gets in it re-reads the ledger
and finds nothing to do. **The pending list is computed AFTER the lock is
held**, never before; computing it first and then locking gives back exactly
the race the lock was taken to close, and it looks correct while doing it.

The lock is the SESSION-level `pg_advisory_lock`, not the transaction-level
`pg_advisory_xact_lock`, because each migration commits on its own and a
transaction-scoped lock would be dropped at the first COMMIT -- leaving every
migration after the first unprotected. It follows that `migrate` needs a
connection it owns for the whole run: the lock lives on the session, so a
handle that goes back to a pool half-way through takes the lock with it.

## The ledger row is written in the SAME transaction as the migration

This is the defect that makes the next deploy run a migration twice. Apply the
file, commit, then record it: a crash in the gap -- an OOM kill, a lost
connection, a deploy timeout -- leaves the change applied and unrecorded, and
the next boot finds it pending and applies it again. `create table` fails
loudly the second time, which is the good case. An `insert` does not.

Both statements therefore go inside one `db:transaction`, so the database is
either changed and marked, or neither. The consequence is a constraint on what
a migration file may contain, stated here because it is discovered otherwise:

  * No `begin` / `commit` / `rollback` in the file. There is already a
    transaction open around it.
  * Anything Postgres refuses to run inside a transaction cannot go in a file.
    `create index concurrently` is the one people meet first, and there is no
    way to have both it and the atomicity above -- this module chooses the
    atomicity and says so.

## A changed checksum is an ERROR

If a file that was already applied has different bytes today than when it ran,
somebody edited history. The database no longer matches the files, and every
statement anyone makes from here on -- "the schema is what the migrations say"
-- is false. That is not a warning, because a warning is a thing that scrolls
past during a deploy.

The checksum is SHA-256 of the file's exact bytes. `akkar.etag` deliberately
uses a fast non-cryptographic hash and explains why; the trade is different
here. That hash runs on every response and its collisions cost a stale ETag;
this one runs a handful of times at boot and its collisions cost a changed
migration accepted in silence, which is precisely what the check exists to
prevent.

Two sharp edges, stated rather than discovered:

  * The bytes are compared exactly, so a checkout that rewrites line endings
    changes every checksum and every file reads as edited. This module does
    not normalise them -- it cannot tell a line ending inside a string literal
    from one between statements -- so the answer is to keep the working tree's
    line endings stable, not to reach for a flag here.
  * A file that was applied and has since been DELETED from disk is not an
    error. Squashing old migrations away once they are everywhere is an
    ordinary thing to do, and refusing it would make this module the reason
    the directory can never be cleaned.

## Order is filename order, and that is string order

`table.sort` on the names, so `10_x.sql` sorts BEFORE `9_x.sql`. Zero-pad or
timestamp the prefixes. Nothing here can rescue a directory that did not.

A file whose name sorts before one already applied is still applied -- out of
order, after its neighbours. That is what every runner does and it is the
least surprising of the bad options, but it means two branches that merged
badly can produce an order nobody ever tested.
]]

local digest = require "openssl.digest"

local Migrate = {}
Migrate.__index = Migrate

local M = {}

-- The key, fixed, and fixed on purpose. Deriving it from the directory or the
-- ledger name would let two runners in one database miss each other, which is
-- the exact thing the lock is for; a single key means at most one migration
-- run per database at a time, and a run that waits behind an unrelated one
-- has lost nothing but a few seconds at boot.
--
-- The value is the ASCII of "akkar" read as a big-endian integer. It has no
-- meaning to Postgres -- any bigint would do -- but a recognisable one is
-- worth having when someone is reading `pg_locks` at three in the morning and
-- wants to know whose lock this is.
local LOCK_KEY = 0x616b6b6172

local function hex(bytes)
  return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

local function checksum_of(bytes)
  return hex(digest.new("sha256"):final(bytes))
end

-- The ledger's name is the one thing here that reaches SQL as text rather than
-- as a bound parameter, because an identifier cannot be a parameter -- Postgres
-- plans `select * from $1` as nothing at all. So it is checked instead, at
-- construction, against what an unquoted Postgres identifier may contain.
--
-- The value comes from the application's own configuration rather than from a
-- request, so this is not the injection path a handler has; it is checked
-- anyway because "not reachable from outside today" is a property of the
-- calling code, and the calling code is free to change.
local function ledger_name(name)
  if type(name) ~= "string" or #name == 0 or #name > 63
     or not name:match "^[%a_][%w_]*$" then
    error("akkar.migrate: '" .. tostring(name) .. "' is not a usable table " ..
          "name; it goes into SQL as an identifier, which cannot be a bound " ..
          "parameter, so it must be letters, digits and underscores", 3)
  end
  return name
end

-- `find`, for the same reason `akkar.watch` uses it: Lua has no directory
-- listing and LuaFileSystem is a C dependency this project has spent real
-- effort not needing.
--
-- `io.popen` blocks the whole OS process, which would be unacceptable inside a
-- request and is fine here -- migrations run at boot, before the server is
-- listening, and a fork per run is not a budget anybody is counting.
--
-- `-maxdepth 1`: a migrations directory is a flat list of files. Descending
-- would pick up a backup directory, an editor's `.sql~`, or a subdirectory
-- somebody made to "archive" old migrations -- and applying an archive is a
-- worse failure than not finding it.
--- THE SHELL IS NOT ALWAYS THERE, and a deploy found it the hard way.
---
--- `io.popen` needs `/bin/sh`. The single-file binary `akkar build` produces
--- runs happily in a `scratch` container -- two files, no libc, no shell --
--- which is the whole point of the runtime, and in that image this function
--- fails with:
---
---     could not list /migrations: ... No such file or directory
---
--- where the missing file is the SHELL, not the directory. Proven rather than
--- guessed: the same binary against the same mount and the same database
--- applied both migrations from an Alpine image and neither from scratch.
---
--- The fix is not to find another way to read a directory -- there is none in
--- plain Lua, and adding a C dependency to list files would trade the whole
--- point of the small binary for a convenience. The fix is that a deployment
--- which cannot list files should not have to: `migrate.new(db, { files =
--- {...} })` takes the migrations as data, which is what `akkar build` should
--- embed alongside the modules. A directory stays the default because it is
--- what development wants, and development has a shell.
local function shell_available()
  local pipe = io.popen "exit 0"
  if not pipe then return false end
  local ok = pipe:close()
  return ok and true or false
end

local function sql_files(dir)
  local found = {}
  local pipe, why = io.popen(
    ("find %q -maxdepth 1 -type f -name '*.sql' 2>/dev/null"):format(dir))
  if not pipe then
    error("akkar.migrate: could not list " .. dir .. ": " .. tostring(why) ..
          (shell_available() and ""
           or "\n  there is no shell in this image, which is normal for a " ..
              "binary built by `akkar build` and running in a scratch " ..
              "container.\n  pass the migrations as data instead: " ..
              "migrate.new(db, { files = { { name = ..., sql = ... } } })"), 0)
  end
  for path in pipe:lines() do found[#found + 1] = path end
  -- `find` exits non-zero when the directory is not there, and that has to be
  -- told apart from a directory with no files in it. Silently reading a
  -- missing directory as "nothing to migrate" is how a deploy comes up with an
  -- empty schema and no complaint -- a mistyped `dir` would look exactly like
  -- a project that has not written its first migration yet.
  local ok = pipe:close()
  if not ok then
    error("akkar.migrate: cannot read the migration directory '" .. dir ..
          "' -- it does not exist, or is not readable from " ..
          "the working directory" ..
          (shell_available() and ""
           or ".\n  Or -- more likely, since there is no shell here -- this " ..
              "is a scratch container. Pass the migrations as data: " ..
              "migrate.new(db, { files = { { name = ..., sql = ... } } })"), 0)
  end
  return found
end

local function read_file(path)
  local file, why = io.open(path, "rb")
  if not file then
    error("akkar.migrate: cannot read " .. path .. ": " .. tostring(why), 0)
  end
  local contents = file:read "a"
  file:close()
  return contents
end

--- Wraps a database handle with the runner.
---
--- `options.dir` is where the `.sql` files are, `options.table` is the ledger
--- (`akkar_migrations` by default).
---
--- The handle must be a connection this runner can keep for the whole run --
--- see the note on session-level locks in the module docstring. The four
--- methods are checked here rather than at the first query, in the shape
--- `akkar.jobs` uses for stores: a handle that cannot answer the contract
--- should fail while the stack still says who built it.
function M.new(db, options)
  if type(db) ~= "table" then
    error("akkar.migrate: expected a database handle, got " .. type(db), 2)
  end
  for _, method in ipairs { "one", "many", "exec", "transaction" } do
    if type(db[method]) ~= "function" then
      error("akkar.migrate: this is not a database handle; missing :" ..
            method .. ". A connection factory is not a connection -- call " ..
            "it first, and hand the runner the connection it returns", 2)
    end
  end

  options = options or {}

  -- MIGRATIONS AS DATA, for a deployment that cannot list files.
  --
  -- `{ files = { { name = "001_users.sql", sql = "create table ..." } } }`
  -- is the same input a directory produces, handed over directly. It exists
  -- because the binary `akkar build` emits runs in a scratch container with
  -- no shell, where listing a directory is impossible -- see `sql_files`. It
  -- is also the honest shape for a single artefact: a deploy whose schema
  -- travels inside the binary cannot fall out of step with the code, which is
  -- a class of incident a separate migrations directory invites.
  --
  -- Validated here rather than at first use, because the failure otherwise
  -- lands during `apply`, holding a lock, halfway through a deploy.
  local literal
  if options.files ~= nil then
    if type(options.files) ~= "table" then
      error("akkar.migrate: `files` must be a list of { name, sql }, got " ..
            type(options.files), 2)
    end
    if options.dir ~= nil then
      error("akkar.migrate: pass `dir` or `files`, not both -- two sources " ..
            "of migrations is two answers to what has been applied", 2)
    end
    literal = {}
    for index, entry in ipairs(options.files) do
      if type(entry) ~= "table" or type(entry.name) ~= "string"
         or type(entry.sql) ~= "string" then
        error(("akkar.migrate: files[%d] must be { name = string, sql = " ..
               "string }"):format(index), 2)
      end
      literal[#literal + 1] = { name = entry.name, sql = entry.sql }
    end
  end

  return setmetatable({
    db = db,
    dir = options.files and nil or (options.dir or "migrations"),
    literal = literal,
    ledger = ledger_name(options.table or "akkar_migrations"),
  }, Migrate)
end

-- Asking rather than creating, so that `applied` and `pending` stay reads.
-- `create table if not exists` from two connections at once can raise a
-- duplicate-key error out of the system catalogue, so the only place that
-- creates the ledger is `apply`, which holds the lock by then.
function Migrate:_ledger_exists()
  local row = self.db:one("select to_regclass($1) is not null as present",
                          self.ledger)
  return row ~= nil and row.present == true
end

function Migrate:_ensure_ledger()
  self.db:exec("create table if not exists " .. self.ledger .. [[ (
    name text primary key,
    checksum text not null,
    applied_at timestamptz not null default now()
  )]])
end

--- Every `.sql` file in the directory, in the order they will be applied.
---
--- Each entry is `{ name, path, sql, checksum }`.
function Migrate:files()
  local out = {}

  -- The data path. Checksummed identically, so a migration embedded in a
  -- binary and the same migration read from disk produce the same ledger row
  -- -- otherwise moving from a directory to an embedded list would look like
  -- every migration had been edited.
  if self.literal then
    for _, entry in ipairs(self.literal) do
      out[#out + 1] = {
        name = entry.name, path = nil, sql = entry.sql,
        checksum = checksum_of(entry.sql),
      }
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
  end

  for _, path in ipairs(sql_files(self.dir)) do
    local sql = read_file(path)
    out[#out + 1] = {
      name = path:match "([^/]+)$",
      path = path,
      sql = sql,
      checksum = checksum_of(sql),
    }
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

--- What the ledger says has run, oldest name first.
---
--- Empty on a database that has never been migrated, rather than an error
--- about a missing table: "nothing has been applied" is the true answer there
--- and it is the one a status command wants.
function Migrate:applied()
  if not self:_ledger_exists() then return {} end
  return self.db:many(
    "select name, checksum, applied_at from " .. self.ledger .. " order by name")
end

--- What has not run yet, in the order it will run.
---
--- RAISES if a file that already ran has different bytes now. See the module
--- docstring: this is the check that keeps "the schema is what the migrations
--- say" from quietly becoming false, and downgrading it to a warning would put
--- that sentence in a log line nobody reads during a deploy.
function Migrate:pending()
  local recorded = {}
  for _, row in ipairs(self:applied()) do recorded[row.name] = row.checksum end

  local out = {}
  for _, file in ipairs(self:files()) do
    local before = recorded[file.name]
    if before == nil then
      out[#out + 1] = file
    elseif before ~= file.checksum then
      error("akkar.migrate: '" .. file.name .. "' has changed since it was " ..
            "applied (ledger " .. before .. ", file " .. file.checksum ..
            ") -- the database no longer matches the files. Restore the file, " ..
            "or write a new migration for whatever the edit was trying to say",
            2)
    end
  end
  return out
end

--- Applies everything pending and returns the file names it applied, in order.
---
--- Returns an empty list when there was nothing to do, which is the ordinary
--- case on every boot after the first.
---
--- Raises on the first migration that fails. That one is rolled back and NOT
--- recorded, and the ones after it are not attempted: a schema half-way
--- through a change nobody described is worse than a schema that stopped at a
--- known point, and stopping leaves the ledger an honest account of where the
--- database actually is.
function Migrate:apply()
  -- Blocks until it is ours. That is the intended behaviour and it is worth
  -- being explicit about, because it means a boot can WAIT here: an instance
  -- that hangs at the lock is an instance whose predecessor is still applying,
  -- and waiting is what we want it to do.
  --
  -- One interaction to know about, from reading `akkar/db.lua`: that adapter
  -- sets `statement_timeout` on the connection when the config asks for one,
  -- and it is a session setting rather than a per-query one. Postgres counts
  -- the wait for an advisory lock against `statement_timeout`, so a connection
  -- configured with a request-sized timeout will cancel this wait -- and will
  -- cancel a long migration too. Hand `migrate` a connection opened without
  -- one.
  self.db:one("select pg_advisory_lock($1)", LOCK_KEY)

  local ok, result = pcall(function()
    -- Under the lock, both of them. Creating the ledger here is what keeps two
    -- simultaneous first boots from racing inside the system catalogue, and
    -- reading `pending` here rather than before the lock is the whole point of
    -- taking it -- a list computed first and applied second is a list that can
    -- already be stale by the time it is used.
    self:_ensure_ledger()

    local applied = {}
    for _, file in ipairs(self:pending()) do
      self.db:transaction(function(tx)
        tx:exec(file.sql)
        -- The same transaction, and this line is the module's reason for
        -- existing as much as the lock is. A crash between the change and its
        -- ledger row leaves the change applied and unrecorded, and the next
        -- boot applies it again.
        tx:exec("insert into " .. self.ledger ..
                " (name, checksum) values ($1, $2)", file.name, file.checksum)
      end)
      applied[#applied + 1] = file.name
    end
    return applied
  end)

  -- Released on both paths, and released before the error is re-raised. A
  -- failed migration that kept the lock would leave every other instance
  -- blocked at boot behind a run that is already over -- turning one bad
  -- migration into an outage of the whole fleet, from the code that was
  -- supposed to be making startup safer.
  local unlocked, why = pcall(function()
    return self.db:one("select pg_advisory_unlock($1) as released", LOCK_KEY)
  end)

  if not ok then error(result, 0) end
  if not unlocked then
    error("akkar.migrate: the migrations applied but the advisory lock could " ..
          "not be released: " .. tostring(why) .. ". The lock is session " ..
          "scoped, so closing this connection clears it", 0)
  end
  return result
end

M.LOCK_KEY = LOCK_KEY
M.checksum_of = checksum_of
M.Migrate = Migrate
return M
