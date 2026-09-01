#!/usr/bin/env bash
# The run the backlog has owed since the study: what happens ABOVE capacity.
#
# The 45-minute soak used 16 connections against a capacity of 20, so nothing
# ever queued. It proved the absence of a leak and said nothing about the
# regime an incident actually happens in. This one holds the pool fixed and
# sweeps offered concurrency from half capacity to four times it.
#
# THE PREDICTION, RECORDED BEFORE THE MEASUREMENT, per `bench/compare/METHOD.md`:
#
#   1. Throughput is flat from about 1.0x capacity onward. Past the pool, more
#      concurrency buys queue, not answers.
#   2. p50 stays near the service time; p99 grows roughly linearly with
#      offered concurrency once past capacity.
#   3. Time spent waiting for a connection becomes the majority of p99 above
#      2x, which is the thing `akkar_pool_waited` was added to show.
#   4. Errors stay at zero throughout: queuing is not failing, and the point
#      of the deadline is that it converts a queue into a refusal rather than
#      into a timeout.
#
# Anything that disagrees with these four is the finding.
source "$(dirname "$0")/lib.sh"
detect_topology || exit 1
verify_reservation || exit 1

PORT=${PORT:-8502}
POOL=${POOL:-10}
PROCS=${PROCS:-$SERVER_CORES}
DURATION=${DURATION:-30s}
THREADS=${THREADS:-4}
REPS=${REPS:-3}
# Overridable, like every other sweeper here -- `floors.sh:19`, `gc-cost.sh:24`,
# `cpu-parity.sh` and `regression.sh` all take these from the environment. This
# was the one that could not be pointed at a checkout, which is why the run it
# owes has only ever happened on the study box.
APPS=${APPS:-$HOME/study/apps}
TREE=${TREE:-$HOME/study/head}

CAPACITY=$((PROCS * POOL))

stop() { pkill -f "study/apps/serve[.]lua" 2>/dev/null; sleep 2; }
trap stop EXIT
stop

for _ in $(seq 1 "$PROCS"); do
  AKKAR_ROOT="$TREE" setsid taskset -c "$SERVERS" \
    lua5.4 "$APPS/serve.lua" "$PORT" "$POOL" </dev/null >/dev/null 2>&1 & disown
done
sleep 4
verify_running "study/apps/serve[.]lua" "$PROCS" "akkar saturation" || exit 1

body=$(probe_body "http://127.0.0.1:$PORT/users/42") || { echo "REFUSING: $body"; exit 1; }
echo "# saturation: $PROCS processes, pool $POOL each, capacity $CAPACITY connections"
echo "# route /users/42, answering: $body"
echo "# $(date -u +%FT%TZ)  $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
echo
printf "%-6s %-8s %10s %9s %9s %8s\n" mult conns req/s p50 p99 errors

# 0.5x to 4x capacity. The interesting part is the knee, so the low end is
# sampled as finely as the high end.
for mult in 0.5 0.75 1 1.25 1.5 2 3 4; do
  conns=$(awk -v c="$CAPACITY" -v m="$mult" 'BEGIN { printf "%d", c * m }')
  [ "$conns" -lt "$THREADS" ] && conns=$THREADS

  # MEDIAN, AND IT WAS NOT ONE. This loop kept the run with the HIGHEST
  # throughput while the comment above it said "median", so every published
  # figure was a best-of-three dressed as a middle-of-three -- optimistic by
  # construction, and worst precisely where the variance is highest, which on
  # a saturation curve is past the knee. `bench/study/RESULTS.md` section 8
  # carries the retraction.
  #
  # The rows are collected and sorted now, and the middle one is taken whole
  # so that the three numbers on a line still come from ONE run rather than
  # from three different ones.
  runs=""; errors=0
  for _ in $(seq 1 "$REPS"); do
    # `run_wrk url duration conns threads` -- the order matters and getting it
    # wrong reports INVALID for every row, which looks like a saturated server
    # rather than a mistyped call.
    read -r rps p50 p99 < <(run_wrk "http://127.0.0.1:$PORT/users/42" \
      "$DURATION" "$conns" "$THREADS") || { errors=$((errors + 1)); continue; }
    runs="${runs}${rps} ${p50} ${p99}"$'\n'
  done

  # Nearest-rank median: sort by throughput, take row ceil(n/2).
  read -r med_rps med_p50 med_p99 < <(
    printf '%s' "$runs" | grep -v '^$' | sort -g -k1,1 |
    awk '{ row[NR] = $0 } END { if (NR) print row[int((NR + 1) / 2)] }'
  )

  printf "%-6s %-8s %10s %9s %9s %8s\n" \
    "${mult}x" "$conns" "${med_rps:-INVALID}" "${med_p50:--}" "${med_p99:--}" "$errors"
done

echo
echo "# pool waits, summed across the server processes:"
curl -s "http://127.0.0.1:$PORT/metrics" 2>/dev/null | grep -E "akkar_pool|akkar_requests_total" | head -20
