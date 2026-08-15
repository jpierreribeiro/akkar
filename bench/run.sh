#!/usr/bin/env bash
#
# Multicore scaling, measured the way it has to be measured to mean anything.
#
# The methodology is borrowed from an earlier project of mine
# (uruquim-odin, planning/benchmark-methodology.md).  Four of its rules matter
# most here, and each one exists because ignoring it produced a wrong answer
# somewhere:
#
#   1. VERIFY EVERY RESPONSE.  A load generator that is being rejected still
#      reports a number, and the number looks like a number.  That project
#      threw away a whole comparison because ApacheBench speaks HTTP/1.0, the
#      server rejected every request, and ab cheerfully reported 100% non-2xx
#      as throughput.  Here, any non-2xx fails the run.
#
#   2. ALTERNATING ORDER.  The outer loop is the repetition, the inner loop is
#      the configuration.  Running all repetitions of N=1 and then all of N=2
#      hands the first one a warm cache for its whole block, and the measured
#      difference is the order.
#
#   3. WARM-UP, DISCARDED.  The first pass pays for page faults and
#      branch-predictor training that no steady-state request pays again.
#
#   4. DERIVE THE NOISE FLOOR FROM THIS MACHINE.  Repetitions of the SAME
#      configuration give the spread; a difference smaller than that spread is
#      not a result.  Run `bench/noise.sh` first.
#
#   bash bench/run.sh 1 2 4 8
set -uo pipefail

PORT="${PORT:-8300}"
DURATION="${DURATION:-15s}"
CONNECTIONS="${CONNECTIONS:-100}"
THREADS="${THREADS:-4}"
TARGET="${TARGET:-/users/42}"
POOL="${POOL:-10}"
REPS="${REPS:-3}"
WARMUP="${WARMUP:-5s}"

command -v wrk >/dev/null || { echo "wrk is not installed; see bench/README.md"; exit 1; }

CONFIGS=("${@:-1 2 4 8}")
[ $# -gt 0 ] && CONFIGS=("$@")

# ---------------------------------------------------------------- environment
# A distribution without its environment cannot be reproduced, and an
# unreproducible number is an anecdote with decimal places.
echo "# environment"
echo "  date        : $(date -Is)"
echo "  host        : $(uname -srm)"
echo "  cpu         : $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
echo "  cores       : $(nproc)"
echo "  memory      : $(free -g | awk '/^Mem:/ {print $2}') GB"
echo "  lua         : $(lua5.4 -v 2>&1)"
echo "  akkar       : $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
echo "  ulimit -n   : $(ulimit -n)"
echo "  target      : $TARGET"
echo "  wrk         : -t$THREADS -c$CONNECTIONS -d$DURATION"
echo "  pool_size   : $POOL per process"
echo "  repetitions : $REPS, alternating order"
echo

if [ "$(ulimit -n)" -lt 8192 ]; then
  echo "REFUSING TO RUN: ulimit -n is $(ulimit -n)."
  echo "Hitting it looks exactly like the server falling over.  Run: ulimit -n 65535"
  exit 1
fi

cleanup() { pkill -f "bench/serve.lua $PORT" 2>/dev/null; sleep 0.5; }
trap cleanup EXIT

start_processes() {
  cleanup
  for _ in $(seq 1 "$1"); do
    lua5.4 bench/serve.lua "$PORT" "$POOL" >/dev/null 2>&1 &
  done
  sleep 2

  # Rule 1 applied to the CONFIGURATION, not just the responses.
  #
  # Verifying every response is not enough.  The first scaling run on a
  # c5.2xlarge started 8 processes, 7 died instantly with EADDRINUSE because
  # SO_REUSEPORT was not set, and the one survivor answered every request
  # perfectly -- so the run passed its own checks and reported a flat line
  # labelled "8 processes".  A configuration that is not the configuration
  # produces numbers that look exactly like real ones.
  local alive
  alive=$(pgrep -fc "bench/serve.lua $PORT" || echo 0)
  if [ "$alive" -ne "$1" ]; then
    echo "REFUSING TO RUN: asked for $1 processes, $alive are alive."
    echo "The rest most likely failed to bind.  Is reuseport = true set?"
    exit 1
  fi

  # And it must actually answer before being measured.
  curl -sf --max-time 5 "http://127.0.0.1:$PORT$TARGET" >/dev/null || {
    echo "REFUSING TO RUN: the server did not answer $TARGET with 2xx before the run."
    exit 1
  }
}

# Prints "rps p50 p99" or "INVALID <reason>".
measure() {
  local out
  out=$(wrk -t"$THREADS" -c"$CONNECTIONS" -d"$1" --latency \
        "http://127.0.0.1:$PORT$TARGET" 2>/dev/null)

  # Rule 1.  wrk prints this line ONLY when some responses were not 2xx/3xx,
  # so its absence is the pass condition.
  local bad
  bad=$(echo "$out" | awk '/Non-2xx or 3xx responses/ {print $NF}')
  if [ -n "${bad:-}" ]; then
    echo "INVALID $bad non-2xx responses"
    return
  fi
  local errors
  errors=$(echo "$out" | awk '/Socket errors/ {print $0}')
  if [ -n "${errors:-}" ]; then
    echo "INVALID $errors"
    return
  fi

  echo "$out" | awk '
    /Requests\/sec/ {rps=$2}
    /^ *50%/ {p50=$2}
    /^ *99%/ {p99=$2}
    END {print rps, p50, p99}'
}

declare -A RESULTS
FAILED=0

for rep in $(seq 1 "$REPS"); do
  for n in "${CONFIGS[@]}"; do
    start_processes "$n"
    [ "$rep" -eq 1 ] && wrk -t"$THREADS" -c"$CONNECTIONS" -d"$WARMUP" \
      "http://127.0.0.1:$PORT$TARGET" >/dev/null 2>&1   # rule 3

    result=$(measure "$DURATION")
    if [[ "$result" == INVALID* ]]; then
      echo "  rep $rep, n=$n: $result"
      FAILED=1
    else
      RESULTS["$n"]="${RESULTS[$n]:-}$result"$'\n'
    fi
  done
done

if [ "$FAILED" -eq 1 ]; then
  echo
  echo "RUN INVALID.  A load generator being rejected still reports a number."
  echo "Fix the errors above before quoting anything from this run."
  exit 1
fi

echo "# results (median of $REPS repetitions, alternating order)"
printf "  %-10s %14s %12s %12s %14s %10s\n" \
       "processes" "req/s" "p50" "p99" "req/s/process" "scaling"
BASE=""
for n in "${CONFIGS[@]}"; do
  read -r rps p50 p99 <<<"$(echo "${RESULTS[$n]}" | grep -v '^$' | sort -n -k1 | awk 'NR==int((NR+1)/2) || 1' | \
    awk '{r[NR]=$1; a[NR]=$2; b[NR]=$3} END {m=int((NR+1)/2); print r[m], a[m], b[m]}')"
  per=$(awk -v r="$rps" -v n="$n" 'BEGIN {printf "%.0f", r/n}')
  [ -z "$BASE" ] && BASE="$per"
  scale=$(awk -v p="$per" -v b="$BASE" 'BEGIN {printf "%.2fx", p/b}')
  printf "  %-10s %14s %12s %12s %14s %10s\n" "$n" "$rps" "$p50" "$p99" "$per" "$scale"
done

echo
echo "# reading it"
echo "  scaling near 1.00x throughout -> one process per core is the whole"
echo "     deployment story, and CPU-bound work is capacity, not architecture"
echo "  scaling falling off           -> something shared is the limit; check"
echo "     Postgres max_connections against $((${CONFIGS[-1]} * POOL)) connections"
echo "  compare differences against the noise floor from bench/noise.sh;"
echo "     a difference smaller than that floor is not a result"
