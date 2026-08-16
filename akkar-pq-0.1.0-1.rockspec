rockspec_format = "3.0"
package = "akkar-pq"
version = "0.1.0-1"

-- WHY THIS IS A SEPARATE ROCK, and not a module in `akkar`.
--
-- `akkar.pq` -- the Lua half of the Postgres driver -- ships with akkar and
-- costs nothing to carry. Its C half links against libpq, and declaring that
-- in the main rockspec would make libpq a hard dependency of
-- `luarocks install akkar`, breaking the install for everyone who does not
-- use Postgres at all.
--
-- Leaving it out entirely had a cost of its own, and this rock exists because
-- of it: `db.connect { driver = "pq" }` was a real flag that no installed copy
-- of akkar could satisfy. The Lua half was there, the C half was not, and the
-- only way to get it was to clone the repository and run `src/build.sh`. A
-- flag that needs a git clone is not a flag.
--
--     luarocks install akkar-pq
--
-- and then the flag means what it says.
source = {
  url = "git+https://github.com/jpierreribeiro/akkar.git",
  tag = "v0.1.0",
}

description = {
  summary  = "The C Postgres driver for akkar, built on libpq",
  detailed = [[
    `akkar.pq_native` is the C half of akkar's Postgres driver. The C speaks
    the protocol and materialises rows; it never waits. Waiting happens in
    Lua, through `cqueues.poll`, so a query in flight does not block the event
    loop and the concurrency model of the framework is unchanged.

    Install it and pass `driver = "pq"` to `akkar.db.connect`. Everything
    above the adapter boundary -- the pool, the transaction, the scope wrapper
    -- never learns which driver is underneath.

    It is opt-in on purpose. Measured against pgmoon through HTTP on a
    reserved machine it is 1.27x on a single row and 2.79x on a thousand, with
    p99 under saturation falling from 1.3s to 475ms. It is also measurably
    less consistent, which is why pgmoon remains akkar's default. Both
    measurements, and the open question about the inconsistency, are in
    `bench/driver/RESULTS.md`.
  ]],
  homepage = "https://github.com/jpierreribeiro/akkar",
  license  = "MIT",
}

dependencies = {
  "lua >= 5.4, < 5.6",
  -- The Lua half lives in akkar and is what applications actually call. This
  -- rock is useless without it, and pinning the minor keeps a C module from
  -- being paired with a Lua half whose contract has moved.
  "akkar >= 0.1.0, < 0.2.0",
}

-- libpq, found rather than assumed.
--
-- `libpq-fe.h` is NOT in a default include path on Debian and Ubuntu -- it
-- lands in `/usr/include/postgresql` -- so luarocks will usually need to be
-- told. The error it prints when it cannot find the header names the variable,
-- and `docs/reference/db.md` gives the invocation:
--
--     luarocks install akkar-pq PQ_INCDIR=$(pg_config --includedir)
external_dependencies = {
  PQ = {
    header  = "libpq-fe.h",
    library = "pq",
  },
}

build = {
  type = "builtin",
  modules = {
    ["akkar.pq_native"] = {
      sources   = { "src/akkar_pq.c" },
      libraries = { "pq" },
      incdirs   = { "$(PQ_INCDIR)" },
      libdirs   = { "$(PQ_LIBDIR)" },
    },
  },
}
