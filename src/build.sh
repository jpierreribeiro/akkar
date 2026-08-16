#!/usr/bin/env bash
#
# Builds `akkar.pq_native` — the C half of the Postgres driver.
#
# NOT part of `luarocks install akkar`, deliberately. Making libpq a hard
# dependency would break the install for everyone who does not use Postgres,
# and the driver is opt-in: `akkar/pq.lua` is the only thing that requires it,
# and `akkar/db.lua` still goes through pgmoon. Wiring it into the adapter is a
# separate decision with a separate measurement behind it.
#
#   ./src/build.sh              # build into akkar/pq_native.so
#   PQ_INC=... PQ_LIB=... ./src/build.sh
#
# NO ROOT REQUIRED, and the reason is written down because it took a detour to
# find. `libpq-dev` supplies the header; if you cannot install it, fetch the
# package and unpack it into a directory of your own:
#
#   apt-get download libpq-dev
#   dpkg -x libpq-dev_*.deb /tmp/libpq
#   PQ_INC=/tmp/libpq/usr/include/postgresql ./src/build.sh
#
# The RUNTIME comes from the system's already-installed `libpq.so.5`, which
# anything speaking to Postgres already has. Only the header was missing.
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)

# Where the header lives. `pg_config` knows if it is installed.
PQ_INC=${PQ_INC:-$(pg_config --includedir 2>/dev/null || echo /usr/include/postgresql)}
if [ ! -f "$PQ_INC/libpq-fe.h" ]; then
  echo "libpq-fe.h not found under $PQ_INC" >&2
  echo "install libpq-dev, or set PQ_INC -- see the header of this script" >&2
  exit 1
fi

# What to link against. A versioned .so is fine and is what a system without
# the dev package has; the unversioned symlink only ships with libpq-dev.
if [ "${PQ_LIB:-}" = "" ]; then
  for candidate in \
    "$(pg_config --libdir 2>/dev/null)/libpq.so" \
    /usr/lib/*/libpq.so.5 /usr/lib/libpq.so.5 /usr/local/lib/libpq.so.5
  do
    if [ -e "$candidate" ]; then PQ_LIB=$candidate; break; fi
  done
fi
if [ "${PQ_LIB:-}" = "" ] || [ ! -e "$PQ_LIB" ]; then
  echo "no libpq runtime found; set PQ_LIB to your libpq.so" >&2
  exit 1
fi

LUA_CFLAGS=${LUA_CFLAGS:-$(pkg-config --cflags lua5.4 2>/dev/null || echo -I/usr/include/lua5.4)}
OUT=${OUT:-$here/akkar/pq_native.so}

# -Wall -Wextra because this is the first C in the project and the whole
# concern about owning C is that it becomes a segfault factory. Warnings are
# the cheapest part of not becoming one.
${CC:-gcc} -O2 -fPIC -shared -Wall -Wextra \
  $LUA_CFLAGS -I"$PQ_INC" \
  -o "$OUT" "$here/src/akkar_pq.c" "$PQ_LIB"

echo "built $OUT"
echo "  header : $PQ_INC/libpq-fe.h"
echo "  runtime: $PQ_LIB"
echo
echo "check it: lua5.4 -e 'package.cpath=\"./?.so;\"..package.cpath;" \
     "print(require\"akkar.pq_native\".VERSION)'"
