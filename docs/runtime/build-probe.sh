#!/usr/bin/env bash
# Can akkar ship as one binary?  Measured, not argued.
#
# `docs/BACKLOG.md` recorded `akkar build` in the "deliberately not building"
# table with this reason:
#
#     Attractive, but Redbean is a *different substrate*, and `cqueues` is a
#     C module. That is a substrate change, not a packaging step.
#
# The first half is true of Redbean and the second half does not follow. This
# script is the disproof: it links cqueues STATICALLY into a single executable
# and runs an event loop inside it. The substrate does not change at all --
# the same cqueues, the same lua-http above it, the same Lua 5.4 VM. Only the
# linkage changes.
#
# Three probes, each one more than the last:
#
#   1  a pure-Lua script                       -> 302 KB, libc + libm only
#   2  plus a C module (lua-cjson)             -> 328 KB
#   3  plus cqueues, running a real event loop -> 1.5 MB
#
# Run from anywhere. Needs: gcc, luarocks, and the OpenSSL headers.
set -euo pipefail

WORK=${WORK:-$(mktemp -d)}
LUA_INC=${LUA_INC:-/usr/include/lua5.4}
LUA_A=${LUA_A:-/usr/lib/x86_64-linux-gnu/liblua5.4.a}
CACHE="$HOME/.cache/luarocks/https___luarocks.org"

command -v luastatic >/dev/null || luarocks install --local luastatic
[ -r "$LUA_A" ]        || { echo "REFUSING: no $LUA_A"; exit 1; }
[ -r "$LUA_INC/lua.h" ] || { echo "REFUSING: no headers in $LUA_INC"; exit 1; }

cd "$WORK"
echo "# working in $WORK"

# ------------------------------------------------------------------ probe 1
echo 'print("probe 1: pure lua ok")' > hello.lua
luastatic hello.lua "$LUA_A" -I"$LUA_INC" -o hello >/dev/null
./hello
echo "  size: $(stat -c%s hello) bytes"

# ------------------------------------------------------------------ probe 2
# lua-cjson builds EITHER fpconv.c OR dtoa.c+g_fmt.c. Archiving both gives
# `multiple definition of fpconv_strtod` at link time.
mkdir -p cjson && cd cjson
unzip -qo "$CACHE"/lua-cjson-*.src.rock
cd lua-cjson
gcc -c -O2 -fPIC -I"$LUA_INC" lua_cjson.c fpconv.c strbuf.c
ar rcs "$WORK/cjson.a" lua_cjson.o fpconv.o strbuf.o
cd "$WORK"

cat > json.lua <<'LUA'
local cjson = require "cjson"
local s = cjson.encode { framework = "akkar", embedded = true }
assert(cjson.decode(s).framework == "akkar")
print("probe 2: C module embedded ok -> " .. s)
LUA
luastatic json.lua cjson.a "$LUA_A" -I"$LUA_INC" -o json >/dev/null
./json
echo "  size: $(stat -c%s json) bytes"

# ------------------------------------------------------------------ probe 3
# cqueues has no static target of its own, but its build already produces
# `src/lib/libnonlua.a` and per-API objects. Archiving them is one `ar` call.
mkdir -p cq && cd cq
unzip -qo "$CACHE"/cqueues-*.src.rock
tar xzf rel-*.tar.gz
cd cqueues-rel-*
make -s all5.4 CPPFLAGS="-I$LUA_INC" >/dev/null 2>&1
SRC=$PWD
cd "$WORK"

mkdir -p arobj && cd arobj
ar x "$SRC/src/lib/libnonlua.a"
for f in dns.o notify.o socket.o; do mv "$f" "lib_$f"; done   # names collide
cp "$SRC"/src/5.4/*.o .
ar rcs "$WORK/_cqueues.a" ./*.o
cd "$WORK"

cp "$(luarocks --local config deploy_lua_dir 2>/dev/null || echo "$HOME/.luarocks/share/lua/5.4")/cqueues.lua" .

cat > loop.lua <<'LUA'
local cqueues = require "cqueues"
local cq, ticks = cqueues.new(), 0
cq:wrap(function() for _ = 1, 3 do ticks = ticks + 1 cqueues.sleep(0.01) end end)
assert(cq:loop(5))
print("probe 3: cqueues event loop ran inside the binary, ticks=" .. ticks)
LUA

luastatic loop.lua cqueues.lua _cqueues.a "$LUA_A" -I"$LUA_INC" \
  -lssl -lcrypto -lpthread -ldl -lrt -lm -o loop >/dev/null

# luastatic derives a module name from the `luaopen_` symbol and turns the
# first underscore into a dot, so `luaopen__cqueues` registers as `.cqueues`
# rather than `_cqueues`. Every module whose name begins with an underscore
# hits this. Patched here; a real `akkar build` emits its own host and never
# has the problem.
sed -i 's/, "\.cqueues/, "_cqueues/g' loop.luastatic.c
cc -Os loop.luastatic.c _cqueues.a "$LUA_A" -rdynamic -lm -ldl \
   -I"$LUA_INC" -lssl -lcrypto -lpthread -lrt -o loop
./loop
echo "  size: $(stat -c%s loop) bytes"
echo
echo "# all three probes passed; see docs/RUNTIME.md for what this does and does not prove"
