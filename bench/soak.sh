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
set -euo pipefail

MINUTES="${1:-30}"
PROCESSES="${2:-3}"
PORT="${PORT:-8300}"
CONNECTIONS="${CONNECTIONS:-50}"
THREADS="${THREADS:-2}"
TARGET="${TARGET:-/users/42}"
POOL="${POOL:-10}"
SAMPLE_EVERY="${SAMPLE_EVERY:-60}"
OUT="${OUT:-bench/soak-$(date +%Y%m%d-%H%M).tsv}"
SOAK_ASSERT="${SOAK_ASSERT:-0}"
PG_CONTAINER="${PG_CONTAINER:-}"

command -v wrk >/dev/null || { echo "wrk is not installed"; exit 1; }
[[ "$MINUTES" =~ ^[1-9][0-9]*$ && "$PROCESSES" =~ ^[1-9][0-9]*$ ]] || exit 2
[[ "$SAMPLE_EVERY" =~ ^[1-9][0-9]*$ ]] || exit 2
if [ "${BENCH_NO_DB:-0}" = 1 ] && [ "$TARGET" != /ping ]; then
  echo "BENCH_NO_DB=1 requires TARGET=/ping" >&2; exit 2
fi

PIDS=()
WRK=""
WRK_OUT="$(mktemp "${TMPDIR:-/tmp}/akkar-soak-wrk.XXXXXX")"
cleanup() {
  [ -z "$WRK" ] || kill "$WRK" 2>/dev/null || true
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  rm -f "$WRK_OUT"
}
trap cleanup EXIT

echo "# soak: ${MINUTES}m, $PROCESSES processes, $CONNECTIONS connections on $TARGET"
echo "# machine: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs), $(nproc) threads"
echo "# started: $(date -Is)"
echo "# output : $OUT"
echo
{
  date -Is
  uname -a
  lua5.4 -v
  git rev-parse HEAD
  git diff --binary | sha256sum
  lua5.4 -e 'print("cqueues=" .. tostring(require("cqueues").COMMIT or "unknown"))'
  echo "minutes=$MINUTES processes=$PROCESSES target=$TARGET connections=$CONNECTIONS"
  echo "sample_every=$SAMPLE_EVERY pg_probe=${PG_CONTAINER:-disabled}"
} > "$OUT.meta"

for _ in $(seq 1 "$PROCESSES"); do
  lua5.4 bench/serve.lua "$PORT" "$POOL" >/dev/null 2>&1 &
  PIDS+=("$!")
done
sleep 3

alive=0
for pid in "${PIDS[@]}"; do
  kill -0 "$pid" 2>/dev/null && alive=$((alive + 1))
done
[ "$alive" -eq "$PROCESSES" ] || { echo "only $alive/$PROCESSES processes alive"; exit 1; }
curl -sf --max-time 5 "http://127.0.0.1:$PORT$TARGET" >/dev/null || { echo "server not answering"; exit 1; }

# Load runs for the whole window in the background.
wrk -t"$THREADS" -c"$CONNECTIONS" -d"${MINUTES}m" --latency \
    "http://127.0.0.1:$PORT$TARGET" > "$WRK_OUT" 2>&1 &
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
  pg=NA
  [ "${BENCH_NO_DB:-0}" != 1 ] || pg=0
  if [ -n "$PG_CONTAINER" ]; then
    pg=$(docker exec "$PG_CONTAINER" psql -U "${PGUSER:-postgres}" -d "${PGDATABASE:-akkar}" -tAc \
      "select count(*) from pg_stat_activity where datname=current_database()" | tr -d ' ')
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$(( now - START ))" "${heap:-0}" "${rss:-0}" "${live:-0}" "${idle:-0}" "${pg:-0}" "${total:-0}" \
    | tee -a "$OUT"
done

set +e
wait "$WRK" 2>/dev/null
wrk_status=$?
set -e
WRK=""
echo
echo "# load summary"
cp "$WRK_OUT" "$OUT.wrk.txt"
grep -E 'Requests/sec|Latency|Non-2xx|Socket errors' "$WRK_OUT" | sed 's/^/  /'
if [ "$wrk_status" -ne 0 ]; then
  echo "load generator exited with status $wrk_status" >&2
  exit "$wrk_status"
fi
if grep -Eq 'Non-2xx or 3xx responses: [1-9]|Socket errors:.*[1-9]' "$WRK_OUT"; then
  echo "load generator reported HTTP or socket errors" >&2
  exit 1
fi

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

if [ "$SOAK_ASSERT" = "1" ]; then
  [ "$PROCESSES" -eq 1 ] || {
    echo "SOAK_ASSERT requires one process because /metrics is process-local" >&2
    exit 1
  }
  lua5.4 bench/certify/soak-check.lua "$OUT"
fi
