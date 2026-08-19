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
# RESULT, akkar with `h2c = true`, h2spec 2.6.0, 2026-08-19:
#
#     146 tests, 146 passed, 0 skipped, 0 failed
#
# THE SKIPPED ONE WAS A FINDING, not a footnote. h2spec skips 5.1.2, "sends
# HEADERS that cause the advertised concurrent stream limit to be exceeded",
# when the server advertises no limit -- and akkar advertised
# MAX_CONCURRENT_STREAMS = infinity, inherited from upstream's defaults.
#
# Measured: 500 concurrent streams on ONE connection all went through, at
# 10 KB each, with `max_concurrent` never seeing them because it counts
# connections and that was one. Advertising 100 made 5.1.2 run, and it FAILED,
# which is how upstream's two `-- TODO: check MAX_CONCURRENT_STREAMS` comments
# stopped being trivia. Enforced now, and the same 500-stream probe delivers
# 100 to the application instead of 500.
#
# AND IT WAS NOT ALWAYS 15 OUT OF 15. The first five runs of this file split
# 3/2: three clean, two failing 3.8, GOAWAY. h2spec sends a GOAWAY and then a
# PING and expects either a clean close or a PING ACK, and twice in five it got
# `connection reset by peer` instead.
#
# The mechanism was ordinary and the fix was one loop.
# `connection_methods:shutdown` shut the READ side down while the peer's PING
# was still unread in the buffer, and closing a socket with unread inbound
# data makes the kernel send RST rather than FIN. Whether h2spec's PING had
# landed by then decided which one it saw. The vendored copy now drains what
# has already arrived -- bounded, without waiting -- before shutting the read
# side down. Fifteen consecutive clean runs since.
#
# The first run of this file reported 145/0 and the second 144/1. Reporting
# the first number alone would have been the exact mistake this project spent
# a week finding in its instruments -- and it would also have hidden a real
# defect that turned out to be fixable in six lines.
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
