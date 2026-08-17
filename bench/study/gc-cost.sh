#!/usr/bin/env bash
# How much of akkar's per-request cost is the collector rather than the code?
#
# `floors.sh` puts akkar's own overhead at 44.6 us per request on top of the
# substrate. Before anyone proposes rewriting that code, it is worth knowing
# how much of it IS code. akkar allocates roughly 2,166 bytes per request and
# the hand-written floor allocates a small fraction of that, so an unknown
# share of the 44.6 is Lua reclaiming what akkar produced.
#
# Four collector settings, same server, same everything else:
#
#   default   Lua 5.4's incremental collector as shipped
#   gen       the generational collector, which line of investigation 9 asked
#             about and nobody ran
#   lazy      incremental with the pause and step multiplier opened right up
#   off       collector stopped. NOT a configuration anyone can ship -- memory
#             grows without bound -- but it is the only way to put a hard upper
#             bound on what collector tuning could ever be worth.
source "$(dirname "$0")/lib.sh"
detect_topology || exit 1
verify_reservation || exit 1

ROOT=${ROOT:-$HOME/akkar}
APPS=${APPS:-$HOME/study/apps}
PORT=${PORT:-8500}
DURATION=${DURATION:-10s}
REPS=${REPS:-3}
CONNS=${CONNS:-100}
THREADS=${THREADS:-4}
PROCS=${PROCS:-2}
HZ=$(getconf CLK_TCK)

stop_all() { pkill -f "study/apps/serve[.]lua" 2>/dev/null; sleep 2; }
trap stop_all EXIT

cpu_ticks() {
  local total=0
  for pid in $(pgrep -f "study/apps/serve[.]lua" 2>/dev/null); do
    [ -r "/proc/$pid/stat" ] || continue
    local rest; rest=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null)
    local ut st
    ut=$(echo "$rest" | awk '{print $12}'); st=$(echo "$rest" | awk '{print $13}')
    total=$(( total + ${ut:-0} + ${st:-0} ))
  done
  echo "$total"
}

# Peak RSS across the server processes, in MB. With the collector stopped this
# is the number that says why "off" is a probe and not an option.
peak_rss() {
  local total=0
  for pid in $(pgrep -f "study/apps/serve[.]lua" 2>/dev/null); do
    local kb; kb=$(awk '/VmHWM/{print $2}' "/proc/$pid/status" 2>/dev/null)
    total=$(( total + ${kb:-0} ))
  done
  awk -v k="$total" 'BEGIN{printf "%.0f", k/1024}'
}

run_gc() {   # label, AKKAR_GC value ("" = default)
  local label=$1 gc=${2:-}
  stop_all
  for _ in $(seq 1 "$PROCS"); do
    AKKAR_ROOT="$ROOT" AKKAR_LEAN=0 AKKAR_GC="$gc" setsid taskset -c "$SERVERS" \
      lua5.4 "$APPS/serve.lua" "$PORT" 10 </dev/null >/dev/null 2>&1 & disown
  done
  sleep 4
  verify_running "study/apps/serve[.]lua" "$PROCS" "akkar/$label" || return 1
  probe_body "http://127.0.0.1:$PORT/ping" >/dev/null || {
    echo "REFUSING: $label did not answer"; return 1; }

  taskset -c "$GENERATOR" wrk -t"$THREADS" -c"$CONNS" -d3s \
    "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1

  local rows="" cs=0 n=0
  for _ in $(seq 1 "$REPS"); do
    local b a ws we line
    b=$(cpu_ticks); ws=$(date +%s.%N)
    line=$(run_wrk "http://127.0.0.1:$PORT/ping" "$DURATION" "$CONNS" "$THREADS") || return 1
    we=$(date +%s.%N); a=$(cpu_ticks)
    local c; c=$(awk -v x="$b" -v y="$a" -v hz="$HZ" -v s="$ws" -v e="$we" \
      'BEGIN{printf "%.2f", ((y-x)/hz)/(e-s)}')
    cs=$(awk -v p="$cs" -v q="$c" 'BEGIN{print p+q}'); n=$((n+1))
    rows+="$line"$'\n'
  done
  local ac; ac=$(awk -v s="$cs" -v n="$n" 'BEGIN{printf "%.2f", s/n}')
  local r; r=$(echo "$rows" | grep -v '^$' | summarise)
  local rps; rps=$(echo $r | cut -d' ' -f1)
  local us; us=$(awk -v x="$rps" -v c="$ac" 'BEGIN{printf "%.1f", (c/x)*1000000}')
  local rss; rss=$(peak_rss)
  printf "%-22s %11s %10s %10s %7s%% %7s %10s %8s\n" "$label" $r "$ac" "$us" "${rss}MB"
}

echo "cores $SERVERS, generator $GENERATOR, $PROCS processes, /ping only"
echo
printf "%-22s %11s %10s %10s %8s %7s %10s %8s\n" \
  collector req/s p50 p99 spread cores "us/req" "peak rss"
printf "%-22s %11s %10s %10s %8s %7s %10s %8s\n" \
  "----------------------" ----------- ---------- ---------- -------- ------- ---------- --------

run_gc "default (shipped)" ""
run_gc "generational"      "gen"
run_gc "incremental, lazy" "lazy"
run_gc "STOPPED (probe)"   "off"

echo
echo "STOPPED is not shippable -- memory grows without bound. It is the upper"
echo "bound on what any collector tuning could be worth, and nothing more."
