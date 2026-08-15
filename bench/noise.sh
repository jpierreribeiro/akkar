#!/usr/bin/env bash
#
# Derives this machine's noise floor.
#
# The tolerance comes from the machine, not from a person picking a number and
# calling it measured.  Run the SAME configuration many times and take the
# spread; any later difference smaller than that spread is not a result.
#
# This is worth the ten minutes.  An earlier project of mine measured a floor
# of +/-57.6% on its hardware, which invalidated a comparison it was about to
# base a design decision on.
#
#   bash bench/noise.sh [repetitions]
set -uo pipefail

PORT="${PORT:-8300}"
DURATION="${DURATION:-10s}"
CONNECTIONS="${CONNECTIONS:-100}"
THREADS="${THREADS:-4}"
TARGET="${TARGET:-/users/42}"
POOL="${POOL:-10}"
PROCESSES="${PROCESSES:-4}"
CORES="${CORES:-$(nproc)}"
GEN_CORES="${GEN_CORES:-0-1}"
SRV_CORES="${SRV_CORES:-2-$((CORES - 1))}"
PIN="${PIN:-1}"
srv_run() { if [ "$PIN" = "1" ]; then taskset -c "$SRV_CORES" "$@"; else "$@"; fi; }
gen_run() { if [ "$PIN" = "1" ]; then taskset -c "$GEN_CORES" "$@"; else "$@"; fi; }
REPS="${1:-10}"

command -v wrk >/dev/null || { echo "wrk is not installed"; exit 1; }

cleanup() { pkill -f "bench/serve.lua $PORT" 2>/dev/null; sleep 0.5; }
trap cleanup EXIT

echo "# noise floor: $REPS repetitions of an identical configuration"
echo "  processes   : $PROCESSES"
echo "  affinity    : servers $SRV_CORES, generator $GEN_CORES"
echo "  cpu         : $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
echo "  date        : $(date -Is)"
echo

cleanup
for _ in $(seq 1 "$PROCESSES"); do
  srv_run lua5.4 bench/serve.lua "$PORT" "$POOL" >/dev/null 2>&1 &
done
sleep 2
gen_run wrk -t"$THREADS" -c"$CONNECTIONS" -d5s "http://127.0.0.1:$PORT$TARGET" >/dev/null 2>&1

SAMPLES=()
for rep in $(seq 1 "$REPS"); do
  out=$(gen_run wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION" \
        "http://127.0.0.1:$PORT$TARGET" 2>/dev/null)
  if echo "$out" | grep -q 'Non-2xx'; then
    echo "  rep $rep: INVALID, non-2xx responses"; exit 1
  fi
  rps=$(echo "$out" | awk '/Requests\/sec/ {print $2}')
  SAMPLES+=("$rps")
  printf "  rep %-3s %14s req/s\n" "$rep" "$rps"
done

printf '%s\n' "${SAMPLES[@]}" | sort -n | awk '
{v[NR]=$1}
END {
  n=NR
  min=v[1]; max=v[n]
  p50=v[int(0.50*n)+((0.50*n)==int(0.50*n)?0:1)]
  p95=v[int(0.95*n)+((0.95*n)==int(0.95*n)?0:1)]
  bp=(p95-min)/p50*10000
  printf "\n# floor\n"
  printf "  n=%d  min %.0f  p50 %.0f  p95 %.0f  max %.0f req/s\n", n, min, p50, p95, max
  printf "  spread (p95-min)/p50 = %.0f basis points = %.1f%%\n", bp, bp/100
  printf "\n  Any later difference smaller than %.1f%% is noise on this machine.\n", bp/100
}'
