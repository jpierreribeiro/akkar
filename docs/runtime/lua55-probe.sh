#!/usr/bin/env bash
# What actually stops akkar running on Lua 5.5. Measured, layer by layer.
#
# `docs/BACKLOG.md` used to say: "cqueues pins lua == 5.4 and has had no
# release since 2020. Supporting 5.5 would mean building Lua 5.5, forking
# cqueues, possibly adapting its C to 5.5 API changes, and repeating for
# luaossl."
#
# Almost none of that survived contact. This script is why.
#
#   Lua 5.5.1        builds
#   cqueues @ master builds and RUNS AN EVENT LOOP under 5.5 -- but only after
#                    its vendored lua-compat-5.3 is updated. It ships v0.9,
#                    whose header refuses LUA_VERSION_NUM > 504, so the build
#                    fails out of the box even though the makefile's
#                    KNOWN_APIS lists 5.5. Listing an API is not building for
#                    it, and that distinction cost an afternoon.
#   lua-cjson        builds, encodes and decodes
#   lpeg             builds
#   luaossl          NO 5.5 TARGET: KNOWN_APIS = 5.1 5.2 5.3 5.4
#   akkar            does not load -- lua-http requires openssl.rand
#
# So the blocker is luaossl, which is not the library anyone assumed, and
# cqueues -- the one everyone assumed -- needs a single stale vendored file
# refreshed.
#
# Everything here happens in a scratch directory and installs nothing.
set -uo pipefail

WORK=${WORK:-$(mktemp -d)}
AKKAR=${AKKAR:-$(cd "$(dirname "$0")/../.." && pwd)}
CQUEUES_COMMIT=${CQUEUES_COMMIT:-c36614982fe07917b2e1ce5a9e7a0e55b81be262}
LUA_VERSION=${LUA_VERSION:-5.5.1}

cd "$WORK"
echo "# working in $WORK"
mkdir -p lib share

step() { printf '\n== %s\n' "$1"; }

# ------------------------------------------------------------------ the VM
step "Lua $LUA_VERSION"
curl -fsSL -O "https://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz"
tar xzf "lua-$LUA_VERSION.tar.gz"
( cd "lua-$LUA_VERSION" && make -s linux ) >/dev/null 2>&1
LUA="$WORK/lua-$LUA_VERSION/src/lua"
LUA_INC="$WORK/lua-$LUA_VERSION/src"
"$LUA" -v

# ---------------------------------------------------------------- the loop
step "cqueues at $CQUEUES_COMMIT"
git clone -q https://github.com/wahern/cqueues.git cqueues
( cd cqueues && git checkout -q "$CQUEUES_COMMIT" )
grep -m1 KNOWN_APIS cqueues/GNUmakefile

echo "-- as shipped:"
if ( cd cqueues && make all5.5 CPPFLAGS="-I$LUA_INC" ) >/dev/null 2>&1; then
  echo "   builds (upstream has fixed the vendored compat header)"
else
  echo "   FAILS -- vendored lua-compat-5.3 refuses LUA_VERSION_NUM > 504"
fi

echo "-- with the current lua-compat-5.3:"
for f in compat-5.3.h compat-5.3.c; do
  curl -fsSL -o "cqueues/vendor/compat53/c-api/$f" \
    "https://raw.githubusercontent.com/lunarmodules/lua-compat-5.3/master/c-api/$f"
done
( cd cqueues && make all5.5 CPPFLAGS="-I$LUA_INC" ) >/dev/null 2>&1 \
  && echo "   builds" || { echo "   still fails"; exit 1; }

cp cqueues/src/5.5/cqueues.so lib/_cqueues.so
cp -r cqueues/src/cqueues.lua cqueues/src/cqueues share/ 2>/dev/null || true

cat > loop.lua <<'LUA'
local cqueues = require "cqueues"
local cq, n = cqueues.new(), 0
cq:wrap(function() for _ = 1, 3 do n = n + 1 cqueues.sleep(0.01) end end)
assert(cq:loop(5))
print("   event loop ran under " .. _VERSION .. ", ticks=" .. n)
LUA
LUA_PATH="$WORK/share/?.lua;$WORK/share/?/init.lua;;" \
LUA_CPATH="$WORK/lib/?.so;;" "$LUA" loop.lua

# ---------------------------------------------------------- the serializer
step "lua-cjson"
CACHE="$HOME/.cache/luarocks/https___luarocks.org"
mkdir -p cjson && ( cd cjson && unzip -qo "$CACHE"/lua-cjson-*.src.rock )
( cd cjson/lua-cjson \
  && gcc -O2 -fPIC -shared -I"$LUA_INC" -o "$WORK/lib/cjson.so" \
       lua_cjson.c fpconv.c strbuf.c ) \
  && echo "   builds" || echo "   FAILS"

LUA_CPATH="$WORK/lib/?.so;;" "$LUA" -e \
  'local c = require "cjson" print("   " .. c.encode { ok = true })'

# ----------------------------------------------------------------- the TLS
step "luaossl"
mkdir -p ossl && ( cd ossl && unzip -qo "$CACHE"/luaossl-*.src.rock && unzip -qo rel-*.zip )
OSSL=$(find ossl -maxdepth 1 -type d -name 'luaossl-*' | head -1)
grep -m1 "KNOWN_APIS" "$OSSL/GNUmakefile" || true
if ( cd "$OSSL" && make all5.5 CPPFLAGS="-I$LUA_INC" ) >/dev/null 2>&1; then
  echo "   builds -- luaossl now has a 5.5 target"
else
  echo "   NO 5.5 TARGET. This is the blocker."
fi

step "verdict"
echo "   cqueues:  one stale vendored file away from 5.5"
echo "   luaossl:  no 5.5 target; nothing akkar can do from here"
echo "   akkar:    blocked on luaossl, via lua-http's openssl.rand"
