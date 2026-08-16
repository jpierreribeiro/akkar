#!/usr/bin/env bash
# Is akkar.pq less consistent than pgmoon, or is it just going twice as fast?
#
# THE COMPARISON THAT WAS NEVER FAIR. Every measurement of the "inconsistency"
# ran both drivers at the same CONCURRENCY, which means pq ran at more than
# twice pgmoon's throughput -- 5,100 req/s against 2,400. Anything that
# degrades with load therefore had twice the chance to appear on pq's side, and
# the conclusion drawn was about the driver.
#
# Two hypotheses have already been eliminated, and both by measurement:
#
#   * ONE LONG STALL. No: in a slow window p50 rises with p99, so the whole
#     window is slower rather than one request hanging in it.
#   * A POSTGRES CHECKPOINT. No. `anomaly.sh` found pq's worst window was the
#     one window a checkpoint completed in, which looked decisive at n=1 --
#     until `checkpoint.sh` forced them and neither driver moved (pgmoon
#     -0.0%, pq +0.1%). The correlated checkpoint had written ZERO buffers,
#     so there was never a mechanism; that should have been noticed first.
#
# So: sweep concurrency and watch the SPREAD. If pq is smooth at pgmoon's
# throughput and ragged at its own, then it is not less consistent -- it is
# consistent until pushed twice as hard, which is a different statement and a
# much less alarming one.
source "$(dirname "$0")/../study/lib.sh"
detect_topology || exit 1
verify_reservation || exit 1

ROOT=${ROOT:-$HOME/akkar}
APPS=${APPS:-$HOME/study/apps}
PORT=${PORT:-8500}
WINDOWS=${WINDOWS:-16}
DURATION=${DURATION:-10s}
THREADS=${THREADS:-4}
PROCS=${PROCS:-2}
TARGET=${TARGET:-/rows/100}

stop_all() { pkill -f "study/apps/serve[.]lua" 2>/dev/null; sleep 2; }
trap stop_all EXIT

start() {
  local driver=$1
  stop_all
  local log=/tmp/rm-boot.log; : > "$log"
  for _ in $(seq 1 "$PROCS"); do
    AKKAR_ROOT="$ROOT" AKKAR_LEAN=0 AKKAR_DRIVER="$driver" \
      setsid taskset -c "$SERVERS" \
      lua5.4 "$APPS/serve.lua" "$PORT" 10 </dev/null >/dev/null 2>>"$log" &
    disown
  done
  sleep 4
  verify_running "study/apps/serve[.]lua" "$PROCS" "akkar/$driver" || exit 1
  local seen; seen=$(grep -c "^driver=$driver$" "$log")
  [ "${seen:-0}" -eq "$PROCS" ] || { echo "REFUSING: driver not confirmed"; exit 1; }
}

sweep() {   # driver, connections
  local driver=$1 conns=$2
  taskset -c "$GENERATOR" wrk -t"$THREADS" -c"$conns" -d5s \
    "http://127.0.0.1:$PORT$TARGET" >/dev/null 2>&1

  local file=/tmp/rm-$driver-$conns; : > "$file"
  for _ in $(seq 1 "$WINDOWS"); do
    run_wrk "http://127.0.0.1:$PORT$TARGET" "$DURATION" "$conns" "$THREADS" \
      | awk '{print $1}' >> "$file"
  done

  awk -v d="$driver" -v c="$conns" '
    { v[NR] = $1 }
    END {
      n = asort(v)
      med = v[int((n + 1) / 2)]
      lo = v[1]; hi = v[n]
      slow = 0
      for (i = 1; i <= n; i++) if (v[i] < 0.95 * med) slow++
      printf "%-8s %5s %10.0f %10.0f %10.0f %8.1f%% %8d\n",
             d, c, med, lo, hi, (hi - lo) / med * 100, slow
    }' "$file"
}

echo "target $TARGET, $WINDOWS windows of $DURATION at each point"
echo
printf "%-8s %5s %10s %10s %10s %9s %8s\n" \
  driver conns median min max spread "slow(<5%)"
printf "%-8s %5s %10s %10s %10s %9s %8s\n" \
  -------- ----- ---------- ---------- ---------- --------- --------

start pgmoon
sweep pgmoon 16

start pq
# 6 connections puts pq at roughly pgmoon's throughput; 16 is where the
# published comparison ran it.
sweep pq 6
sweep pq 16

echo
echo "If pq at 6 is as smooth as pgmoon at 16, the inconsistency belongs to the"
echo "operating point and not to the driver."
