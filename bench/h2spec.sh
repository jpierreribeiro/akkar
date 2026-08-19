#!/usr/bin/env bash
# HTTP/2 conformance, against a server in another process.
#
# `spec/h2_framing_spec.lua` says plainly what it does not establish: that
# lua-http's h2 is CORRECT. It throws 22 named hostile shapes at a live server
# and requires it to keep answering, which is a smaller and checkable claim.
# Conformance is a different question and h2spec is the standard answer to it --
# 146 cases straight out of RFC 7540 and RFC 7541.
#
# It lives here rather than in `spec/` for the reason `spec/fuzz_spec.lua`
# records about raw-socket harnesses: the client belongs in its own process.
# h2spec is a Go binary, so it is one by construction, and it is fetched rather
# than vendored.
#
# RESULT, akkar with `h2c = true`, h2spec 2.6.0, 2026-08-19, five runs:
#
#     146 tests, 145 passed, 1 skipped, 0 failed     3 runs
#     146 tests, 144 passed, 1 skipped, 1 failed     2 runs
#
# THE ONE THAT FAILS INTERMITTENTLY IS 3.8, GOAWAY. h2spec sends a GOAWAY and
# then a PING, and expects either a clean close or a PING ACK; it sometimes
# gets `connection reset by peer` instead. Two runs in five, which is a real
# deviation rather than a flaky measurement -- and the mechanism is ordinary:
# closing a socket that still has unread inbound data makes the kernel send
# RST rather than FIN, so whether h2spec's PING has landed in the buffer by
# the time the server closes decides which one it sees.
#
# It is a deviation and not a hazard: the connection is going away either way,
# and what a RST costs is data already in flight on a connection the peer
# asked to end. Fixing it means draining before closing in the vendored
# `h2_connection` GOAWAY path, which is upstream's code and a change worth
# more care than a conformance point. Recorded in `docs/BACKLOG.md` §12.3.
#
# The first run of this file reported 145/0 and the second 144/1. Reporting
# the first number alone would have been the exact mistake this project spent
# a week finding in its instruments.
#
# Run it after touching anything under `akkar/vendor/http/h2_*`, `hpack.lua`,
# or the negotiation in `server.lua`.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CACHE=${H2SPEC_CACHE:-${TMPDIR:-/tmp}/akkar-h2spec}
VERSION=${H2SPEC_VERSION:-v2.6.0}
PORT=${PORT:-17501}

mkdir -p "$CACHE"
if [ ! -x "$CACHE/h2spec" ]; then
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)  ASSET=h2spec_linux_amd64.tar.gz ;;
    Darwin-x86_64) ASSET=h2spec_darwin_amd64.tar.gz ;;
    Darwin-arm64)  ASSET=h2spec_darwin_amd64.tar.gz ;;   # runs under Rosetta
    *)
      echo "no h2spec build published for $(uname -s)-$(uname -m);" \
           "install it yourself and put it on PATH" >&2
      exit 2 ;;
  esac
  URL="https://github.com/summerwind/h2spec/releases/download/$VERSION/$ASSET"
  echo "fetching h2spec $VERSION"
  curl -fsSL -o "$CACHE/h2spec.tgz" "$URL" || { echo "download failed" >&2; exit 2; }
  tar xzf "$CACHE/h2spec.tgz" -C "$CACHE" || exit 2
  chmod +x "$CACHE/h2spec"
fi

APP=$(mktemp "${TMPDIR:-/tmp}/akkar-h2spec-app.XXXXXX.lua")
trap 'rm -f "$APP"' EXIT

cat > "$APP" <<'LUA'
package.path = "./?.lua;./?/init.lua;" .. package.path
local akkar = require "akkar"
local app = akkar.new()
app:get("/ping", function() return { pong = true } end)
app:post("/ping", function() return { pong = true } end)
app:run {
  port = assert(tonumber(os.getenv "PORT")),
  h2c = true,                      -- h2spec speaks cleartext with prior knowledge
  check_capabilities = false,
  log = akkar.log.new { level = "error", sink = function() end },
}
LUA

cd "$ROOT" || exit 1
export LUA_PATH="./?.lua;./?/init.lua;$HOME/.luarocks/share/lua/5.4/?.lua;$HOME/.luarocks/share/lua/5.4/?/init.lua;;"
export LUA_CPATH="$HOME/.luarocks/lib/lua/5.4/?.so;;"

PORT=$PORT lua5.4 "$APP" >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null; rm -f "$APP"' EXIT

# Wait for the port rather than sleeping a guess -- and poll at 20 ms, because
# `bench/runtime/run.sh` once measured its own `sleep .1` and reported it as
# three runtimes booting in 113 ms.
for _ in $(seq 1 200); do
  curl -s -m 1 -o /dev/null --http2-prior-knowledge \
    "http://127.0.0.1:$PORT/ping" && break
  sleep 0.02
done

"$CACHE/h2spec" -h 127.0.0.1 -p "$PORT" -P /ping --strict=false -t=false
STATUS=$?

kill $SRV 2>/dev/null
wait $SRV 2>/dev/null
exit $STATUS
