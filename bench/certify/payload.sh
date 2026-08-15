#!/usr/bin/env bash
#
# Where does serialisation start to dominate?
#
#   bash bench/certify/payload.sh [akkar_dir]
#
# The owner's earlier framework had its trouble on "medium JSON" specifically
# -- not tiny, not huge.  There it turned out to be a 4,310-byte body of 64
# nested items, and the cost was work the framework *chose* to do: re-validating
# what it had just serialised, and re-tokenising what it had just parsed.
#
# This sweeps response size against akkar alone to find the same knee, if it
# has one.  Two curves, because they have different causes:
#
#   /rows/:n   the response grows   -> encode cost
#   /echo      the request grows    -> decode cost, response stays constant
#
# Throughput falling faster than the payload grows means per-byte cost is
# rising, which points at work proportional to something other than bytes.
# Falling proportionally is just more bytes, and is nobody's bug.
set -uo pipefail

AKKAR_DIR="${1:-.}"
PORT="${PORT:-8500}"
DURATION="${DURATION:-8s}"
CONNECTIONS="${CONNECTIONS:-50}"
THREADS="${THREADS:-2}"
PROCESSES="${PROCESSES:-3}"
POOL="${POOL:-10}"
SIZES="${SIZES:-1 10 50 100 250 500 1000 2500}"
PIN="${PIN:-1}"

command -v wrk >/dev/null || { echo "wrk is not installed"; exit 1; }

if [ "$PIN" = "1" ] && command -v taskset >/dev/null; then
  declare -A SIB
  for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -r "$cpu/topology/core_id" ] || continue
    c=$(cat "$cpu/topology/core_id"); SIB[$c]="${SIB[$c]:+${SIB[$c]},}${cpu##*/cpu}"
  done
  PH=($(printf '%s\n' "${!SIB[@]}" | sort -n))
  GEN_CORES="${SIB[${PH[0]}]}"; SRV_CORES=""
  for i in "${!PH[@]}"; do [ "$i" -eq 0 ] && continue
    SRV_CORES="${SRV_CORES:+$SRV_CORES,}${SIB[${PH[$i]}]}"; done
  srv() { taskset -c "$SRV_CORES" "$@"; }
  gen() { taskset -c "$GEN_CORES" "$@"; }
else
  srv() { "$@"; }; gen() { "$@"; }
fi

stop() { pkill -f "bench/certify/serve.lua $PORT" 2>/dev/null; sleep 0.5; }
trap stop EXIT

stop
for _ in $(seq 1 "$PROCESSES"); do
  srv lua5.4 bench/certify/serve.lua "$PORT" "$POOL" "$AKKAR_DIR" >/dev/null 2>&1 &
done
sleep 3
alive=$(pgrep -fc "bench/certify/serve.lua $PORT" || echo 0)
[ "$alive" -eq "$PROCESSES" ] || { echo "only $alive/$PROCESSES processes alive"; exit 1; }

echo "# payload sweep  --  $AKKAR_DIR"
echo "  $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs), $(nproc) threads"
echo "  wrk -t$THREADS -c$CONNECTIONS -d$DURATION, $PROCESSES processes"
echo

# ---------------------------------------------------------------- response side
echo "## response grows  --  GET /rows/:n  (encode cost)"
printf "  %-8s %12s %12s %14s %14s\n" "rows" "bytes" "req/s" "us/req" "ns/byte"
PREV_RPS=""; PREV_BYTES=""
for n in $SIZES; do
  body=$(curl -s --max-time 20 "http://127.0.0.1:$PORT/rows/$n" 2>/dev/null)
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "http://127.0.0.1:$PORT/rows/$n")
  [ "$code" = "200" ] || { printf "  %-8s %12s\n" "$n" "HTTP $code"; continue; }
  bytes=${#body}

  out=$(gen wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" \
        "http://127.0.0.1:$PORT/rows/$n" 2>/dev/null)
  echo "$out" | grep -q 'Non-2xx' && { printf "  %-8s %12s %12s\n" "$n" "$bytes" "INVALID"; continue; }
  rps=$(echo "$out" | awk '/Requests\/sec/{printf "%.0f", $2}')
  us=$(awk -v r="$rps" -v p="$PROCESSES" 'BEGIN{printf "%.1f", (r>0)? p*1e6/r : 0}')
  nspb=$(awk -v u="$us" -v b="$bytes" 'BEGIN{printf "%.1f", (b>0)? u*1000/b : 0}')
  printf "  %-8s %12s %12s %14s %14s\n" "$n" "$bytes" "$rps" "$us" "$nspb"
done

echo
echo "## request grows  --  POST /echo  (decode cost, response constant)"
printf "  %-8s %12s %12s %14s %14s\n" "rows" "bytes in" "req/s" "us/req" "ns/byte"
for n in $SIZES; do
  payload=$(lua5.4 -e '
    local cjson = require "cjson"
    local n = tonumber(arg[1]); local rows = {}
    for i = 1, n do
      rows[i] = { id = i, name = "user" .. i, email = "u" .. i .. "@example.com" }
    end
    io.write(cjson.encode { rows = rows })' "$n" 2>/dev/null)
  [ -z "$payload" ] && { printf "  %-8s %12s\n" "$n" "encode failed"; continue; }
  printf '%s' "$payload" > /tmp/certify-payload.json
  bytes=${#payload}

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST \
         -H 'content-type: application/json' --data-binary @/tmp/certify-payload.json \
         "http://127.0.0.1:$PORT/echo")
  [ "$code" = "200" ] || { printf "  %-8s %12s %12s\n" "$n" "$bytes" "HTTP $code"; continue; }

  cat > /tmp/certify-post.lua <<LUAEOF
wrk.method = "POST"
wrk.headers["content-type"] = "application/json"
local f = assert(io.open("/tmp/certify-payload.json"))
wrk.body = f:read("a")
f:close()
LUAEOF
  out=$(gen wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" \
        -s /tmp/certify-post.lua "http://127.0.0.1:$PORT/echo" 2>/dev/null)
  echo "$out" | grep -q 'Non-2xx' && { printf "  %-8s %12s %12s\n" "$n" "$bytes" "INVALID"; continue; }
  rps=$(echo "$out" | awk '/Requests\/sec/{printf "%.0f", $2}')
  us=$(awk -v r="$rps" -v p="$PROCESSES" 'BEGIN{printf "%.1f", (r>0)? p*1e6/r : 0}')
  nspb=$(awk -v u="$us" -v b="$bytes" 'BEGIN{printf "%.1f", (b>0)? u*1000/b : 0}')
  printf "  %-8s %12s %12s %14s %14s\n" "$n" "$bytes" "$rps" "$us" "$nspb"
done

echo
echo "# reading it"
echo "  us/req is per process, so it is comparable across sizes."
echo "  ns/byte FLAT     -> cost is proportional to payload; nobody's bug"
echo "  ns/byte RISING   -> cost is superlinear in size, or proportional to"
echo "                      element COUNT rather than bytes.  That is the shape"
echo "                      the owner's earlier framework had, and there it was"
echo "                      per-element reflection and a redundant second pass."
echo "  ns/byte FALLING  -> a fixed per-request cost being amortised.  The knee"
echo "                      is where it stops falling."
