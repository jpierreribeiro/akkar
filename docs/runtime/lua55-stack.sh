#!/usr/bin/env bash
# Build the whole akkar dependency stack for Lua 5.5, from source, in a prefix.
#
# THIS SCRIPT IS THE RECIPE AND ALSO WHAT CI RUNS. Its sibling
# `lua55-probe.sh` answers "what blocks 5.5"; this one is the answer acted on.
# They are kept together deliberately: a documented recipe that CI does not
# execute is a recipe that silently rots, and this project has already been
# bitten by a claim nobody re-measured.
#
# WHY FROM SOURCE, EVERY LAYER
#
# No distribution ships Lua 5.5 yet, so the interpreter is built here. Two of
# the four C rocks then need something upstream has not released:
#
#   luaossl   Its C compiles against 5.5 with ZERO changes -- one `cc` and the
#             .so is there. What does not know 5.5 is its GNUmakefile, whose
#             KNOWN_APIS ladder stops at 5.4 and whose `mk/luapath` probe has
#             no 5.5 rung. So the build system is bypassed rather than patched:
#             two `sed`s into someone else's makefile is a thing that breaks
#             silently when upstream moves a line, and a direct compile of one
#             translation unit cannot drift that way.
#
#             This corrects the long-standing claim, carried in README.md and
#             docs/BACKLOG.md for months, that luaossl "has no 5.5 target" and
#             is therefore the blocker. It has no 5.5 *target*. Its code was
#             never the problem.
#
#   cqueues   Gained a 5.5 build target upstream in March 2026, in the very
#             commit akkar pins. But it vendors lua-compat-5.3 at v0.9, from
#             2020, whose header hard-errors on LUA_VERSION_NUM > 504:
#
#               compat-5.3.h:404: error: "unsupported Lua version
#                                 (i.e. not Lua 5.1, 5.2, 5.3, or 5.4)"
#
#             The 5.5 commit did not refresh the submodule. So the target
#             exists and the compile fails, which is exactly the shape of
#             "listing an API is not building for it". Upstream lua-compat-5.3
#             learned 5.5 in March 2026 and released v0.15.1 in July; this
#             swaps that in. It is the same error the macOS CI job hit when
#             Homebrew's `lua` formula quietly became 5.5.
#
# USAGE
#
#   LUA55_PREFIX=~/lua55 bash docs/runtime/lua55-stack.sh
#
# Everything lands in the prefix and nothing touches the system Lua or
# ~/.luarocks. Discarding the experiment is `rm -rf` on the prefix.
#
# Re-running is cheap: every step checks for its own output first, so this
# doubles as the cache-warm path in CI.
set -uo pipefail

# Resolved BEFORE anything cds. `$0` is relative, and this script changes
# directory five times.
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

P=${LUA55_PREFIX:-$HOME/lua55}
SRC=$P/src
LIB=$P/lib/lua/5.5
SHARE=$P/share/lua/5.5
LOG=$P/build.log

# The cqueues commit akkar pins. Kept in sync with the rockspecs by
# spec/rockspec_spec.lua, which asserts this file and they agree.
source "$REPO/runtime/substrate.env"
LUA_VERSION=$LUA55_VERSION

mkdir -p "$SRC" "$LIB" "$SHARE"
: > "$LOG"
export PATH="$P/bin:$PATH"

step() { printf '\n\033[1m--- %s ---\033[0m\n' "$1"; }
ok()   { printf '  \033[32m%-24s\033[0m %s\n' "$1" "${2:-}"; }
die()  { printf '  \033[31m%-24s\033[0m %s\n' "$1" "${2:-}"; \
         echo; echo "last 30 lines of $LOG:"; tail -30 "$LOG"; exit 1; }

# --------------------------------------------------------------- lua 5.5

step "Lua $LUA_VERSION"
if [ ! -x "$P/bin/lua5.5" ]; then
  cd "$SRC" || exit 1
  [ -f "lua-$LUA_VERSION.tar.gz" ] \
    || curl -fsSLO "https://www.lua.org/ftp/lua-$LUA_VERSION.tar.gz" \
    || die "download" "lua.org unreachable"
  rm -rf "lua-$LUA_VERSION"
  tar xf "lua-$LUA_VERSION.tar.gz"
  cd "lua-$LUA_VERSION" || exit 1
  # -fPIC is not optional: every C rock below links this static lib into a
  # shared object, and a non-PIC archive cannot go into one. Without it the
  # failure surfaces much later, as a relocation error from the linker while
  # building cqueues, which reads as a cqueues problem and is not one.
  make -j"$(nproc 2>/dev/null || echo 2)" linux-readline MYCFLAGS="-fPIC" >>"$LOG" 2>&1 \
    || make -j"$(nproc 2>/dev/null || echo 2)" linux MYCFLAGS="-fPIC" >>"$LOG" 2>&1 \
    || die "lua" "build failed"
  make install INSTALL_TOP="$P" >>"$LOG" 2>&1
  # Lua installs its interpreter as plain `lua`; every rock build system below
  # looks for a versioned `lua5.5`.
  ln -sf "$P/bin/lua" "$P/bin/lua5.5"
  ln -sf "$P/bin/luac" "$P/bin/luac5.5"
fi
"$P/bin/lua5.5" -v >/dev/null 2>&1 || die "lua5.5" "will not run"
"$P/bin/lua5.5" -e 'assert(_VERSION == "Lua 5.5", "got " .. _VERSION)' \
  || die "lua5.5" "is not 5.5"
ok "lua5.5" "$("$P/bin/lua5.5" -v 2>&1)"

# --------------------------------------------------------------- luarocks

step "luarocks against 5.5"
if [ ! -x "$P/bin/luarocks" ]; then
  cd "$SRC" || exit 1
  [ -d luarocks ] || git clone -q --depth 1 https://github.com/luarocks/luarocks.git
  cd luarocks || exit 1
  ./configure --prefix="$P" --with-lua="$P" --lua-version=5.5 >>"$LOG" 2>&1 \
    || die "luarocks configure" "failed"
  make install >>"$LOG" 2>&1 || die "luarocks install" "failed"
fi
ok "luarocks" "$("$P/bin/luarocks" --version 2>&1 | head -1)"

# ---------------------------------------------------------------- luaossl

step "luaossl -- compiled directly, makefile bypassed"
cd "$SRC" || exit 1
[ -d luaossl ] || git clone -q https://github.com/wahern/luaossl.git
cd luaossl || exit 1
if [ ! -f "$LIB/_openssl.so" ]; then
  # One translation unit, no build system. See the header of this file.
  cc -O2 -std=gnu99 -fPIC -shared -o "$LIB/_openssl.so" \
     -I"$P/include" src/openssl.c -lssl -lcrypto >>"$LOG" 2>&1 \
    || die "_openssl.so" "compile failed -- THIS would be a real 5.5 blocker"
fi
ok "_openssl.so" "$(du -h "$LIB/_openssl.so" | cut -f1)"

# The Lua half, and the one thing bypassing the makefile actually costs.
#
# luaossl keeps these FLAT and DOT-NAMED -- `src/openssl.ssl.context.lua` --
# and it is the makefile that turns each name into a directory path. Skip the
# makefile and you inherit that translation. Nothing warns you: a plain copy
# leaves `openssl.ssl.context.lua` sitting where `require` will never look,
# and the failure arrives much later as lua-http not finding `openssl.rand`.
if [ ! -f "$SHARE/openssl/rand.lua" ]; then
  count=0
  for f in src/openssl*.lua; do
    rel=${f#src/}; rel=${rel%.lua}            # openssl.ssl.context
    dest="$SHARE/${rel//./\/}.lua"            # openssl/ssl/context.lua
    mkdir -p "$(dirname "$dest")"
    cp -f "$f" "$dest"
    count=$((count + 1))
  done
  [ -f "$SHARE/openssl/rand.lua" ] \
    || die "openssl/*.lua" "installed $count files and openssl.rand is not among them"
fi
ok "openssl/*.lua" "$(find "$SHARE/openssl" -name '*.lua' | wc -l) modules"

# ---------------------------------------------------------------- cqueues

step "cqueues -- pinned commit, compat shim refreshed"
cd "$SRC" || exit 1
[ -d cqueues ] || git clone -q https://github.com/wahern/cqueues.git
if [ ! -f "$LIB/_cqueues.so" ]; then
  [ -d compat53 ] || git clone -q https://github.com/lunarmodules/lua-compat-5.3.git compat53
  cd compat53 || exit 1
  git fetch -q --tags
  git checkout -q "$COMPAT53_TAG" || die "compat53" "no tag $COMPAT53_TAG"
  cd "$SRC/cqueues" || exit 1
  git checkout -q "$CQUEUES_COMMIT" || die "cqueues" "no commit $CQUEUES_COMMIT"

  # The swap this whole layer exists for. Assert it took: if upstream ever
  # refreshes its own submodule, the copy is a no-op and this loudly says so
  # rather than leaving a stale header to fail 200 lines later.
  cp -f "$SRC/compat53/c-api/compat-5.3.h" vendor/compat53/c-api/compat-5.3.h
  cp -f "$SRC/compat53/c-api/compat-5.3.c" vendor/compat53/c-api/compat-5.3.c 2>/dev/null
  grep -q "505\|5\.5" vendor/compat53/c-api/compat-5.3.h \
    || die "compat53 swap" "the refreshed header still does not mention 5.5"

  make clean >>"$LOG" 2>&1
  make -j"$(nproc 2>/dev/null || echo 2)" all5.5 \
       CPPFLAGS="-I$P/include -DCQUEUES_COMMIT='\"${CQUEUES_COMMIT:0:7}\"'" \
       prefix="$P" lua55cpath="$LIB" lua55path="$SHARE" >>"$LOG" 2>&1
  make install5.5 prefix="$P" lua55cpath="$LIB" lua55path="$SHARE" >>"$LOG" 2>&1
  [ -f "$LIB/_cqueues.so" ] || die "_cqueues.so" "build failed"
fi
ok "_cqueues.so" "$(du -h "$LIB/_cqueues.so" | cut -f1)"

# ------------------------------------------------------------------ rocks

step "the rest, from the rockspec"
# THE LIST IS READ FROM `akkar-dev-1.rockspec`, NOT WRITTEN OUT HERE.
#
# It was written out here for exactly one run, and it was already wrong: it
# missed `pgmoon` and `http`, so the stack built clean, every substrate module
# loaded, and 85 documentation examples failed on `module 'pgmoon' not found`.
# A hand-copied dependency list is a second source of truth that nobody
# updates, which is the same defect this whole 5.5 story is about.
#
# `luarocks install akkar` is not an option here: it would resolve `cqueues`
# and `luaossl` from LuaRocks, and those are precisely the two that have to be
# built by hand above. So the rockspec is read for its list and the two
# hand-built ones are skipped by name.
ROCKSPEC=$REPO/akkar-dev-1.rockspec
[ -f "$ROCKSPEC" ] || die "rockspec" "not found at $ROCKSPEC"

# The rockspec is Lua, so it is read by Lua rather than by grep.
#
# PASSED IN THE ENVIRONMENT, NOT AS AN ARGUMENT. `lua -e 'code' file` treats
# `file` as a SCRIPT TO RUN, so it never lands in `arg[1]` -- and `loadfile`
# with no filename reads standard input, which here is empty. The result was
# an empty rock list, a zero exit status, and a build that reported success
# with nothing installed. A guard that fails open is worse than no guard, so
# the non-empty check below is as load-bearing as the parse itself.
rocks=$(ROCKSPEC="$ROCKSPEC" "$P/bin/lua5.5" -e '
  local path = assert(os.getenv "ROCKSPEC", "ROCKSPEC is not set")
  local env = {}
  local chunk = assert(loadfile(path, "t", env))
  chunk()
  local skip = { lua = true, cqueues = true, luaossl = true }
  local seen, out = {}, {}
  for _, list in ipairs { env.dependencies or {}, env.test_dependencies or {} } do
    for _, entry in ipairs(list) do
      local name = entry:match "^%s*([%w%-_%.]+)"
      if name and not skip[name] and not seen[name] then
        seen[name] = true
        out[#out + 1] = name
      end
    end
  end
  assert(#out > 0, "parsed no dependencies out of " .. path)
  print(table.concat(out, " "))') || die "rockspec" "will not parse"

[ -n "${rocks// /}" ] || die "rockspec" "parsed to an empty rock list"

# `luafilesystem` and `lua-term` arrive under busted; `tl` is deliberately
# absent, since spec/teal_spec.lua skips without it and it is a linter.
for rock in $rocks; do
  if "$P/bin/luarocks" show "$rock" >/dev/null 2>&1; then
    ok "$rock" "already there"
  elif "$P/bin/luarocks" install --tree="$P" "$rock" >>"$LOG" 2>&1; then
    ok "$rock"
  # `http` declares cqueues and luaossl, which exist here but not as rocks
  # LuaRocks can see -- they were compiled by hand. Installing it without
  # dependency resolution is correct for that reason and only that reason;
  # the module check below is what catches it if it is ever wrong.
  elif "$P/bin/luarocks" install --tree="$P" --nodeps "$rock" >>"$LOG" 2>&1; then
    ok "$rock" "--nodeps (its C deps are the hand-built ones)"
  else
    die "$rock" "luarocks install failed"
  fi
done

# ----------------------------------------------------------------- verify

step "every module akkar needs, loaded under 5.5"
# AKKAR ITSELF IS IN THIS LIST, and that is the point.
#
# The first version checked the substrate only -- cqueues, openssl, lpeg -- and
# passed on a prefix with no `pgmoon`, because nothing in that list reaches
# `akkar/db.lua`. The stack reported itself complete and the suite then failed
# 85 times. A completeness check that stops below the thing being built is not
# a completeness check.
LUA_CPATH="$LIB/?.so;;" \
LUA_PATH="$REPO/?.lua;$REPO/?/init.lua;$SHARE/?.lua;$SHARE/?/init.lua;;" \
"$P/bin/lua5.5" -e '
local missing = 0
for _, m in ipairs { "_openssl", "openssl.ssl.context", "openssl.rand",
                     "cqueues", "cqueues.socket", "cqueues.condition",
                     "cqueues.thread", "lpeg", "lpeg_patterns.http", "fifo",
                     "binaryheap", "basexx", "cjson", "pgmoon", "http.request",
                     "akkar", "akkar.db", "akkar.redis", "akkar.jobs" } do
  local ok, err = pcall(require, m)
  print(string.format("  %-26s %s", m, ok and "ok" or tostring(err):match("[^\n]*")))
  if not ok then missing = missing + 1 end
end
os.exit(missing == 0 and 0 or 1)' || die "module load" "something akkar needs is missing"

echo
ok "stack complete" "$P"
echo
echo "  run the suite with:"
echo "    export PATH=\"$P/bin:\$PATH\""
echo "    export LUA_PATH=\"\$PWD/?.lua;\$PWD/?/init.lua;$SHARE/?.lua;$SHARE/?/init.lua;;\""
echo "    export LUA_CPATH=\"$LIB/?.so;;\""
echo "    busted"
