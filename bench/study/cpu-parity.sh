#!/usr/bin/env bash
# How much of the Gin gap is hardware the harness never gave akkar?
#
# `SERVERS` is every hyperthread of the server cores -- on this box "2,6,3,7",
# four vCPUs over two physical cores. `PROCS` defaults to SERVER_CORES, which
# counts PHYSICAL cores, so akkar runs two single-threaded processes: two
# hardware threads out of four.
#
# Go does not agree to that. `main.go` never sets `GOMAXPROCS`, so the runtime
# takes it from `runtime.NumCPU()`, which reads the affinity mask -- four. Two
# Gin processes therefore spread goroutines across every thread the harness
# offered, while akkar used half of them.
#
# That is the exact shape of the asymmetry that got `bench/compare/RESULTS.md`
# retracted ("a 2:1 CPU handicap manufactures exactly that kind of outcome"),
# and nothing in the harness was checking for it.
#
# This script does not argue about it. It measures three things:
#
#   1. CPU ACTUALLY CONSUMED by each framework during a run, in cores. Not
#      what it was allowed -- what it took.
#   2. akkar at one process per vCPU rather than per physical core.
#   3. Gin held to the same thread count, via GOMAXPROCS.
#
# usage: cpu-parity.sh
source "$(dirname "$0")/lib.sh"
detect_topology || exit 1
verify_reservation || exit 1

ROOT=${ROOT:-$HOME/akkar}
APPS=${APPS:-$HOME/study/apps}
PORT=${PORT:-8500}
DURATION=${DURATION:-10s}
REPS=${REPS:-3}
POOL=${POOL:-10}
TARGET=${TARGET:-/ping}
CONNS=${CONNS:-100}
THREADS=${THREADS:-4}

VCPUS=$(echo "$SERVERS" | tr ',' '\n' | grep -c .)
echo "server cores  : $SERVERS  ($VCPUS vCPUs, ${#PHYSICAL[@]} physical, $SERVER_CORES for servers)"
echo "generator     : $GENERATOR"
echo "target        : $TARGET at $CONNS connections, $REPS reps of $DURATION"
echo

stop_all() {
  pkill -f "study/apps/serve[.]lua" 2>/dev/null
  pkill -f "study/apps/gin-bench"   2>/dev/null
  sleep 2
}
trap stop_all EXIT

# Total CPU seconds burned by every process matching a pattern.
#
# utime + stime from /proc/<pid>/stat, fields 14 and 15, in clock ticks. Read
# before and after so what is reported is the run's cost and not the process's
# whole life.
cpu_ticks() {
  local pattern=$1 total=0
  for pid in $(pgrep -f "$pattern" 2>/dev/null); do
    [ -r "/proc/$pid/stat" ] || continue
    # Field 2 is the comm and may contain spaces, so cut from the closing paren.
    local rest; rest=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null)
    local ut st
    ut=$(echo "$rest" | awk '{print $12}')
    st=$(echo "$rest" | awk '{print $13}')
    total=$(( total + ${ut:-0} + ${st:-0} ))
  done
  echo "$total"
}

HZ=$(getconf CLK_TCK)

# Runs one configuration and prints "rps p50 p99 cores_used"
measure_one() {
  local pattern=$1
  taskset -c "$GENERATOR" wrk -t"$THREADS" -c"$CONNS" -d3s \
    "http://127.0.0.1:$PORT$TARGET" >/dev/null 2>&1     # warm-up, discarded

  local rows="" cores_sum=0 n=0
  for _ in $(seq 1 "$REPS"); do
    local before after wall_start wall_end line
    before=$(cpu_ticks "$pattern")
    wall_start=$(date +%s.%N)
    line=$(run_wrk "http://127.0.0.1:$PORT$TARGET" "$DURATION" "$CONNS" "$THREADS") || return 1
    wall_end=$(date +%s.%N)
    after=$(cpu_ticks "$pattern")

    local cores
    cores=$(awk -v a="$before" -v b="$after" -v hz="$HZ" \
                -v s="$wall_start" -v e="$wall_end" \
                'BEGIN { printf "%.2f", ((b - a) / hz) / (e - s) }')
    cores_sum=$(awk -v x="$cores_sum" -v y="$cores" 'BEGIN{print x + y}')
    n=$((n + 1))
    rows+="$line"$'\n'
  done
  local avg_cores; avg_cores=$(awk -v s="$cores_sum" -v n="$n" 'BEGIN{printf "%.2f", s/n}')
  echo "$(echo "$rows" | grep -v '^$' | summarise) $avg_cores"
}

start_akkar_n() {         # processes, driver
  local n=$1 driver=${2:-pgmoon}
  stop_all
  local log=/tmp/parity-boot.log; : > "$log"
  for _ in $(seq 1 "$n"); do
    AKKAR_ROOT="$ROOT" AKKAR_LEAN=0 AKKAR_DRIVER="$driver" \
      setsid taskset -c "$SERVERS" \
      lua5.4 "$APPS/serve.lua" "$PORT" "$POOL" </dev/null >/dev/null 2>>"$log" &
    disown
  done
  sleep 4
  verify_running "study/apps/serve[.]lua" "$n" "akkar x$n" || return 1
  local seen; seen=$(grep -c "^driver=$driver$" "$log" 2>/dev/null)
  [ "${seen:-0}" -eq "$n" ] || { echo "REFUSING: $seen of $n reported driver=$driver"; return 1; }
}

start_gin_n() {           # processes, GOMAXPROCS ("" = let Go decide)
  local n=$1 gmp=${2:-}
  stop_all
  for _ in $(seq 1 "$n"); do
    if [ -n "$gmp" ]; then
      GOMAXPROCS="$gmp" setsid taskset -c "$SERVERS" "$APPS/gin-bench" "$PORT" "$POOL" \
        </dev/null >/dev/null 2>&1 & disown
    else
      setsid taskset -c "$SERVERS" "$APPS/gin-bench" "$PORT" "$POOL" \
        </dev/null >/dev/null 2>&1 & disown
    fi
  done
  sleep 4
  verify_running "study/apps/gin-bench" "$n" "gin x$n" || return 1
}

printf "%-30s %11s %10s %10s %8s %8s\n" configuration req/s p50 p99 spread cores
printf "%-30s %11s %10s %10s %8s %8s\n" "------------------------------" ----------- ---------- ---------- -------- --------

run_row() {  # label, pattern
  local label=$1 pattern=$2
  local r; r=$(measure_one "$pattern") || { echo "$label FAILED"; return 1; }
  printf "%-30s %11s %10s %10s %7s%% %8s\n" "$label" $r
}

start_akkar_n 2  && run_row "akkar x2 (as published)"   "study/apps/serve[.]lua"
start_akkar_n "$VCPUS" && run_row "akkar x$VCPUS (one per vCPU)" "study/apps/serve[.]lua"
start_gin_n   2  && run_row "gin x2 (as published)"     "study/apps/gin-bench"
start_gin_n   2 1 && run_row "gin x2, GOMAXPROCS=1"     "study/apps/gin-bench"

echo
echo "cores = CPU seconds burned by the server processes, divided by wall clock."
echo "It is what the framework TOOK, not what it was allowed."
