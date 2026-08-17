#!/usr/bin/env bash
# Does a Postgres checkpoint cost the C driver what it costs pgmoon?
#
# `anomaly.sh` found the correlation: across forty windows each, pgmoon's worst
# was 2% off its median and pq's worst was 11% off -- and pq's worst window is
# the one window in which a checkpoint completed. pgmoon had a checkpoint too,
# in its window 27, and did not notice it.
#
# That is n=1 on each side. This forces the event instead of waiting for it:
# alternating windows with and without an explicit `CHECKPOINT`, on both
# drivers, so the mechanism is demonstrated rather than correlated once.
#
# THE MECHANISM UNDER TEST. pgmoon spends so long in the interpreter that
# Postgres is never its bottleneck, so Postgres pausing does not change its
# throughput. akkar.pq is fast enough that Postgres IS the bottleneck, so it
# does. If that is right, pq loses throughput on checkpoint windows and pgmoon
# loses none -- and pgmoon's famous consistency is not a virtue of pgmoon, it
# is the consistency of something that is not the bottleneck.
source "$(dirname "$0")/../study/lib.sh"
detect_topology || exit 1
verify_reservation || exit 1

ROOT=${ROOT:-$HOME/akkar}
APPS=${APPS:-$HOME/study/apps}
PORT=${PORT:-8500}
ROUNDS=${ROUNDS:-6}
DURATION=${DURATION:-10s}
CONNS=${CONNS:-16}
THREADS=${THREADS:-4}
PROCS=${PROCS:-2}
TARGET=${TARGET:-/rows/100}
PG=akkar-pg

stop_all() { pkill -f "study/apps/serve[.]lua" 2>/dev/null; sleep 2; }
trap stop_all EXIT

start() {
  local driver=$1
  stop_all
  local log=/tmp/ckpt-boot.log; : > "$log"
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

# Issues a CHECKPOINT a second into the window, so it lands while the window is
# being measured rather than between windows.
checkpoint_soon() {
  ( sleep 1
    sudo docker exec "$PG" psql -U postgres -d akkar -c "CHECKPOINT" >/dev/null 2>&1
  ) &
}

median() { sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}'; }

run_driver() {
  local driver=$1
  start "$driver"
  taskset -c "$GENERATOR" wrk -t"$THREADS" -c"$CONNS" -d5s \
    "http://127.0.0.1:$PORT$TARGET" >/dev/null 2>&1

  local quiet="" forced=""
  echo "=== $driver ==="
  printf "%-7s %10s %10s %10s\n" round quiet forced delta
  for r in $(seq 1 "$ROUNDS"); do
    # Quiet window first, then a window with a checkpoint in it. Alternating
    # rather than blocked, so drift cannot be handed to one of them.
    local q f
    q=$(run_wrk "http://127.0.0.1:$PORT$TARGET" "$DURATION" "$CONNS" "$THREADS" | awk '{print $1}')
    checkpoint_soon
    f=$(run_wrk "http://127.0.0.1:$PORT$TARGET" "$DURATION" "$CONNS" "$THREADS" | awk '{print $1}')
    wait 2>/dev/null

    printf "%-7s %10s %10s %9s%%\n" "$r" "$q" "$f" \
      "$(awk -v a="$q" -v b="$f" 'BEGIN{printf "%+.1f", (b-a)/a*100}')"
    echo "$q" >> "/tmp/ckpt-$driver-quiet"
    echo "$f" >> "/tmp/ckpt-$driver-forced"
  done

  local mq mf
  mq=$(median < "/tmp/ckpt-$driver-quiet")
  mf=$(median < "/tmp/ckpt-$driver-forced")
  printf "%-7s %10s %10s %9s%%   <- medians\n" "" "$mq" "$mf" \
    "$(awk -v a="$mq" -v b="$mf" 'BEGIN{printf "%+.1f", (b-a)/a*100}')"
  echo
}

rm -f /tmp/ckpt-*-quiet /tmp/ckpt-*-forced
echo "target $TARGET at $CONNS connections, $ROUNDS rounds per driver,"
echo "each round = one quiet window then one window with a forced CHECKPOINT"
echo

run_driver pgmoon
run_driver pq
