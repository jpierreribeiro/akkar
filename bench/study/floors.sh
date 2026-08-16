#!/usr/bin/env bash
# Attributes the /ping gap against Gin, instead of leaving it as one number.
#
# Four servers, identical pinning, identical wrk, identical response body, and
# CPU consumption measured rather than assumed:
#
#   cqueues    the event loop with a hand-written response and no parsing
#   lua-http   the substrate akkar stands on, with akkar removed
#   akkar      the published /ping
#   gin        held to the same thread count with GOMAXPROCS
#
# Two processes each, both pinned to the same cores. Every server answers the
# same thirteen bytes, so nothing here is measuring an encoder.
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

stop_all() {
  pkill -f "study/floors[.]lua"     2>/dev/null
  pkill -f "study/apps/serve[.]lua" 2>/dev/null
  pkill -f "study/apps/gin-bench"   2>/dev/null
  sleep 2
}
trap stop_all EXIT

cpu_ticks() {
  local pattern=$1 total=0
  for pid in $(pgrep -f "$pattern" 2>/dev/null); do
    [ -r "/proc/$pid/stat" ] || continue
    local rest; rest=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null)
    local ut st
    ut=$(echo "$rest" | awk '{print $12}'); st=$(echo "$rest" | awk '{print $13}')
    total=$(( total + ${ut:-0} + ${st:-0} ))
  done
  echo "$total"
}

measure_one() {
  local pattern=$1
  taskset -c "$GENERATOR" wrk -t"$THREADS" -c"$CONNS" -d3s \
    "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1
  local rows="" cores_sum=0 n=0
  for _ in $(seq 1 "$REPS"); do
    local before after ws we line
    before=$(cpu_ticks "$pattern"); ws=$(date +%s.%N)
    line=$(run_wrk "http://127.0.0.1:$PORT/ping" "$DURATION" "$CONNS" "$THREADS") || return 1
    we=$(date +%s.%N); after=$(cpu_ticks "$pattern")
    local c; c=$(awk -v a="$before" -v b="$after" -v hz="$HZ" -v s="$ws" -v e="$we" \
      'BEGIN{printf "%.2f", ((b-a)/hz)/(e-s)}')
    cores_sum=$(awk -v x="$cores_sum" -v y="$c" 'BEGIN{print x+y}'); n=$((n+1))
    rows+="$line"$'\n'
  done
  local ac; ac=$(awk -v s="$cores_sum" -v n="$n" 'BEGIN{printf "%.2f", s/n}')
  echo "$(echo "$rows" | grep -v '^$' | summarise) $ac"
}

# The body must be identical everywhere or this measures encoders.
verify_body() {
  local what=$1
  local body; body=$(probe_body "http://127.0.0.1:$PORT/ping") || {
    echo "REFUSING: $what returned $body"; return 1; }
  if [ -z "${EXPECT_BODY:-}" ]; then
    EXPECT_BODY=$body
  elif [ "$body" != "$EXPECT_BODY" ]; then
    echo "REFUSING: $what answers $body, others answer $EXPECT_BODY"
    echo "  Different bytes is a different measurement."
    return 1
  fi
  return 0
}

start_lua_floor() {   # which
  local which=$1
  stop_all
  for _ in $(seq 1 "$PROCS"); do
    setsid taskset -c "$SERVERS" lua5.4 "$ROOT/bench/study/floors.lua" \
      "$which" "$PORT" </dev/null >/dev/null 2>/tmp/floor-$which.log & disown
  done
  sleep 3
  verify_running "study/floors[.]lua" "$PROCS" "floor/$which" || return 1
}

start_akkar() {
  stop_all
  for _ in $(seq 1 "$PROCS"); do
    AKKAR_ROOT="$ROOT" AKKAR_LEAN=0 setsid taskset -c "$SERVERS" \
      lua5.4 "$APPS/serve.lua" "$PORT" 10 </dev/null >/dev/null 2>&1 & disown
  done
  sleep 4
  verify_running "study/apps/serve[.]lua" "$PROCS" "akkar" || return 1
}

start_gin() {         # GOMAXPROCS
  local gmp=$1
  stop_all
  for _ in $(seq 1 "$PROCS"); do
    GOMAXPROCS="$gmp" setsid taskset -c "$SERVERS" "$APPS/gin-bench" "$PORT" 10 \
      </dev/null >/dev/null 2>&1 & disown
  done
  sleep 4
  verify_running "study/apps/gin-bench" "$PROCS" "gin" || return 1
}

echo "cores $SERVERS, generator $GENERATOR, $PROCS processes each, /ping only"
echo
printf "%-26s %11s %10s %10s %8s %7s %11s\n" \
  layer req/s p50 p99 spread cores "us/req/core"
printf "%-26s %11s %10s %10s %8s %7s %11s\n" \
  "--------------------------" ----------- ---------- ---------- -------- ------- -----------

row() {  # label, pattern
  local label=$1 pattern=$2
  verify_body "$label" || exit 1
  local r; r=$(measure_one "$pattern") || { echo "$label FAILED"; return 1; }
  local rps cores us
  rps=$(echo $r | cut -d' ' -f1); cores=$(echo $r | cut -d' ' -f5)
  us=$(awk -v r="$rps" -v c="$cores" 'BEGIN{ printf "%.1f", (c / r) * 1000000 }')
  printf "%-26s %11s %10s %10s %7s%% %7s %11s\n" "$label" $r "$us"
}

start_lua_floor cqueues && row "cqueues, no parsing"  "study/floors[.]lua"
start_lua_floor luahttp && row "lua-http, no akkar"   "study/floors[.]lua"
start_akkar             && row "akkar /ping"          "study/apps/serve[.]lua"
start_gin 1             && row "gin, GOMAXPROCS=1"    "study/apps/gin-bench"

echo
echo "us/req/core is CPU microseconds spent per request per core -- the only"
echo "column that compares layers fairly when they consume different CPU."
