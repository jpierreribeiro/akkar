#!/usr/bin/env bash
# Why does akkar.pq lose a whole window twice in thirty?
#
# `bench/driver/RESULTS.md` §5.4 is the only thing keeping pgmoon as the
# default. Across thirty ten-second windows pgmoon produced no anomalous ones
# and `akkar.pq` produced two, where a window ran at pgmoon's speed and then
# went back to being fast. No explanation was measured, so the driver stayed
# off.
#
# ONE FACT NARROWS IT SHARPLY: in a slow window p50 rose along with p99. That is
# not one request stalling, it is the whole window being slower -- which points
# outside the driver.
#
# THE HYPOTHESIS THIS TESTS. pgmoon spends so much time in the interpreter that
# Postgres is never its bottleneck. `akkar.pq` is fast enough that Postgres is.
# So a Postgres hiccup -- a checkpoint, an autovacuum, buffer eviction --
# changes pq's throughput and is invisible in pgmoon's. If that is right, the
# "driver inconsistency" is not the driver at all, and the two anomalous
# windows should line up with Postgres doing something.
#
# So every window records what Postgres did during it, not only what akkar did.
source "$(dirname "$0")/../study/lib.sh"
detect_topology || exit 1
verify_reservation || exit 1

ROOT=${ROOT:-$HOME/akkar}
APPS=${APPS:-$HOME/study/apps}
PORT=${PORT:-8500}
WINDOWS=${WINDOWS:-40}
DURATION=${DURATION:-10s}
CONNS=${CONNS:-16}
THREADS=${THREADS:-4}
PROCS=${PROCS:-2}
TARGET=${TARGET:-/rows/100}
PG=akkar-pg

psql_one() { sudo docker exec "$PG" psql -U postgres -d akkar -tAc "$1" 2>/dev/null | tr -d ' '; }

stop_all() { pkill -f "study/apps/serve[.]lua" 2>/dev/null; sleep 2; }
trap stop_all EXIT

start() {   # driver
  local driver=$1
  stop_all
  local log=/tmp/anomaly-boot.log; : > "$log"
  for _ in $(seq 1 "$PROCS"); do
    AKKAR_ROOT="$ROOT" AKKAR_LEAN=0 AKKAR_DRIVER="$driver" \
      setsid taskset -c "$SERVERS" \
      lua5.4 "$APPS/serve.lua" "$PORT" 10 </dev/null >/dev/null 2>>"$log" &
    disown
  done
  sleep 4
  verify_running "study/apps/serve[.]lua" "$PROCS" "akkar/$driver" || exit 1
  local seen; seen=$(grep -c "^driver=$driver$" "$log"); [ "${seen:-0}" -eq "$PROCS" ] \
    || { echo "REFUSING: $seen of $PROCS reported driver=$driver"; exit 1; }
}

# What Postgres was doing, sampled either side of a window.
#
# `checkpoints_timed` and `checkpoints_req` count checkpoints; `buffers_checkpoint`
# is how much they wrote. `blks_read` is cache misses that went to disk. Any of
# them moving during a window is a candidate explanation for that window.
pg_stats() {
  local ck bck blks
  ck=$(psql_one "select checkpoints_timed + checkpoints_req from pg_stat_bgwriter")
  bck=$(psql_one "select buffers_checkpoint from pg_stat_bgwriter")
  blks=$(psql_one "select blks_read from pg_stat_database where datname='akkar'")
  echo "${ck:-0} ${bck:-0} ${blks:-0}"
}

echo "target $TARGET at $CONNS connections, $WINDOWS windows of $DURATION per driver"
echo "cores $SERVERS, generator $GENERATOR, $PROCS processes"
echo

run_driver() {   # driver
  local driver=$1
  start "$driver"
  taskset -c "$GENERATOR" wrk -t"$THREADS" -c"$CONNS" -d5s \
    "http://127.0.0.1:$PORT$TARGET" >/dev/null 2>&1      # warm-up

  echo "=== $driver ==="
  printf "%-4s %10s %10s %10s %8s %8s %10s\n" \
    win req/s p50 p99 ckpt buf_ck blks_read
  local n=0
  for w in $(seq 1 "$WINDOWS"); do
    read -r ck0 bck0 blk0 <<< "$(pg_stats)"
    local line
    line=$(run_wrk "http://127.0.0.1:$PORT$TARGET" "$DURATION" "$CONNS" "$THREADS") \
      || { echo "  window $w INVALID"; continue; }
    read -r ck1 bck1 blk1 <<< "$(pg_stats)"

    local rps p50 p99
    rps=$(echo "$line" | awk '{print $1}')
    p50=$(echo "$line" | awk '{print $2}')
    p99=$(echo "$line" | awk '{print $3}')
    printf "%-4s %10s %10s %10s %8s %8s %10s\n" "$w" "$rps" "$p50" "$p99" \
      "$(( ${ck1:-0} - ${ck0:-0} ))" "$(( ${bck1:-0} - ${bck0:-0} ))" \
      "$(( ${blk1:-0} - ${blk0:-0} ))"
    n=$((n + 1))
  done
  echo
}

run_driver pgmoon
run_driver pq

echo "ckpt = checkpoints that completed during the window"
echo "buf_ck = buffers those checkpoints wrote"
echo "blks_read = reads that missed the buffer cache"
echo
echo "A slow window that lines up with any of them is Postgres, not the driver."
