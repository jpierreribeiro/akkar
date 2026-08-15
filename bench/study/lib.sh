#!/usr/bin/env bash
# Shared machinery for the study, and every gate in it was earned by a run
# that reported a number for the wrong reason.
#
#   1. The process count is VERIFIED, per framework, every time.  Go's
#      net.Listen does not set SO_REUSEPORT, so two of three `gin-bench`
#      processes died instantly with EADDRINUSE and the survivor used six
#      vCPUs against akkar's three.  Nothing noticed.
#   2. The server PROVES which tree it loaded.  A harness pinned `akkar-after`
#      in package.path and never substituted a literal `akkar-VARIANT`, so the
#      variant resolved correctly only by accident of the working directory.
#   3. The response gate refuses an ERROR body.  A run against /users/42 -- a
#      route the server did not have -- passed an identity check because both
#      sides returned the same 404, and measured the router.
#   4. Order alternates and the spread of the run IS the noise floor.  A
#      change smaller than the floor is not a result.
#   5. Goodput and p50 are read together.  A p50 that rises while throughput
#      is flat is queue depth wearing a latency label.

set -uo pipefail
export PATH=$HOME/.local/bin:$PATH
eval "$(luarocks path --bin)" 2>/dev/null

# ------------------------------------------------------------------ topology
# c5.2xlarge is 4 physical cores x 2 threads.  Two hyperthreads of one core are
# not two cores, and pinning to 0-5 rather than to whole cores measures the
# siblings fighting each other.
detect_topology() {
  declare -gA SIBLINGS
  for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
    [ -r "$cpu/topology/core_id" ] || continue
    local core; core=$(cat "$cpu/topology/core_id")
    SIBLINGS[$core]="${SIBLINGS[$core]:+${SIBLINGS[$core]},}${cpu##*/cpu}"
  done
  mapfile -t PHYSICAL < <(printf '%s\n' "${!SIBLINGS[@]}" | sort -n)
  GENERATOR="${SIBLINGS[${PHYSICAL[0]}]}"
  SERVERS=""
  for i in "${!PHYSICAL[@]}"; do
    [ "$i" -eq 0 ] && continue
    SERVERS="${SERVERS:+$SERVERS,}${SIBLINGS[${PHYSICAL[$i]}]}"
  done
  SERVER_CORES=$(( ${#PHYSICAL[@]} - 1 ))
  export GENERATOR SERVERS SERVER_CORES
}

# Cores for exactly N physical cores, so a scaling run gives each process one.
cores_for() {
  local want=$1 list=""
  for i in "${!PHYSICAL[@]}"; do
    [ "$i" -eq 0 ] && continue
    [ "$((i))" -le "$want" ] || break
    list="${list:+$list,}${SIBLINGS[${PHYSICAL[$i]}]}"
  done
  echo "$list"
}

# --------------------------------------------------------------------- gates
# Refuses rather than warns.  A warning in a log nobody reads is not a gate.
verify_running() {
  local pattern=$1 expected=$2 what=$3
  # `pgrep -c` prints 0 AND exits non-zero when nothing matches, so the
  # obvious `|| echo 0` appends a second line and the comparison below fails
  # with "0\n0: integer expected" -- an error about the harness printed where
  # the reason for the refusal should be.
  local alive; alive=$(pgrep -fc "$pattern" 2>/dev/null); alive=${alive:-0}
  if [ "$alive" -ne "$expected" ]; then
    echo "REFUSING: $what has $alive process(es), expected $expected."
    echo "  A configuration that is not the configuration reports a number too."
    return 1
  fi
  return 0
}

canonical() {
  python3 -c 'import json,sys
raw = sys.stdin.read()
try:
    print(json.dumps(json.loads(raw), sort_keys=True, separators=(",",":")))
except Exception:
    print("NOT-JSON:" + raw[:200])'
}

# A body is acceptable only if it is 2xx AND is not an error document.
# Agreeing on an error is still agreement.
probe_body() {
  local url=$1
  local code; code=$(curl -s -o /tmp/probe.$$ -w '%{http_code}' --max-time 10 "$url")
  local body; body=$(canonical < /tmp/probe.$$); rm -f /tmp/probe.$$
  if [ "$code" != "200" ]; then echo "HTTP-$code:$body"; return 1; fi
  case "$body" in
    *'"error"'*|NOT-JSON:*|"") echo "ERROR-BODY:$body"; return 1 ;;
  esac
  echo "$body"
}

# ---------------------------------------------------------------------- load
# Returns "rps p50 p99" or the empty string when the run was invalid.
# Non-2xx or socket errors invalidate: a server answering 500 quickly looks
# fast.
run_wrk() {
  local url=$1 duration=$2 conns=$3 threads=$4 script=${5:-}
  # wrk gives up on a socket after 2 s by default, and a heavy route under
  # a hundred connections exceeds that -- which aborts the whole run rather
  # than measuring it.  Ten seconds, applied identically to every framework,
  # so it advantages none of them.  A request that needs longer than ten
  # seconds is a failure worth reporting as one.
  local args=(-t"$threads" -c"$conns" -d"$duration" --timeout 10s --latency)
  [ -n "$script" ] && args+=(-s "$script")

  local out; out=$(taskset -c "$GENERATOR" wrk "${args[@]}" "$url" 2>/dev/null)
  if echo "$out" | grep -qE 'Non-2xx|Socket errors'; then
    echo "INVALID $(echo "$out" | grep -E 'Non-2xx|Socket errors' | tr '\n' ' ')" >&2
    return 1
  fi
  echo "$out" | awk '
    /Requests\/sec/ { rps = $2 }
    /^ *50%/        { p50 = $2 }
    /^ *99%/        { p99 = $2 }
    END             { print rps, p50, p99 }'
}

# Nearest-rank median and the spread across repetitions, which IS the floor.
summarise() {
  sort -n | awk '
    { r[NR] = $1; a[NR] = $2; b[NR] = $3 }
    END {
      if (NR == 0) { print "0 0 0 0"; exit }
      m = int((NR + 1) / 2)
      spread = (r[NR] - r[1]) / r[m] * 100
      printf "%s %s %s %.1f", r[m], a[m], b[m], spread
    }'
}

# Latency figures arrive as 1.23ms / 456.78us / 1.02s.  Comparing them as
# strings is how a study reports that 900us is slower than 1.2ms.
to_ms() {
  python3 -c '
import sys, re
v = sys.argv[1]
m = re.match(r"([0-9.]+)(us|ms|s)", v)
if not m: print("nan"); sys.exit()
n, unit = float(m.group(1)), m.group(2)
print({"us": n/1000, "ms": n, "s": n*1000}[unit])' "$1"
}
