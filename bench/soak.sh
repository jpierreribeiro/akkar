#!/usr/bin/env bash
#
# Sustained load, because every other measurement here is fifteen seconds.
#
# Fifteen seconds says nothing about the questions that actually decide whether
# something survives production:
#
#   * does the Lua heap grow without bound, or settle?
#   * does RSS grow when the heap does not, which would point at the C side --
#     socket buffers, TLS contexts, a driver holding on to something?
#   * do connections leak back to Postgres over hours?
#   * does latency drift upward as the process ages?
#
# The server's own /metrics is the instrument, which means this also exercises
# the observability under the same load it is reporting on.
#
#   bash bench/soak.sh [minutes] [processes]
set -uo pipefail

MINUTES="${1:-30}"
PROCESSES="${2:-3}"
PORT="${PORT:-8300}"
CONNECTIONS="${CONNECTIONS:-50}"
THREADS="${THREADS:-2}"
TARGET="${TARGET:-/users/42}"
POOL="${POOL:-10}"
SAMPLE_EVERY="${SAMPLE_EVERY:-60}"
OUT="${OUT:-bench/soak-$(date +%Y%m%d-%H%M).tsv}"

command -v wrk >/dev/null || { echo "wrk is not installed"; exit 1; }

cleanup() { pkill -f "bench/serve.lua $PORT" 2>/dev/null; sleep 0.5; }
trap cleanup EXIT

echo "# soak: ${MINUTES}m, $PROCESSES processes, $CONNECTIONS connections on $TARGET"
echo "# machine: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs), $(nproc) threads"
echo "# started: $(date -Is)"
echo "# output : $OUT"
echo

cleanup
for _ in $(seq 1 "$PROCESSES"); do
  lua5.4 bench/serve.lua "$PORT" "$POOL" >/dev/null 2>&1 &
done
sleep 3

alive=$(pgrep -fc "bench/serve.lua $PORT" || echo 0)
[ "$alive" -eq "$PROCESSES" ] || { echo "only $alive/$PROCESSES processes alive"; exit 1; }
curl -sf --max-time 5 "http://127.0.0.1:$PORT$TARGET" >/dev/null || { echo "server not answering"; exit 1; }

# Load runs for the whole window in the background.
wrk -t"$THREADS" -c"$CONNECTIONS" -d"${MINUTES}m" --latency \
    "http://127.0.0.1:$PORT$TARGET" > /tmp/soak-wrk.out 2>&1 &
WRK=$!

printf "elapsed_s\tlua_heap_kb\trss_kb\tpool_live\tpool_idle\tpg_conns\treq_total\n" > "$OUT"

START=$(date +%s)
END=$(( START + MINUTES * 60 ))
while [ "$(date +%s)" -lt "$END" ]; do
  sleep "$SAMPLE_EVERY"
  now=$(date +%s)
  scrape=$(curl -s --max-time 10 "http://127.0.0.1:$PORT/metrics" 2>/dev/null)
  [ -z "$scrape" ] && continue

  heap=$(echo "$scrape" | awk '/^akkar_lua_heap_bytes/ {printf "%.0f", $2/1024}')
  rss=$(echo  "$scrape" | awk '/^akkar_process_resident_bytes/ {printf "%.0f", $2/1024}')
  live=$(echo "$scrape" | awk '/^akkar_db_pool_live/ {print $2}')
  idle=$(echo "$scrape" | awk '/^akkar_db_pool_idle/ {print $2}')
  total=$(echo "$scrape" | awk '/^akkar_requests_total/ {s+=$2} END {print s+0}')
  pg=$(sudo docker exec akkar-pg psql -U postgres -d akkar -tAc \
        "select count(*) from pg_stat_activity where datname='akkar'" 2>/dev/null | tr -d ' ')

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$(( now - START ))" "${heap:-0}" "${rss:-0}" "${live:-0}" "${idle:-0}" "${pg:-0}" "${total:-0}" \
    | tee -a "$OUT"
done

wait $WRK 2>/dev/null
echo
echo "# load summary"
grep -E 'Requests/sec|Latency|Non-2xx|Socket errors' /tmp/soak-wrk.out | sed 's/^/  /'

echo
echo "# drift, first sample against last"
awk 'NR==2 {h=$2; r=$3} END {
  printf "  lua heap : %s -> %s KB", h, $2
  if (h+0 > 0) printf "  (%+.1f%%)", ($2-h)/h*100
  printf "\n  rss      : %s -> %s KB", r, $3
  if (r+0 > 0) printf "  (%+.1f%%)", ($3-r)/r*100
  printf "\n  pg conns : %s at the end\n", $6
}' "$OUT"
echo
echo "  A heap that settles is healthy.  A heap that settles while RSS keeps"
echo "  climbing points at the C side, not at Lua."
