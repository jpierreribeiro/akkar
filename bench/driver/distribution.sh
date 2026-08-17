#!/usr/bin/env bash
# Is the "driver inconsistency" the way connections land on processes?
#
# On a verifiably idle box, `rate-matched.sh` produced the opposite of what the
# published claim says:
#
#     pgmoon @16    spread  1.4%   0 slow windows
#     pq     @6     spread 30.8%   4 slow windows
#     pq     @16    spread  2.8%   0 slow windows
#
# The driver is ragged at LOW concurrency and smooth at high, which no property
# of a driver explains -- and one property of the HARNESS does.
#
# `SO_REUSEPORT` distributes connections across the listening processes by
# hashing the four-tuple. With sixteen connections over two processes the split
# is eight and eight, near enough, every time. With six it can be three and
# three, or four and two, or five and one -- and it is re-drawn every time wrk
# reconnects, which is every window. An uneven split leaves one process idle
# while the other queues, and that costs throughput for the whole window.
#
# Two tests:
#
#   1. The same six connections against ONE process. If the raggedness is the
#      split, one process cannot be split and the spread should collapse.
#   2. `/users/42`, which is where the published anomaly was measured, to find
#      out whether it reproduces at all today.
source "$(dirname "$0")/../study/lib.sh"
detect_topology || exit 1
verify_reservation || exit 1

ROOT=${ROOT:-$HOME/akkar}
APPS=${APPS:-$HOME/study/apps}
PORT=${PORT:-8500}
WINDOWS=${WINDOWS:-16}
DURATION=${DURATION:-10s}
THREADS=${THREADS:-4}

stop_all() { pkill -f "study/apps/serve[.]lua" 2>/dev/null; sleep 2; }
trap stop_all EXIT

start() {   # driver, processes
  local driver=$1 procs=$2
  stop_all
  local log=/tmp/dist-boot.log; : > "$log"
  for _ in $(seq 1 "$procs"); do
    AKKAR_ROOT="$ROOT" AKKAR_LEAN=0 AKKAR_DRIVER="$driver" \
      setsid taskset -c "$SERVERS" \
      lua5.4 "$APPS/serve.lua" "$PORT" 10 </dev/null >/dev/null 2>>"$log" &
    disown
  done
  sleep 4
  verify_running "study/apps/serve[.]lua" "$procs" "akkar/$driver x$procs" || exit 1
}

sweep() {   # label, target, connections
  local label=$1 target=$2 conns=$3
  taskset -c "$GENERATOR" wrk -t"$THREADS" -c"$conns" -d5s \
    "http://127.0.0.1:$PORT$target" >/dev/null 2>&1
  local file=/tmp/dist-$$; : > "$file"
  for _ in $(seq 1 "$WINDOWS"); do
    run_wrk "http://127.0.0.1:$PORT$target" "$DURATION" "$conns" "$THREADS" \
      | awk '{print $1}' >> "$file"
  done
  awk -v l="$label" '
    { v[NR] = $1 }
    END {
      n = asort(v); med = v[int((n + 1) / 2)]
      slow = 0; for (i = 1; i <= n; i++) if (v[i] < 0.95 * med) slow++
      printf "%-34s %10.0f %10.0f %10.0f %8.1f%% %8d\n",
             l, med, v[1], v[n], (v[n] - v[1]) / med * 100, slow
    }' "$file"
  rm -f "$file"
}

printf "%-34s %10s %10s %10s %9s %8s\n" \
  configuration median min max spread "slow(<5%)"
printf "%-34s %10s %10s %10s %9s %8s\n" \
  ---------------------------------- ---------- ---------- ---------- --------- --------

# 1. The split.
start pq 2; sweep "pq /rows/100 @6, TWO processes"  /rows/100 6
start pq 1; sweep "pq /rows/100 @6, ONE process"    /rows/100 6
start pq 1; sweep "pq /rows/100 @16, ONE process"   /rows/100 16

echo
# 2. Where the published anomaly was measured.
start pq 2;     sweep "pq /users/42 @16, two processes"     /users/42 16
start pgmoon 2; sweep "pgmoon /users/42 @16, two processes" /users/42 16

echo
echo "If one process is smooth at six connections and two are not, the"
echo "raggedness is SO_REUSEPORT dividing a small number of connections."
