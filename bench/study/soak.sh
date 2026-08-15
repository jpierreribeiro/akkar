#!/usr/bin/env bash
# Sustained load, because every other figure in this study is ten seconds.
#
# A ten-second run cannot see the three things that actually take a service
# down overnight: memory that climbs, descriptors that are never returned, and
# throughput that decays. So this measures DRIFT rather than a number -- the
# last quarter against the first -- and samples the resources alongside.
#
# The route mixes framework work and database work, because a leak in the
# connection pool never shows on /ping and a leak in the deadline controller
# never shows anywhere else.
source "$(dirname "$0")/lib.sh"
detect_topology || exit 1
verify_reservation || exit 1

PORT=${PORT:-8501}
MINUTES=${MINUTES:-45}
CONNS=${CONNS:-16}
THREADS=${THREADS:-4}
PROCS=${PROCS:-$SERVER_CORES}
POOL=${POOL:-10}
SAMPLE=${SAMPLE:-60}         # seconds per sample
APPS=$HOME/study/apps
TREE=$HOME/study/head

stop() { pkill -f "study/apps/serve[.]lua" 2>/dev/null; sleep 2; }
trap stop EXIT
stop

for _ in $(seq 1 "$PROCS"); do
  AKKAR_ROOT="$TREE" setsid taskset -c "$SERVERS" \
    lua5.4 "$APPS/serve.lua" "$PORT" "$POOL" </dev/null >/dev/null 2>&1 & disown
done
sleep 4
verify_running "study/apps/serve[.]lua" "$PROCS" "akkar soak" || exit 1

body=$(probe_body "http://127.0.0.1:$PORT/users/42") || { echo "REFUSING: $body"; exit 1; }
echo "# soak: $MINUTES minutes, $PROCS processes, pool $POOL, $CONNS connections"
echo "# route /users/42, answering: $body"
echo "# $(date -u +%FT%TZ)  machine $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
echo
printf "%-6s %10s %9s %9s %8s %7s %6s %6s\n" \
  min req/s p50 p99 rss_mb fds pg errors

samples=$((MINUTES * 60 / SAMPLE))
for i in $(seq 1 "$samples"); do
  out=$(taskset -c "$GENERATOR" wrk -t"$THREADS" -c"$CONNS" -d"${SAMPLE}s" \
        --timeout 10s --latency "http://127.0.0.1:$PORT/users/42" 2>/dev/null)

  rps=$(echo "$out" | awk '/Requests\/sec/{print $2}')
  p50=$(echo "$out" | awk '/^ *50%/{print $2}')
  p99=$(echo "$out" | awk '/^ *99%/{print $2}')
  errs=$(echo "$out" | grep -cE 'Non-2xx|Socket errors')

  # Summed across the server processes: one leaking is a leak.
  rss=0; fds=0
  for pid in $(pgrep -f "study/apps/serve[.]lua"); do
    rss=$(( rss + $(awk '/VmRSS/{print $2}' /proc/$pid/status 2>/dev/null || echo 0) ))
    fds=$(( fds + $(ls /proc/$pid/fd 2>/dev/null | wc -l) ))
  done
  pg=$(sudo docker exec akkar-pg psql -U postgres -d akkar -tAc \
       "select count(*) from pg_stat_activity where datname='akkar'" 2>/dev/null | tr -d ' ')

  printf "%-6s %10s %9s %9s %8s %7s %6s %6s\n" \
    "$((i * SAMPLE / 60))" "$rps" "$p50" "$p99" "$((rss / 1024))" "$fds" "${pg:-?}" "$errs"
done
