#!/usr/bin/env bash
# The driver through HTTP, which is the measurement that was missing.
#
# `bench/driver/RESULTS.md` measured `akkar.pq` against pgmoon in isolation:
# one connection, one query at a time, no server, no pool, no concurrency, on
# a laptop. Every OTHER measurement in this repository -- the comparison
# against Gin and FastAPI, the saturation sweep, the eight-hour soak -- ran
# pgmoon, because pgmoon is the default and no benchmark server ever passed
# `driver`. So the driver's effect on a REQUEST has never been measured, and
# §4 of that page says so in as many words.
#
# This closes it, on the study machine, through the study's own gates.
#
# What it is built to be able to report as "no":
#
#   * `/ping` touches no database. If the two variants differ there, the
#     harness is measuring itself and every other row is void. It is the
#     control, and it is listed first on purpose.
#   * `/users/42` is one row, and the isolated benchmark says one row does not
#     clear the noise gate (1.09x, OVERLAPPING). The prediction on record is
#     that the headline number does NOT move. A run that cannot reproduce a
#     published prediction is worth more than one that confirms it.
#   * The row sweep is where the 6.1x in driver cost lives, if it survives
#     the trip through HTTP, JSON encoding and the pool.
#
# usage: end-to-end.sh            (all targets)
#        REPS=3 DURATION=5s end-to-end.sh
source "$(dirname "$0")/../study/lib.sh"
detect_topology || exit 1
verify_reservation || exit 1

ROOT=${ROOT:-$HOME/akkar}
APPS=$ROOT/bench/study/apps
PORT=${PORT:-8500}
DURATION=${DURATION:-10s}
REPS=${REPS:-5}
POOL=${POOL:-10}
PROCS=${PROCS:-$SERVER_CORES}
OUT=${OUT:-$HOME/driver-e2e}
mkdir -p "$OUT"

# path:connections:threads
#
# Concurrency is chosen per route rather than globally. `/ping` at 100 is the
# framework under load; the database routes run at 16 against a total pool of
# PROCS x POOL, because measuring at a concurrency the pool cannot serve
# reports queue depth wearing a latency label -- part 3 of the study exists
# because of that mistake. The last line is deliberate saturation: it is where
# "the event loop is blocked for 3.9ms per query" should show up as a tail, and
# that effect is named as unmeasured in the driver page.
#
# Overridable, so a single route that behaved oddly can be re-measured on its
# own without re-running the whole sweep:
#
#   TARGETS="/users/42:16:4" REPS=8 end-to-end.sh
#
if [ -n "${TARGETS:-}" ]; then read -r -a TARGETS <<< "$TARGETS"; else
TARGETS=(
  "/ping:100:4"
  "/users/42:16:4"
  "/rows/10:16:4"
  "/rows/100:16:4"
  "/rows/1000:16:4"
  "/rows/1000:100:4"
)
fi

stop_all() {
  pkill -f "study/apps/serve[.]lua" 2>/dev/null
  sleep 2
  # A killed client is not a closed backend, and starting the next variant
  # into an exhausted max_connections fails for a reason that has nothing to
  # do with the driver.
  for _ in $(seq 1 40); do
    local n; n=$(sudo docker exec akkar-pg psql -U postgres -d akkar -tAc \
      "select count(*) from pg_stat_activity where datname='akkar'" 2>/dev/null | tr -d ' ')
    [ "${n:-99}" -le 5 ] && break
    sleep 0.5
  done
}
trap stop_all EXIT

# Starts PROCS servers on one driver and PROVES which one they took.
#
# The proof is not decoration. `db.connect` returns a factory that opens on
# first use, so a server asked for `pq` with no `pq_native.so` would run
# happily until the first request. serve.lua loads the module at boot and
# prints the name; this reads it back rather than trusting the variable it
# just exported.
start_variant() {
  local driver=$1 cores=$SERVERS
  stop_all
  local log=$OUT/boot-$driver.log
  : > "$log"
  for _ in $(seq 1 "$PROCS"); do
    AKKAR_ROOT="$ROOT" AKKAR_DRIVER="$driver" setsid taskset -c "$cores" \
      lua5.4 "$APPS/serve.lua" "$PORT" "$POOL" </dev/null >/dev/null 2>>"$log" &
    disown
  done
  sleep 4
  verify_running "study/apps/serve[.]lua" "$PROCS" "akkar/$driver" || return 1

  local want; want=$([ "$driver" = pq ] && echo "driver=pq" || echo "driver=pgmoon")
  local seen; seen=$(grep -c "^$want$" "$log" 2>/dev/null); seen=${seen:-0}
  if [ "$seen" -ne "$PROCS" ]; then
    echo "REFUSING: $seen of $PROCS servers reported '$want'."
    echo "  A run that does not know which driver it measured measures nothing."
    sed -n '1,10p' "$log"
    return 1
  fi
  return 0
}

# --------------------------------------------------- semantic equivalence
# Both drivers must return byte-identical JSON on every route before anything
# is timed. Two drivers that disagree about the data are not comparable, and
# the failure mode is specific and real: libpq hands back numerics as strings
# unless told otherwise, so `{"id":42}` against `{"id":"42"}` is exactly the
# kind of difference that would make one variant look faster for having
# encoded less.
equivalence() {
  local ok=0
  start_variant pgmoon || return 1
  declare -gA PGMOON_BODY
  for spec in "${TARGETS[@]}"; do
    local path=${spec%%:*}
    PGMOON_BODY[$path]=$(probe_body "http://127.0.0.1:$PORT$path") || {
      echo "REFUSING: pgmoon returned an unusable body for $path: ${PGMOON_BODY[$path]}"
      return 1; }
  done

  start_variant pq || return 1
  for spec in "${TARGETS[@]}"; do
    local path=${spec%%:*} body
    body=$(probe_body "http://127.0.0.1:$PORT$path") || {
      echo "REFUSING: pq returned an unusable body for $path: $body"; return 1; }
    if [ "$body" != "${PGMOON_BODY[$path]}" ]; then
      echo "REFUSING: the drivers disagree on $path"
      echo "  pgmoon: $(echo "${PGMOON_BODY[$path]}" | cut -c1-160)"
      echo "  pq    : $(echo "$body" | cut -c1-160)"
      ok=1
    fi
  done
  [ "$ok" -eq 0 ] && echo "equivalence: identical bodies on all ${#TARGETS[@]} targets"
  return $ok
}

# ------------------------------------------------------------- measurement
warm() {
  taskset -c "$GENERATOR" wrk -t4 -c16 -d3s \
    "http://127.0.0.1:$PORT/rows/100" >/dev/null 2>&1
  taskset -c "$GENERATOR" wrk -t4 -c100 -d3s \
    "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1
}

# ORDER ALTERNATES PER REPETITION rather than per block. Five runs of pgmoon
# followed by five of pq attributes any drift in the machine -- thermal, page
# cache, another tenant -- to the driver. Restarting both servers every
# repetition costs about eight seconds a round and removes that entirely.
equivalence || exit 1

RETRY_COUNT=0
for spec in "${TARGETS[@]}"; do : > "$OUT/pgmoon${spec//\//_}.txt"; : > "$OUT/pq${spec//\//_}.txt"; done

for rep in $(seq 1 "$REPS"); do
  for driver in pgmoon pq; do
    start_variant "$driver" || exit 1
    warm
    for spec in "${TARGETS[@]}"; do
      IFS=: read -r path conns threads <<< "$spec"
      line=$(run_wrk "http://127.0.0.1:$PORT$path" "$DURATION" "$conns" "$threads") || {
        RETRY_COUNT=$((RETRY_COUNT + 1)); sleep 3
        line=$(run_wrk "http://127.0.0.1:$PORT$path" "$DURATION" "$conns" "$threads") || {
          echo "REFUSING: $driver $path failed twice"; exit 1; }
      }
      echo "$line" >> "$OUT/${driver}${spec//\//_}.txt"
    done
    echo "rep $rep $driver done" >&2
  done
done

echo "retries: $RETRY_COUNT"
echo "results in $OUT"
