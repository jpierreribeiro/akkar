#!/usr/bin/env bash
# Did akkar get slower between the published study and now?
#
# `RESULTS.md` §2 reported /ping at 20,648 req/s on 2026-08-15. Six independent
# measurements on 2026-08-16, on the same box with the same harness, landed
# between 19,135 and 19,622 -- about 6% down, every one of them with a spread
# under 2%.
#
# The reason that is worth chasing rather than shrugging at: on the SAME runs,
# Gin came back within 0.2% of its published number and FastAPI within 0.1%.
# The machine reproduced. akkar did not.
#
# So this alternates two trees on /ping, same process count, same cores, same
# generator, restarting between every repetition so drift cannot be attributed
# to one of them.
#
#   usage: regression.sh <baseline-ref> [head-ref]
#
# Trees are prepared as separate clones under ~/study rather than by checking
# out in place, because a shared tree means whichever ran last is what both
# measured.
source "$(dirname "$0")/lib.sh"
detect_topology || exit 1
verify_reservation || exit 1

BASE_REF=${1:?usage: regression.sh <baseline-ref> [head-ref]}
HEAD_REF=${2:-HEAD}
ROOT=${ROOT:-$HOME/akkar}
APPS=${APPS:-$HOME/study/apps}
PORT=${PORT:-8500}
DURATION=${DURATION:-10s}
REPS=${REPS:-5}
CONNS=${CONNS:-100}
THREADS=${THREADS:-4}
PROCS=${PROCS:-2}
HZ=$(getconf CLK_TCK)

BASE_TREE=$HOME/study/tree-base
HEAD_TREE=$HOME/study/tree-head

prepare() {   # ref, destination
  local ref=$1 dest=$2
  rm -rf "$dest"
  git -C "$ROOT" worktree prune 2>/dev/null
  cp -a "$ROOT" "$dest"
  # `-f`, because the copy may carry edits shipped to the box by hand, and a
  # checkout that silently keeps them would measure neither ref.
  git -C "$dest" checkout -q -f --detach "$ref" 2>/dev/null || {
    echo "REFUSING: cannot check out $ref"; return 1; }
  # And prove the tree is clean, since -f is the reason to be suspicious.
  #
  # TRACKED files only. The harness scripts themselves are untracked at an
  # older ref -- they were written after it -- and refusing on those refuses
  # every comparison this script exists to make.
  local dirty; dirty=$(git -C "$dest" status --porcelain --untracked-files=no | grep -c .)
  if [ "${dirty:-0}" -ne 0 ]; then
    echo "REFUSING: $dest still has $dirty modified tracked file(s)"
    git -C "$dest" status --porcelain --untracked-files=no | head -5
    return 1
  fi
  echo "  $(basename "$dest"): $(git -C "$dest" log --oneline -1)"
}

echo "preparing trees"
prepare "$BASE_REF" "$BASE_TREE" || exit 1
prepare "$HEAD_REF" "$HEAD_TREE" || exit 1
echo

stop_all() { pkill -f "study/apps/serve[.]lua" 2>/dev/null; sleep 2; }
trap stop_all EXIT

cpu_ticks() {
  local total=0
  for pid in $(pgrep -f "study/apps/serve[.]lua" 2>/dev/null); do
    [ -r "/proc/$pid/stat" ] || continue
    local rest; rest=$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null)
    local ut st
    ut=$(echo "$rest" | awk '{print $12}'); st=$(echo "$rest" | awk '{print $13}')
    total=$(( total + ${ut:-0} + ${st:-0} ))
  done
  echo "$total"
}

start_tree() {   # tree
  stop_all
  for _ in $(seq 1 "$PROCS"); do
    AKKAR_ROOT="$1" AKKAR_LEAN=0 setsid taskset -c "$SERVERS" \
      lua5.4 "$APPS/serve.lua" "$PORT" 10 </dev/null >/dev/null 2>&1 & disown
  done
  sleep 4
  verify_running "study/apps/serve[.]lua" "$PROCS" "akkar" || return 1
}

declare -A GOT CPU
# ORDER ALTERNATES PER REPETITION so a machine that drifts cannot hand the
# difference to whichever tree ran second.
for rep in $(seq 1 "$REPS"); do
  for variant in base head; do
    local_tree=$BASE_TREE
    [ "$variant" = head ] && local_tree=$HEAD_TREE
    start_tree "$local_tree" || exit 1
    [ "$rep" -eq 1 ] && {
      probe_body "http://127.0.0.1:$PORT/ping" >/dev/null || {
        echo "REFUSING: $variant did not answer"; exit 1; }
      taskset -c "$GENERATOR" wrk -t"$THREADS" -c"$CONNS" -d3s \
        "http://127.0.0.1:$PORT/ping" >/dev/null 2>&1
    }
    b=$(cpu_ticks); ws=$(date +%s.%N)
    line=$(run_wrk "http://127.0.0.1:$PORT/ping" "$DURATION" "$CONNS" "$THREADS") || exit 1
    we=$(date +%s.%N); a=$(cpu_ticks)
    c=$(awk -v x="$b" -v y="$a" -v hz="$HZ" -v s="$ws" -v e="$we" \
      'BEGIN{printf "%.2f", ((y-x)/hz)/(e-s)}')
    GOT[$variant]="${GOT[$variant]:-}$line"$'\n'
    CPU[$variant]="${CPU[$variant]:-}$c"$'\n'
  done
  echo "rep $rep done" >&2
done

echo
printf "%-14s %11s %10s %10s %8s %7s %10s\n" tree req/s p50 p99 spread cores "us/req"
printf "%-14s %11s %10s %10s %8s %7s %10s\n" \
  "--------------" ----------- ---------- ---------- -------- ------- ----------

declare -A RPS
for variant in base head; do
  r=$(echo "${GOT[$variant]}" | grep -v '^$' | summarise)
  rps=$(echo $r | cut -d' ' -f1)
  cores=$(echo "${CPU[$variant]}" | grep -v '^$' | awk '{s+=$1; n++} END{printf "%.2f", s/n}')
  us=$(awk -v x="$rps" -v c="$cores" 'BEGIN{printf "%.1f", (c/x)*1000000}')
  RPS[$variant]=$rps
  printf "%-14s %11s %10s %10s %7s%% %7s %10s\n" "$variant" $r "$cores" "$us"
done

echo
awk -v b="${RPS[base]}" -v h="${RPS[head]}" 'BEGIN{
  printf "head is %.1f%% of baseline (%.1f%% change)\n", h/b*100, (h-b)/b*100 }'
echo "baseline $BASE_REF, head $HEAD_REF"
