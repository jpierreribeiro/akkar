#!/usr/bin/env bash
#
# Stages the four candidate services into ~/rt/svc from this checkout.
#
# WHY THIS EXISTS. `run.sh` starts four files out of `~/rt/svc`, and until now
# nothing put them there: the first study box was populated by hand. When it
# became unreachable, the numbers in `RESULTS.md` stopped being reproducible --
# not because the method was unwritten, but because the *services* were.
#
# So: everything `run.sh` opens comes from a file in this directory, and
# `provision.sh` installs the software while this places the code. Two scripts
# because they fail differently -- provisioning wants the network and root,
# staging wants neither and can be re-run after every `git pull`.
#
# Idempotent. Re-running is how you pick up a change to a service.
set -euo pipefail

RT="$HOME/rt"
SVC="$RT/svc"
AKKAR_SRC="${AKKAR_SRC:-$HOME/akkar}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ -d "$AKKAR_SRC/akkar" ] || {
  echo "no akkar checkout at $AKKAR_SRC -- set AKKAR_SRC or clone it there" >&2
  exit 1
}

mkdir -p "$SVC/openresty/conf" "$SVC/openresty/logs"

# The names on the left are what `run.sh` starts and `pkill -f` matches. They
# are not decorative: `stop_all` kills by pattern, so renaming a file here
# leaves a server running into the next candidate's measurement.
install -m 0644 "$HERE/akkar/serve.lua"     "$SVC/rt-akkar-serve.lua"
install -m 0644 "$HERE/luvit/serve.lua"     "$SVC/luvit-serve.lua"
install -m 0644 "$HERE/lapis/serve.lua"     "$SVC/lapis-serve.lua"
install -m 0644 "$HERE/lapis/run.lua"       "$SVC/lapis-serve-run.lua"
install -m 0644 "$HERE/openresty/nginx.conf" "$SVC/openresty/conf/nginx.conf"

# OpenResty's config hard-codes /home/ubuntu/.luarocks so that every Lua
# candidate reads the SAME pgmoon out of the same tree -- rule 2. On a box
# whose user is not `ubuntu` that path is silently wrong, and the failure
# arrives as HTTP 500 in the middle of a timed run rather than here.
if ! grep -q "$HOME/.luarocks" "$SVC/openresty/conf/nginx.conf"; then
  echo "WARNING: nginx.conf does not mention $HOME/.luarocks." >&2
  echo "         OpenResty will not find the shared pgmoon; fix the two" >&2
  echo "         lua_package_path lines before trusting /users/:id." >&2
fi

echo "staged into $SVC:"
ls -1 "$SVC" "$SVC/openresty/conf"
echo
echo "akkar source: $AKKAR_SRC ($(git -C "$AKKAR_SRC" rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout'))"
echo "next: bash $HERE/run.sh"
