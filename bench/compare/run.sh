#!/usr/bin/env bash
#
# The comparison itself.  Read METHOD.md first: it was written before any
# number existed, and it is what makes these numbers mean anything.
#
#   bash run.sh [target] [processes]
set -uo pipefail

TARGET="${1:-/users/42}"
PROCESSES="${2:-3}"
DURATION="${DURATION:-12s}"
CONNECTIONS="${CONNECTIONS:-100}"
THREADS="${THREADS:-4}"
POOL="${POOL:-10}"
REPS="${REPS:-3}"

command -v wrk >/dev/null || { echo "wrk is not installed"; exit 1; }
export PATH=$HOME/.local/bin:$PATH:/usr/local/go/bin
eval "$(luarocks path --bin)" 2>/dev/null

# Rule 5: whole physical cores, because splitting sibling threads leaves the
# contention in place while looking like isolation.
declare -A SIBLINGS
for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
  [ -r "$cpu/topology/core_id" ] || continue
  core=$(cat "$cpu/topology/core_id")
  SIBLINGS[$core]="${SIBLINGS[$core]:+${SIBLINGS[$core]},}${cpu##*/cpu}"
done
PHYS=($(printf '%s\n' "${!SIBLINGS[@]}" | sort -n))
GEN_CORES="${SIBLINGS[${PHYS[0]}]}"
SRV_CORES=""
for i in "${!PHYS[@]}"; do
  [ "$i" -eq 0 ] && continue
  SRV_CORES="${SRV_CORES:+$SRV_CORES,}${SIBLINGS[${PHYS[$i]}]}"
done

echo "# environment"
echo "  date       : $(date -Is)"
echo "  cpu        : $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
echo "  topology   : ${#PHYS[@]} physical cores x $(( $(nproc) / ${#PHYS[@]} )) threads"
echo "  affinity   : services $SRV_CORES, generator $GEN_CORES"
echo "  target     : $TARGET"
echo "  load       : wrk -t$THREADS -c$CONNECTIONS -d$DURATION"
echo "  processes  : $PROCESSES each, pool $POOL each"
echo "  reps       : $REPS, alternating order"
echo "  go         : $(go version 2>/dev/null | awk '{print $3}')"
echo "  python     : $(~/fastapi-venv/bin/python -V 2>&1)"
echo "  lua        : $(lua5.4 -v 2>&1)"
echo

stop_all() {
  pkill -f gin-bench 2>/dev/null
  pkill -f uvicorn 2>/dev/null
  pkill -f "cmp/akkar/serve.lua" 2>/dev/null
  sleep 1
}
trap stop_all EXIT

start() {   # framework
  stop_all
  case "$1" in
    gin)
      for _ in $(seq 1 "$PROCESSES"); do
        PORT=8401 POOL=$POOL setsid taskset -c "$SRV_CORES" /tmp/gin-bench \
          </dev/null >/dev/null 2>&1 & disown
      done ;;
    fastapi)
      cd ~/cmp/fastapi
      POOL=$POOL setsid taskset -c "$SRV_CORES" ~/fastapi-venv/bin/uvicorn app:app \
        --host 127.0.0.1 --port 8402 --workers "$PROCESSES" \
        --no-access-log --log-level warning </dev/null >/dev/null 2>&1 & disown
      cd - >/dev/null ;;
    akkar)
      cd ~/akkar
      for _ in $(seq 1 "$PROCESSES"); do
        setsid taskset -c "$SRV_CORES" lua5.4 ~/cmp/akkar/serve.lua 8403 "$POOL" \
          </dev/null >/dev/null 2>&1 & disown
      done
      cd - >/dev/null ;;
  esac
  sleep 5
}

port_of() { case "$1" in gin) echo 8401;; fastapi) echo 8402;; akkar) echo 8403;; esac; }

# Prints "rps p50 p99" or "INVALID ..."
measure() {
  local port; port=$(port_of "$1")
  local out
  out=$(taskset -c "$GEN_CORES" wrk -t"$THREADS" -c"$CONNECTIONS" -d"$2" --latency \
        "http://127.0.0.1:$port$TARGET" 2>/dev/null)

  # Rule 1, still applying during the run: a rejected generator reports a
  # number that looks like a number.
  local bad; bad=$(echo "$out" | awk '/Non-2xx or 3xx responses/ {print $NF}')
  [ -n "${bad:-}" ] && { echo "INVALID $bad non-2xx"; return; }
  echo "$out" | grep -q 'Socket errors' && { echo "INVALID socket errors"; return; }

  echo "$out" | awk '/Requests\/sec/{r=$2} /^ *50%/{a=$2} /^ *99%/{b=$2} END{print r, a, b}'
}

FRAMEWORKS=(gin fastapi akkar)
declare -A SAMPLES
FAILED=0

for rep in $(seq 1 "$REPS"); do
  # Rule 4: outer loop is the repetition, inner loop the framework.
  for fw in "${FRAMEWORKS[@]}"; do
    start "$fw"
    port=$(port_of "$fw")
    curl -sf --max-time 5 "http://127.0.0.1:$port$TARGET" >/dev/null || {
      echo "  rep $rep $fw: REFUSING, no 2xx before the run"; FAILED=1; continue; }
    [ "$rep" -eq 1 ] && taskset -c "$GEN_CORES" wrk -t"$THREADS" -c"$CONNECTIONS" \
      -d5s "http://127.0.0.1:$port$TARGET" >/dev/null 2>&1   # warm-up, discarded

    result=$(measure "$fw" "$DURATION")
    if [[ "$result" == INVALID* ]]; then
      echo "  rep $rep $fw: $result"; FAILED=1
    else
      SAMPLES[$fw]="${SAMPLES[$fw]:-}$result"$'\n'
    fi
  done
done

[ "$FAILED" -eq 1 ] && { echo; echo "RUN INVALID -- see above."; exit 1; }

echo "# results on $TARGET (median of $REPS, alternating order)"
printf "  %-10s %14s %12s %12s %12s\n" "framework" "req/s" "p50" "p99" "relative"
BASE=""
for fw in "${FRAMEWORKS[@]}"; do
  read -r rps p50 p99 <<<"$(echo "${SAMPLES[$fw]}" | grep -v '^$' | sort -n \
    | awk '{r[NR]=$1;a[NR]=$2;b[NR]=$3} END {m=int((NR+1)/2); print r[m], a[m], b[m]}')"
  [ -z "$BASE" ] && BASE="$rps"
  rel=$(awk -v x="$rps" -v b="$BASE" 'BEGIN{printf "%.2fx", x/b}')
  printf "  %-10s %14s %12s %12s %12s\n" "$fw" "$rps" "$p50" "$p99" "$rel"
done
