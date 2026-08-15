#!/usr/bin/env bash
# The study.  One harness, four questions, every gate from lib.sh armed.
#
#   cumulative   the state before the performance work against HEAD
#   compare      akkar against Gin and FastAPI, equal parallelism, verified
#   scaling      one process per physical core, 1..N
#   knee         where added concurrency stops buying throughput
#   payload      how each framework degrades as the body grows
#
# usage: run.sh <part> [part ...]
source "$(dirname "$0")/lib.sh"
detect_topology

PORT=${PORT:-8500}
DURATION=${DURATION:-10s}
CONNS=${CONNS:-100}
THREADS=${THREADS:-4}
REPS=${REPS:-5}
PROCS=${PROCS:-$SERVER_CORES}
POOL=${POOL:-10}

HEAD_TREE=$HOME/study/head
BASE_TREE=$HOME/study/baseline
APPS=$HOME/study/apps

# ------------------------------------------------------------------ servers
stop_all() {
  pkill -f "study/apps/serve[.]lua"    2>/dev/null
  pkill -f "study/apps/gin-bench"      2>/dev/null
  pkill -f "fastapi-venv/bin/uvicorn"  2>/dev/null
  pkill -f "spawn_main"                2>/dev/null
  sleep 2
  # Postgres does not reap a killed client's connection instantly, and
  # starting the next variant into an exhausted max_connections fails for a
  # reason that has nothing to do with what is being measured.
  for _ in $(seq 1 40); do
    local n; n=$(sudo docker exec akkar-pg psql -U postgres -d akkar -tAc \
      "select count(*) from pg_stat_activity where datname='akkar'" 2>/dev/null | tr -d ' ')
    [ "${n:-99}" -le 5 ] && break
    sleep 0.5
  done
}
trap stop_all EXIT

start_akkar() {   # tree, processes, cores, [lean]
  local tree=$1 n=$2 cores=$3 lean=${4:-0}
  stop_all
  for _ in $(seq 1 "$n"); do
    AKKAR_ROOT="$tree" AKKAR_LEAN="$lean" setsid taskset -c "$cores" \
      lua5.4 "$APPS/serve.lua" "$PORT" "$POOL" </dev/null >/dev/null 2>&1 &
    disown
  done
  sleep 4
  verify_running "study/apps/serve[.]lua" "$n" "akkar" || exit 1
}

start_gin() {
  local n=$1 cores=$2
  stop_all
  for _ in $(seq 1 "$n"); do
    setsid taskset -c "$cores" "$APPS/gin-bench" "$PORT" "$POOL" \
      </dev/null >/dev/null 2>&1 & disown
  done
  sleep 4
  verify_running "study/apps/gin-bench" "$n" "gin" || exit 1
}

start_fastapi() {
  local n=$1 cores=$2
  stop_all
  # ONE uvicorn with --workers, not N uvicorns: uvicorn does not set
  # SO_REUSEPORT, so N separate ones leave a single survivor and N-1 corpses.
  # Verified by hand -- three started, one alive -- which is the same defect
  # that invalidated the first comparison, this time on the other side.
  #
  # Affinity is inherited across fork, so pinning the master pins the workers.
  # `--workers 1` does NOT spawn a worker: uvicorn serves in the master
  # process, so there is no `spawn_main` to count and the gate refuses a
  # perfectly good server. One process means one process, plainly.
  local worker_flag=(--workers "$n")
  local pattern="spawn_main" expected="$n"
  if [ "$n" -eq 1 ]; then
    worker_flag=()
    pattern="fastapi-venv/bin/uvicorn"
  fi

  POOL_SIZE=$POOL setsid taskset -c "$cores" \
    "$HOME/fastapi-venv/bin/uvicorn" --app-dir "$HOME/study" apps.app:app \
    --host 127.0.0.1 --port "$PORT" --log-level critical \
    --loop uvloop --http httptools "${worker_flag[@]}" \
    </dev/null >/dev/null 2>&1 & disown
  sleep 8
  # The workers do not carry "apps.app:app" on their command line; they are
  # multiprocessing spawns. Counting the wrong pattern reports one process
  # and refuses a run that is fine, or worse, passes one that is not.
  verify_running "$pattern" "$expected" "fastapi" || exit 1
}

# --------------------------------------------------------------- measurement
# Runs REPS repetitions of one target and prints "rps p50 p99 spread".
measure() {
  local target=$1 conns=${2:-$CONNS} threads=${3:-$THREADS}
  local rows="" retries=0
  taskset -c "$GENERATOR" wrk -t"$threads" -c"$conns" -d3s \
    "http://127.0.0.1:$PORT$target" >/dev/null 2>&1      # discarded warm-up

  # One retry per repetition, and the count is reported.
  #
  # A single transient repetition killed a two-hour study once: 42 non-2xx
  # out of roughly half a million requests, on a configuration that then ran
  # five clean repetitions in a row when asked again. Failing the whole run
  # on that is bad harness design -- and swallowing it silently is worse, so
  # RETRIES comes back with the numbers and anything above zero is printed.
  for _ in $(seq 1 "$REPS"); do
    local line
    line=$(run_wrk "http://127.0.0.1:$PORT$target" "$DURATION" "$conns" "$threads") || {
      retries=$((retries + 1))
      sleep 2
      line=$(run_wrk "http://127.0.0.1:$PORT$target" "$DURATION" "$conns" "$threads") || return 1
    }
    rows+="$line"$'\n'
  done
  RETRIES=$retries
  echo "$rows" | grep -v '^$' | summarise
}

banner() {
  echo
  echo "=============================================================="
  echo "$1"
  echo "=============================================================="
}

header() {
  echo "machine   : $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
  echo "topology  : ${#PHYSICAL[@]} physical cores x 2 threads"
  echo "affinity  : servers $SERVERS, generator $GENERATOR"
  echo "load      : wrk -t$THREADS -c$CONNS -d$DURATION, $REPS reps, median"
  echo "date      : $(date -u '+%Y-%m-%d %H:%M UTC')"
}

# ===================================================================== parts

part_cumulative() {
  banner "1. What the performance work actually bought"
  header
  echo
  echo "akkar against akkar: the tree at 62a40ca, before any fix, against HEAD."
  echo "Same harness, same machine, same processes, alternating order."
  echo

  for target in ${TARGETS:-/ping /users/42 /rows/200}; do
    declare -A got
    for rep in $(seq 1 "$REPS"); do
      for variant in baseline head; do
        local tree=$BASE_TREE
        [ "$variant" = head ] && tree=$HEAD_TREE
        start_akkar "$tree" "$PROCS" "$SERVERS"
        [ "$rep" -eq 1 ] && {
          local body; body=$(probe_body "http://127.0.0.1:$PORT$target") || {
            echo "REFUSING on $target ($variant): $body"; exit 1; }
          eval "body_$variant=\$body"
        }
        local line; line=$(run_wrk "http://127.0.0.1:$PORT$target" "$DURATION" "$CONNS" "$THREADS") || exit 1
        got[$variant]="${got[$variant]:-}$line"$'\n'
      done
    done

    if [ "$body_baseline" != "$body_head" ]; then
      echo "REFUSING on $target: the two trees return different data."
      exit 1
    fi

    echo "$target  (identical responses from both trees)"
    printf "  %-9s %12s %10s %10s %8s\n" variant req/s p50 p99 spread
    local rb rh
    rb=$(echo "${got[baseline]}" | grep -v '^$' | summarise)
    rh=$(echo "${got[head]}"     | grep -v '^$' | summarise)
    printf "  %-9s %12s %10s %10s %7s%%\n" baseline $rb
    printf "  %-9s %12s %10s %10s %7s%%\n" HEAD $rh
    awk -v b="$(echo $rb | cut -d' ' -f1)" -v h="$(echo $rh | cut -d' ' -f1)" \
        -v sb="$(echo $rb | cut -d' ' -f4)" -v sh="$(echo $rh | cut -d' ' -f4)" 'BEGIN{
      g = (h-b)/b*100; f = (sb>sh?sb:sh)
      printf "  change %+.1f%% (%.2fx), floor %.1f%% -- %s\n\n", g, h/b, f,
             ((g<0?-g:g) <= f) ? "INSIDE THE NOISE, not a result" : "certified"
    }'
    unset got body_baseline body_head
  done
}

part_compare() {
  banner "2. akkar against Gin and FastAPI"
  header
  echo "processes : $PROCS each, one per physical core, VERIFIED after start"
  echo "pool      : $POOL connections per process, all three"
  echo

  # Concurrency per target, not one number for all three.  /rows/200 at a
  # hundred connections exceeds what this machine can serve -- requests time
  # out and the run reports the generator's rate rather than the server's
  # capacity.  Every framework gets the same number on the same target, so
  # none of them is advantaged.
  for entry in "/ping 100" "/users/42 100" "/rows/200 16"; do
    set -- $entry
    local target=$1 conns=$2
    declare -A got bodies
    for rep in $(seq 1 "$REPS"); do
      for fw in gin fastapi akkar akkar-lean; do
        case $fw in
          gin)        start_gin "$PROCS" "$SERVERS" ;;
          fastapi)    start_fastapi "$PROCS" "$SERVERS" ;;
          akkar)      start_akkar "$HEAD_TREE" "$PROCS" "$SERVERS" 0 ;;
          akkar-lean) start_akkar "$HEAD_TREE" "$PROCS" "$SERVERS" 1 ;;
        esac
        [ "$rep" -eq 1 ] && {
          local body; body=$(probe_body "http://127.0.0.1:$PORT$target") || {
            echo "REFUSING on $target ($fw): $body"; exit 1; }
          bodies[$fw]=$body
        }
        local line; line=$(run_wrk "http://127.0.0.1:$PORT$target" "$DURATION" "$conns" "$THREADS") || exit 1
        got[$fw]="${got[$fw]:-}$line"$'\n'
      done
    done

    # Semantic equivalence before any timing.  Compared canonically, because
    # JSON key order is not defined and varies between runs, not between
    # frameworks.
    for fw in fastapi akkar akkar-lean; do
      if [ "${bodies[$fw]}" != "${bodies[gin]}" ]; then
        echo "REFUSING on $target: $fw and gin return different data."
        echo "  gin : ${bodies[gin]:0:180}"
        echo "  $fw : ${bodies[$fw]:0:180}"
        exit 1
      fi
    done

    echo "$target at $conns connections  (all four return byte-identical JSON)"
    printf "  %-12s %12s %10s %10s %8s %9s\n" framework req/s p50 p99 spread relative
    local base=""
    for fw in gin fastapi akkar akkar-lean; do
      local r; r=$(echo "${got[$fw]}" | grep -v '^$' | summarise)
      local rps; rps=$(echo $r | cut -d' ' -f1)
      [ -z "$base" ] && base=$rps
      printf "  %-12s %12s %10s %10s %7s%% %8.2fx\n" "$fw" $r \
        "$(awk -v a="$rps" -v b="$base" 'BEGIN{print a/b}')"
    done
    echo
    unset got bodies
  done
}

part_scaling() {
  banner "3. Does capacity follow cores?"
  header
  echo "One Lua VM is one core, so akkar's answer to more CPU is more"
  echo "processes. This is where that claim is either true or it is not."
  echo
  printf "  %-8s %-6s %12s %10s %10s %9s\n" framework procs req/s p50 p99 per-proc
  for fw in akkar gin fastapi; do
    for n in $(seq 1 "$SERVER_CORES"); do
      local cores; cores=$(cores_for "$n")
      case $fw in
        akkar)   start_akkar "$HEAD_TREE" "$n" "$cores" 0 ;;
        gin)     start_gin "$n" "$cores" ;;
        fastapi) start_fastapi "$n" "$cores" ;;
      esac
      probe_body "http://127.0.0.1:$PORT/ping" >/dev/null || { echo "  REFUSING: $fw bad body"; exit 1; }
      local r; r=$(measure /ping) || exit 1
      printf "  %-8s %-6s %12s %10s %10s %9.0f%s\n" "$fw" "$n" $(echo $r | cut -d' ' -f1-3) \
        "$(awk -v a="$(echo $r | cut -d' ' -f1)" -v n="$n" 'BEGIN{print a/n}')" \
        "$([ "${RETRIES:-0}" -gt 0 ] && echo "  (${RETRIES} retried)")"
    done
    echo
  done
}

part_knee() {
  banner "4. Where added concurrency stops buying anything"
  header
  echo "Goodput and p50 read together. A p50 climbing while throughput is flat"
  echo "is queue depth wearing a latency label, and the point where that starts"
  echo "is the only honest capacity number."
  echo
  for fw in akkar gin fastapi; do
    case $fw in
      akkar)   start_akkar "$HEAD_TREE" "$PROCS" "$SERVERS" 0 ;;
      gin)     start_gin "$PROCS" "$SERVERS" ;;
      fastapi) start_fastapi "$PROCS" "$SERVERS" ;;
    esac
    echo "  $fw"
    printf "    %-7s %12s %10s %10s\n" conns req/s p50 p99
    for c in 1 2 4 8 16 32 64 128 256 512; do
      local threads=$THREADS
      [ "$c" -lt 4 ] && threads=1
      local r; r=$(measure /ping "$c" "$threads") || continue
      printf "    %-7s %12s %10s %10s\n" "$c" $(echo $r | cut -d' ' -f1-3)
    done
    echo
  done
}

part_payload() {
  banner "5. How each one degrades as the body grows"
  header
  echo
  printf "  %-8s %-7s %12s %10s %10s %11s\n" framework rows req/s p50 p99 bytes
  for fw in akkar gin fastapi; do
    case $fw in
      akkar)   start_akkar "$HEAD_TREE" "$PROCS" "$SERVERS" 0 ;;
      gin)     start_gin "$PROCS" "$SERVERS" ;;
      fastapi) start_fastapi "$PROCS" "$SERVERS" ;;
    esac
    for n in 1 10 100 500 1000 2000; do
      local bytes; bytes=$(curl -s "http://127.0.0.1:$PORT/rows/$n" | wc -c)
      probe_body "http://127.0.0.1:$PORT/rows/$n" >/dev/null || { echo "  REFUSING: $fw /rows/$n"; exit 1; }
      # Below saturation, so what is measured is service time rather than
      # how long a queue got.
      local r; r=$(measure "/rows/$n" 16) || continue
      printf "  %-8s %-7s %12s %10s %10s %11s\n" "$fw" "$n" $(echo $r | cut -d' ' -f1-3) "$bytes"
    done
    echo
  done
}

part_tail() {
  banner "6. The tail that appeared when the median got seven times better"
  header
  echo
  echo "On /users/42 HEAD serves 3.80x the throughput of the baseline and"
  echo "halves p50 seven times over -- while p99 goes from 99ms to 307ms and"
  echo "the spread from 0.9% to 12.2%."
  echo
  echo "The hypothesis: HEAD is now fast enough that the CONNECTION POOL is"
  echo "the queue. $PROCS processes x pool 10 is 60 database connections"
  echo "against 100 client connections, so 40 requests are always waiting for"
  echo "a slot. The baseline was slow enough per request that the client never"
  echo "piled up like that."
  echo
  echo "If that is right, the tail collapses when the connections fit -- and"
  echo "does not when the pool is merely bigger than the demand."
  echo
  printf "  %-22s %12s %10s %10s %8s\n" configuration req/s p50 p99 spread
  for setting in "10 50" "10 100" "30 100" "30 200"; do
    set -- $setting
    POOL=$1
    local conns=$2
    start_akkar "$HEAD_TREE" "$PROCS" "$SERVERS" 0
    probe_body "http://127.0.0.1:$PORT/users/42" >/dev/null || { echo "  bad body"; exit 1; }
    local r; r=$(measure /users/42 "$conns") || continue
    printf "  pool %-3s conns %-6s %12s %10s %10s %7s%%\n" "$POOL" "$conns" $r
  done
  echo
  echo "  (pool x $PROCS processes is the real connection count: 10 -> 60, 30 -> 180)"
}

part_deadline() {
  banner "7. What the per-request deadline costs in the tail"
  header
  echo
  echo "In part 2, akkar showed p99 647ms on /users/42 and akkar-lean showed"
  echo "86ms on the same route and the same load. The only difference between"
  echo "them is timeout = 0, which bypasses the deadline controller."
  echo
  echo "Those were two separate runs, so that is a suspicion and not a result."
  echo "This is the controlled version: same process, alternating, five"
  echo "repetitions, at the concurrency where part 6 showed the pool queues."
  echo
  printf "  %-14s %12s %10s %12s %8s\n" variant req/s p50 p99 spread
  declare -A got
  for rep in $(seq 1 "$REPS"); do
    for variant in shipped lean; do
      local lean=0; [ "$variant" = lean ] && lean=1
      start_akkar "$HEAD_TREE" "$PROCS" "$SERVERS" "$lean"
      probe_body "http://127.0.0.1:$PORT/users/42" >/dev/null || { echo "  bad body"; exit 1; }
      local line; line=$(run_wrk "http://127.0.0.1:$PORT/users/42" "$DURATION" 100 "$THREADS") || exit 1
      got[$variant]="${got[$variant]:-}$line"$'\n'
    done
  done
  for variant in shipped lean; do
    printf "  %-14s %12s %10s %12s %7s%%\n" "$variant" \
      $(echo "${got[$variant]}" | grep -v '^$' | summarise)
  done
  echo
  echo "  shipped = the deadline as akkar ships it; lean = timeout 0, no controller"
}

for part in "$@"; do
  case $part in
    cumulative) part_cumulative ;;
    compare)    part_compare ;;
    scaling)    part_scaling ;;
    knee)       part_knee ;;
    payload)    part_payload ;;
    tail)       part_tail ;;
    deadline)   part_deadline ;;
    *) echo "unknown part: $part"; exit 2 ;;
  esac
done
