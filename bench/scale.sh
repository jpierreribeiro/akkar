#!/usr/bin/env bash
# Multicore scaling: the same load against 1, 2, 4, 8 processes.
#
# One Lua VM is one core, so N processes is how akkar uses a machine.  This
# says how well that actually works and where it stops.
#
#   bash bench/scale.sh 1 2 4 8
set -uo pipefail

PORT="${PORT:-8300}"
DURATION="${DURATION:-20s}"
CONNECTIONS="${CONNECTIONS:-100}"
THREADS="${THREADS:-4}"
TARGET="${TARGET:-/users/42}"
POOL="${POOL:-10}"

command -v wrk >/dev/null || { echo "wrk is not installed; see bench/README.md"; exit 1; }

if [ "$(ulimit -n)" -lt 8192 ]; then
  echo "WARNING: ulimit -n is $(ulimit -n).  Hitting it looks exactly like the"
  echo "         server falling over.  Run: ulimit -n 65535"
  echo
fi

cleanup() { pkill -f "bench/serve.lua $PORT" 2>/dev/null; sleep 0.5; }
trap cleanup EXIT

printf "%-10s %14s %14s %14s %12s\n" "processes" "req/s" "latency p50" "latency p99" "per process"
for n in "${@:-1 2 4 8}"; do
  cleanup
  for _ in $(seq 1 "$n"); do
    lua5.4 bench/serve.lua "$PORT" "$POOL" >/dev/null 2>&1 &
  done
  sleep 2

  out=$(wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" --latency \
        "http://127.0.0.1:$PORT$TARGET" 2>/dev/null)
  rps=$(echo "$out" | awk '/Requests\/sec/ {print $2}')
  p50=$(echo "$out" | awk '/50%/ {print $2}')
  p99=$(echo "$out" | awk '/99%/ {print $2}')
  per=$(awk -v r="${rps:-0}" -v n="$n" 'BEGIN { printf "%.0f", r/n }')

  printf "%-10s %14s %14s %14s %12s\n" "$n" "${rps:-?}" "${p50:-?}" "${p99:-?}" "$per"
done

echo
echo "Reading it:"
echo "  near-linear to 8   -> one process per core is the deployment story"
echo "  flattening at 4    -> something shared is the limit; check Postgres"
echo "                        max_connections against N x POOL=$POOL"
echo "  sublinear from 1   -> the load generator or loopback is saturated,"
echo "                        not the server; rerun from another host"
