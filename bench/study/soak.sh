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

# THE ANSWER IS CAPTURED ONCE AND COMPARED FOREVER.
#
# The eight-hour run this script produced measured memory, descriptors and
# throughput -- and never once checked that the server was still returning the
# right row. A process that starts answering somebody else's user at hour six,
# or truncating a field, or serving a cached body for a different id, passes
# that soak perfectly: RSS flat, no errors, throughput unchanged.
#
# `docs/UNKNOWNS.md` listed it as "correctness over time, as opposed to
# resources over time", and it is the cheapest of the three gaps on that list:
# one curl per sample against a body we already fetch at startup.
EXPECTED=$(probe_body "http://127.0.0.1:$PORT/users/42") \
  || { echo "REFUSING: $EXPECTED"; exit 1; }
body="$EXPECTED"
echo "# soak: $MINUTES minutes, $PROCS processes, pool $POOL, $CONNS connections"
echo "# route /users/42, answering: $body"
echo "# $(date -u +%FT%TZ)  machine $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
echo
printf "%-6s %10s %9s %9s %8s %8s %7s %6s %6s %6s\n" \
  min req/s p50 p99 rss_mb heap_mb fds pg errors wrong

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

  # THE LUA HEAP, BESIDE RSS, BECAUSE RSS ALONE CANNOT NAME THE FAILURE.
  #
  # RSS climbing with the heap is a table akkar is holding: a defect, and ours.
  # RSS climbing while the heap is FLAT is memory the collector released and
  # the C allocator did not return to the kernel: fragmentation or arena
  # growth, which no amount of reading Lua finds. Opposite fixes, and this
  # project has already spent an afternoon blaming a commit for what turned
  # out to be one 1,024 KB allocator step.
  #
  # One process is sampled rather than all of them, because the heap is
  # per-VM and summing figures from independent VMs would produce a number
  # that is not any VM's heap.
  heap=$(curl -s -m 2 "http://127.0.0.1:$PORT/heap" 2>/dev/null \
         | grep -o '"kb":[0-9.]*' | cut -d: -f2)

  # The correctness sample. One request, compared byte for byte against what
  # the same route answered before the load started.
  #
  # Byte for byte and not "looks about right": a field that starts arriving as
  # a float, a key that changes order because something was rebuilt, a
  # truncated email -- each is a real defect and each survives a looser check.
  # ONE CAVEAT, found while proving the check fires. cjson's key order is
  # stable within a process but not across one, so if the server RESTARTS
  # mid-soak the order can change and this reports a divergence for a body
  # that is semantically identical.
  #
  # Left as a divergence on purpose rather than normalised away: a server
  # restarting in the middle of a soak is itself the finding, and a check that
  # hid it would be worse than one that occasionally over-reports. The
  # expected and actual bodies are both printed, so telling the two cases
  # apart takes one glance.
  #
  # Proven to fire: a server rigged to answer a different row after the third
  # request was caught on the third sample and every one after it.
  now_body=$(curl -s --max-time 5 "http://127.0.0.1:$PORT/users/42" 2>/dev/null)
  if [ "$now_body" = "$EXPECTED" ]; then
    wrong=0
  else
    wrong=1
    # Printed once, in full, rather than only counted -- a divergence at hour
    # six is the whole finding and a bare 1 in a column would not say what
    # changed.
    echo "# DIVERGED at minute $((i * SAMPLE / 60))"
    echo "#   expected: $EXPECTED"
    echo "#   got     : ${now_body:-<nothing>}"
  fi

  printf "%-6s %10s %9s %9s %8s %8s %7s %6s %6s %6s\n" \
    "$((i * SAMPLE / 60))" "$rps" "$p50" "$p99" "$((rss / 1024))" \
    "$(awk -v k="${heap:-0}" 'BEGIN{printf "%.1f", k/1024}')" "$fds" \
    "${pg:-?}" "$errs" "$wrong"
done
