#!/usr/bin/env bash
#
# Certify a performance patch end to end, and refuse to call noise a result.
#
#   bash bench/certify/ab.sh <baseline_dir> <patch_dir> [target]
#
# Each directory holds a copy of the framework -- the thing that gets
# `require`d as `akkar`.  Typically:
#
#   git worktree add /tmp/akkar-base HEAD~1
#   bash bench/certify/ab.sh /tmp/akkar-base . /rows/50
#
# ## Why this is not just "run wrk twice"
#
# An earlier project of the owner's proved twice that a symbol's share of a
# profile is not the gain from removing it: pre-sizing a buffer held 10.7% of
# the profile and delivered -2.6% of ceiling; an RTTI cache held 6.86% and
# regressed p99 by 17.8%.  Both looked obviously right beforehand.  So a patch
# is certified by measuring it, and by measuring it in a way that cannot
# flatter itself:
#
#   1. PAYLOAD IDENTITY FIRST.  Two variants answering different payloads are
#      not comparable, and the difference will look exactly like performance.
#      Compared after canonicalising, because akkar's JSON is NOT byte-stable:
#      Lua table iteration order depends on the hash seed, so two processes
#      serialise the same table with different key order.  Worth knowing on its
#      own -- it rules out byte-level response caching and ETags computed from
#      the body.
#   2. BOTH VARIANTS RUN AT ONCE, on two ports, and the generator alternates
#      between them.  Restarting a server between repetitions makes every
#      measurement a cold start -- empty pool, unfaulted pages, untrained
#      predictor -- and the first attempt at this harness spent its runs
#      reporting timeouts from exactly that.  Side by side, the two variants
#      also meet identical machine conditions at the same instant, which is
#      strictly better than alternating in time.
#   3. WARM-UP, DISCARDED.
#   4. A NOISE FLOOR FROM THIS RUN.  Each variant's own spread across
#      repetitions is its floor; a difference smaller than the larger of the
#      two is reported as NO RESULT, not as a small win.
#   5. GOODPUT AND LATENCY TOGETHER.  Under closed-loop load, latency is
#      connections divided by throughput -- it is queue depth, not service
#      time.  So every comparison also runs at low concurrency, where the
#      number means what people think the first number means.
set -uo pipefail

BASE_DIR="${1:?usage: ab.sh <baseline_dir> <patch_dir> [target]}"
PATCH_DIR="${2:?usage: ab.sh <baseline_dir> <patch_dir> [target]}"
TARGET="${3:-/rows/50}"

PORT="${PORT:-8500}"
DURATION="${DURATION:-10s}"
CONNECTIONS="${CONNECTIONS:-100}"
THREADS="${THREADS:-4}"
LOW_CONNECTIONS="${LOW_CONNECTIONS:-2}"
POOL="${POOL:-10}"
PROCESSES="${PROCESSES:-3}"
REPS="${REPS:-5}"
WARMUP="${WARMUP:-10s}"
# wrk defaults to a 2s request timeout.  Under closed-loop saturation the queue
# delay alone approaches that -- 100 connections at 7,000 req/s is 14 ms of
# service and up to a second of queue -- so the default truncates the very
# distribution being measured, and counts the truncated requests as errors.
# The timeout here is a guard against a hung server, not an SLA.
WRK_TIMEOUT="${WRK_TIMEOUT:-10s}"
PIN="${PIN:-1}"

# Arguments before environment: a wrong directory should be reported as a
# wrong directory, not as a missing tool.
for d in "$BASE_DIR" "$PATCH_DIR"; do
  [ -f "$d/akkar/init.lua" ] || {
    echo "no akkar/init.lua under '$d' -- each argument must be a directory"
    echo "holding the framework tree, e.g. a git worktree of an older commit."
    exit 1; }
done
[ "$(cd "$BASE_DIR" && pwd)" = "$(cd "$PATCH_DIR" && pwd)" ] && {
  echo "baseline and patch are the same directory.  That is an A/A run, which"
  echo "is a fine way to measure the noise floor -- pass AA=1 if you meant it."
  [ "${AA:-0}" = "1" ] || exit 1; }
command -v wrk >/dev/null || { echo "wrk is not installed"; exit 1; }

# ------------------------------------------------------- topology-aware pinning
if [ "$PIN" = "1" ] && command -v taskset >/dev/null; then
  declare -A SIB
  for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -r "$cpu/topology/core_id" ] || continue
    c=$(cat "$cpu/topology/core_id"); SIB[$c]="${SIB[$c]:+${SIB[$c]},}${cpu##*/cpu}"
  done
  PH=($(printf '%s\n' "${!SIB[@]}" | sort -n))
  GEN_CORES="${SIB[${PH[0]}]}"; SRV_CORES=""
  for i in "${!PH[@]}"; do
    [ "$i" -eq 0 ] && continue
    SRV_CORES="${SRV_CORES:+$SRV_CORES,}${SIB[${PH[$i]}]}"
  done
  srv() { taskset -c "$SRV_CORES" "$@"; }
  gen() { taskset -c "$GEN_CORES" "$@"; }
  AFFINITY="services $SRV_CORES, generator $GEN_CORES (whole physical cores)"
else
  srv() { "$@"; }
  gen() { "$@"; }
  AFFINITY="NONE -- the generator competes with the server"
fi

echo "# certification"
echo "  date       : $(date -Is)"
echo "  cpu        : $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
echo "  baseline   : $BASE_DIR"
echo "  patch      : $PATCH_DIR"
echo "  target     : $TARGET"
echo "  load       : wrk -t$THREADS -c$CONNECTIONS -d$DURATION --timeout $WRK_TIMEOUT  (ceiling)"
echo "               wrk -t1 -c$LOW_CONNECTIONS -d$DURATION  (service time)"
echo "  processes  : $PROCESSES, pool $POOL"
echo "  reps       : $REPS, alternating order"
echo "  affinity   : $AFFINITY"
echo "  ulimit -n  : $(ulimit -n)"
echo

[ "$(ulimit -n)" -lt 8192 ] && {
  echo "REFUSING: ulimit -n is $(ulimit -n).  Hitting it looks like the server"
  echo "falling over.  Run: ulimit -n 65535"; exit 1; }

PATCH_PORT=$(( PORT + 1 ))

stop() {
  pkill -f "bench/certify/serve.lua $PORT " 2>/dev/null
  pkill -f "bench/certify/serve.lua $PATCH_PORT " 2>/dev/null
  sleep 0.5
}
trap stop EXIT

start_one() {   # dir port
  for _ in $(seq 1 "$PROCESSES"); do
    srv lua5.4 bench/certify/serve.lua "$2" "$POOL" "$1" >/dev/null 2>&1 &
  done
}

# A port that is already busy belongs to somebody else, and measuring it
# would produce a real-looking number for the wrong program.  This box has
# had that happen.
for prt in "$PORT" "$PATCH_PORT"; do
  if curl -sf --max-time 2 "http://127.0.0.1:$prt/__whoami" >/dev/null 2>&1 ||
     (command -v ss >/dev/null && ss -ltn 2>/dev/null | grep -q ":$prt "); then
    echo "REFUSING: something is already listening on :$prt."
    echo "Pick free ports with PORT=<n> (the patch uses PORT+1)."
    exit 1
  fi
done

echo "# starting both variants side by side"
stop
start_one "$BASE_DIR"  "$PORT"
start_one "$PATCH_DIR" "$PATCH_PORT"
sleep 4

for spec in "baseline:$PORT:$BASE_DIR" "patch:$PATCH_PORT:$PATCH_DIR"; do
  label=${spec%%:*}; rest=${spec#*:}; prt=${rest%%:*}; dir=${rest#*:}
  alive=$(pgrep -fc "bench/certify/serve.lua $prt " || echo 0)
  [ "$alive" -eq "$PROCESSES" ] || {
    echo "REFUSING: $label wanted $PROCESSES processes on $prt, $alive alive"; exit 1; }
  curl -sf --max-time 5 "http://127.0.0.1:$prt$TARGET" >/dev/null || {
    echo "REFUSING: $label did not answer $TARGET with 2xx"; exit 1; }

  # Something answering is not the same as MY server answering.
  who=$(curl -s --max-time 5 "http://127.0.0.1:$prt/__whoami" 2>/dev/null)
  echo "$who" | grep -q 'akkar-certify' || {
    echo "REFUSING: :$prt is not the certification target."
    echo "  it said: ${who:0:80}"; exit 1; }
  # cjson escapes forward slashes, so the path arrives as \/tmp\/... --
  # strip backslashes before comparing rather than matching the escaped form.
  echo "$who" | tr -d '\\' | grep -qF "$(cd "$dir" && pwd)" || {
    echo "REFUSING: :$prt did not load the framework from $dir."
    echo "  it said: ${who:0:120}"; exit 1; }
  echo "  $label: $PROCESSES processes on :$prt from $dir"
done
echo

# Rule 1: payload identity.  A patch that changes the payload is not a faster
# patch, it is a different endpoint.
#
# Canonicalised rather than compared raw: key order is not stable across Lua
# processes, so a raw diff reports a difference that is not one.  Length is
# still compared raw, since that is what goes on the wire.
canonical() {
  python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    print(json.dumps(json.loads(raw), sort_keys=True, separators=(",", ":")))
except Exception as e:
    print("UNPARSEABLE:" + str(e))
'
}

echo "# payload identity"
BASE_BODY=$(curl -s --max-time 10 "http://127.0.0.1:$PORT$TARGET")
PATCH_BODY=$(curl -s --max-time 10 "http://127.0.0.1:$PATCH_PORT$TARGET")
BASE_CANON=$(printf '%s' "$BASE_BODY" | canonical)
PATCH_CANON=$(printf '%s' "$PATCH_BODY" | canonical)

if [ "$BASE_CANON" != "$PATCH_CANON" ]; then
  echo "  DIFFERENT.  Comparison refused."
  echo "    baseline: ${#BASE_BODY} bytes, ${BASE_CANON:0:64}"
  echo "    patch   : ${#PATCH_BODY} bytes, ${PATCH_CANON:0:64}"
  exit 1
fi
if [ "${#BASE_BODY}" != "${#PATCH_BODY}" ]; then
  echo "  REFUSED: same content, different length (${#BASE_BODY} vs ${#PATCH_BODY})."
  echo "  Fewer bytes on the wire is a real change and must not be scored as speed."
  exit 1
fi
echo "  same content, ${#BASE_BODY} bytes on the wire"
[ "$BASE_BODY" != "$PATCH_BODY" ] && \
  echo "  (key order differs between processes -- akkar's JSON is not byte-stable)"
echo

# Prints "rps p50 p99" or "INVALID ..."
#
# Socket errors are graded rather than treated alike.  wrk reports one read
# error per connection when a run ends and the connections are torn down --
# with c=2 that is literally "read 2" out of five thousand requests, and
# failing on it would reject every low-concurrency run there is.
#
# connect and timeout are different: those mean requests never started or
# never finished, which is precisely the failure this whole harness exists to
# notice.
measure() {   # port connections threads
  # The configuration is verified before EVERY measurement, not only at
  # startup.  A process that dies mid-run leaves the survivors answering
  # perfectly while the generator hammers a port with fewer listeners, and the
  # number that comes out looks exactly like a real one.  This harness already
  # learned that lesson once, from a scaling run where seven of eight
  # processes had died with EADDRINUSE and the run passed its own checks.
  local alive
  alive=$(pgrep -fc "bench/certify/serve.lua $1 " || echo 0)
  if [ "$alive" -ne "$PROCESSES" ]; then
    echo "INVALID only $alive/$PROCESSES processes alive on :$1 -- one died mid-run"
    return
  fi

  local out
  out=$(gen wrk -t"$3" -c"$2" -d"$DURATION" --timeout "$WRK_TIMEOUT" --latency \
        "http://127.0.0.1:$1$TARGET" 2>/dev/null)

  echo "$out" | grep -q 'Non-2xx or 3xx' && { echo "INVALID non-2xx"; return; }

  local sockets
  sockets=$(echo "$out" | grep 'Socket errors' || true)
  if [ -n "$sockets" ]; then
    local verdict
    verdict=$(echo "$sockets" | awk -v conns="$2" '{
      for (i = 1; i <= NF; i++) {
        if ($i == "connect") c = $(i+1) + 0
        if ($i == "read")    r = $(i+1) + 0
        if ($i == "write")   w = $(i+1) + 0
        if ($i == "timeout") t = $(i+1) + 0
      }
      if (c > 0 || t > 0)
        printf "INVALID connect=%d timeout=%d -- requests did not start or did not finish", c, t
      else if (r + w > 2 * conns)
        printf "INVALID read=%d write=%d, beyond teardown", r, w
      else
        printf "OK"
    }')
    [ "$verdict" != "OK" ] && { echo "$verdict"; return; }
  fi

  echo "$out" | awk '/Requests\/sec/{r=$2} /^ *50%/{a=$2} /^ *99%/{b=$2} END{print r, a, b}'
}

to_ms() { awk -v v="$1" 'BEGIN{
  if (v ~ /us$/)      {sub(/us$/,"",v); print v/1000}
  else if (v ~ /ms$/) {sub(/ms$/,"",v); print v+0}
  else if (v ~ /s$/)  {sub(/s$/,"",v);  print v*1000}
  else print v+0 }'; }

echo "# warm-up, discarded"
for prt in "$PORT" "$PATCH_PORT"; do
  gen wrk -t"$THREADS" -c"$CONNECTIONS" -d"$WARMUP" --timeout "$WRK_TIMEOUT" \
    "http://127.0.0.1:$prt$TARGET" >/dev/null 2>&1
done
echo "  done"
echo

declare -A CEIL LOW
FAILED=0

for rep in $(seq 1 "$REPS"); do
  for variant in base patch; do
    prt=$PORT; [ "$variant" = patch ] && prt=$PATCH_PORT

    r=$(measure "$prt" "$CONNECTIONS" "$THREADS")
    [[ "$r" == INVALID* ]] && { echo "  rep $rep $variant ceiling: $r"; FAILED=1; } \
      || CEIL[$variant]="${CEIL[$variant]:-}$r"$'\n'

    r=$(measure "$prt" "$LOW_CONNECTIONS" 1)
    [[ "$r" == INVALID* ]] && { echo "  rep $rep $variant service: $r"; FAILED=1; } \
      || LOW[$variant]="${LOW[$variant]:-}$r"$'\n'
  done
done

[ "$FAILED" -eq 1 ] && { echo; echo "RUN INVALID."; exit 1; }

# median rps, median p50, and this variant's own spread in basis points
stats() { echo "$1" | grep -v '^$' | sort -n | awk '
  {r[NR]=$1; p[NR]=$2}
  END {m=int((NR+1)/2)
       spread = r[m] > 0 ? (r[NR]-r[1])/r[m]*10000 : 0
       print r[m], p[m], spread}'; }

report() {   # label samples_base samples_patch connections
  local label="$1" conns="$4"
  read -r brps bp50 bspread <<<"$(stats "$2")"
  read -r prps pp50 pspread <<<"$(stats "$3")"

  local floor; floor=$(awk -v a="$bspread" -v b="$pspread" 'BEGIN{print (a>b)?a:b}')
  local delta; delta=$(awk -v a="$brps" -v b="$prps" 'BEGIN{printf "%.2f", (b-a)/a*100}')
  local delta_bp; delta_bp=$(awk -v d="$delta" 'BEGIN{printf "%.0f", (d<0?-d:d)*100}')

  echo "## $label  (c=$conns)"
  printf "  %-10s %13s %11s %14s\n" "" "req/s" "p50" "own spread"
  printf "  %-10s %13s %11s %13.1f%%\n" "baseline" "$brps" "$bp50" "$(awk -v x="$bspread" 'BEGIN{print x/100}')"
  printf "  %-10s %13s %11s %13.1f%%\n" "patch"    "$prps" "$pp50" "$(awk -v x="$pspread" 'BEGIN{print x/100}')"

  # Rule 5: under closed-loop load, latency is connections / throughput.  If
  # the measured p50 matches that, the number is queue depth and says nothing
  # about how long the server took.
  local implied measured ratio
  implied=$(awk -v c="$conns" -v r="$prps" 'BEGIN{printf "%.3f", (r>0)? c/r*1000 : 0}')
  measured=$(to_ms "$pp50")
  ratio=$(awk -v i="$implied" -v m="$measured" 'BEGIN{printf "%.2f", (m>0)? i/m : 0}')
  if awk -v r="$ratio" 'BEGIN{exit !(r > 0.85 && r < 1.15)}'; then
    echo "  note: p50 ${measured}ms matches connections/throughput (${implied}ms)."
    echo "        This run is saturated, so p50 is QUEUE DEPTH, not service time."
  fi

  echo
  if awk -v d="$delta_bp" -v f="$floor" 'BEGIN{exit !(d <= f)}'; then
    printf "  VERDICT: NO RESULT.  %+.2f%% is inside the %.1f%% noise floor\n" \
           "$delta" "$(awk -v x="$floor" 'BEGIN{print x/100}')"
    echo "           derived from this run.  Not a small win; not a result."
  elif awk -v d="$delta" 'BEGIN{exit !(d > 0)}'; then
    printf "  VERDICT: FASTER by %+.2f%%, outside the %.1f%% floor.\n" \
           "$delta" "$(awk -v x="$floor" 'BEGIN{print x/100}')"
  else
    printf "  VERDICT: SLOWER by %.2f%%, outside the %.1f%% floor.\n" \
           "$delta" "$(awk -v x="$floor" 'BEGIN{print x/100}')"
  fi
  echo
}

report "throughput ceiling" "${CEIL[base]}" "${CEIL[patch]}" "$CONNECTIONS"
report "service time"       "${LOW[base]}"  "${LOW[patch]}"  "$LOW_CONNECTIONS"

echo "# reading it"
echo "  The ceiling section answers 'how much work fits'.  The service-time"
echo "  section answers 'how long one request takes' -- and only the second"
echo "  one means that, because under saturation latency is just queue depth."
echo "  A patch that moves one and not the other is still a real finding; say"
echo "  which one it moved."
