#!/usr/bin/env bash
#
# The runtime comparison. Implements bench/runtime/METHOD.md.
#
# Rules enforced here rather than remembered:
#   3  each candidate gets its own noise floor, and a difference below the
#      larger of two floors is not a result
#   4  outer loop is the repetition, inner loop is the candidate, so nobody
#      gets a warm cache for a whole block
#   5  the generator gets its own physical core; services get the others
#   6  the dimensions are runtime dimensions, not throughput alone
#
# Dimensions covered by THIS script: D1 boot, D2 resident memory, D3 cost per
# idle connection, D4 throughput and p99, D6 artefact shape.
# D5 (saturation) and D7 (dependency down) are a second pass and are NOT
# silently folded in -- see the note printed at the end.
set -uo pipefail

RT="$HOME/rt"
OUT="${OUT:-$RT/results}"
mkdir -p "$OUT"
rm -f "$OUT/d4-ping.txt"

# Truncated at the start of every run, not appended to. Two runs' reps mixed
# into one file give a Rule 3 spread computed across configurations that were
# never the same configuration.
REPS=${REPS:-3}
DUR=${DUR:-10}
CONNS=${CONNS:-100}
THREADS=${THREADS:-4}

# Rule 5: c5.2xlarge is 4 physical x 2 threads. Core 0 and its sibling 4 drive
# the generator; the services get 1,2,3 and 5,6,7. Splitting sibling threads
# leaves the contention in place while looking like isolation -- this project
# read 0.67x per-process scaling from exactly that mistake.
GEN_CPUS=${GEN_CPUS:-0,4}
SVC_CPUS=${SVC_CPUS:-1,2,3,5,6,7}
# PROCS IS ONE, AND SAYING SO IS THE FIX.
#
# This was `${PROCS:-2}` and nothing read it: all four candidates run a single
# process, and `openresty/nginx.conf` carried a comment claiming "worker_processes
# is set by run.sh to match every other candidate's process count" -- a guarantee
# no code provided. The comparison was correct at one process each; the stated
# mechanism was absent, which is how a later change to one candidate would have
# gone unnoticed.
#
# `bench/study/regression.sh` is the harness that varies process count. This one
# holds it at one.
PROCS=1

# ---------------------------------------------------------- the request shape
#
# THE FIXTURE IS PART OF THE MEASUREMENT, and until 18 August 2026 this one was
# a lie by omission: `wrk` sends `Host` and nothing else, so every number this
# project has published described a request with two short headers, no body and
# a 13-byte reply.
#
# That hid a header parse whose cost grew with the value's length -- 8% of a
# request's CPU on this shape and 45% on a browser's. It was found by accident.
# Measured afterwards, one variable at a time, against the shape below:
#
#     + 6 browser headers                    1.17x
#     a validated route with those headers    1.64x
#     a POST with a 2 KB JSON body            2.47x
#     a new connection per request            1.88x
#     a 64 KB JSON response                   5.26x
#
# So the default now carries headers a browser actually sends. `SHAPE=bare`
# restores the old two-header form for comparison with numbers taken before
# this date -- and NUMBERS FROM THE TWO SHAPES ARE NOT COMPARABLE, which is why
# the shape is printed with every run rather than left to be remembered.
SHAPE=${SHAPE:-browser}
case "$SHAPE" in
  bare)     WRK_HEADERS=() ;;
  browser)  WRK_HEADERS=(
              -H "user-agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
              -H "accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8"
              -H "accept-language: en-GB,en;q=0.9,pt-BR;q=0.8"
              -H "accept-encoding: gzip, deflate, br"
              -H "cookie: session=8f3a9c2e1b7d4f6a0e5c3b8d2f7a1e9c; consent=1; theme=dark"
              -H "referer: https://example.com/previous/page?utm_source=x"
            ) ;;
  *) echo "SHAPE must be 'browser' or 'bare', not '$SHAPE'" >&2; exit 1 ;;
esac


AKKAR_PORT=8403
LUVIT_PORT=8411
OPENRESTY_PORT=8412
LAPIS_PORT=8413

# akkar from its own checkout, the rest from the shared rock tree. Every Lua
# candidate here reads the SAME cqueues and lua-http out of ~/.luarocks, which
# is what makes the akkar/Lapis delta mean "akkar" and not "a different stack".
# Overridable, because `deploy.sh` already is (`${AKKAR_SRC:-$HOME/akkar}`)
# and the mismatch is silent: `AKKAR_SRC=... bash run.sh` staged one tree and
# measured another, and the run looked completely normal.
AKKAR_SRC="${AKKAR_SRC:-$HOME/akkar}"
ROCKS_PATH="$AKKAR_SRC/?.lua;$AKKAR_SRC/?/init.lua;$HOME/.luarocks/share/lua/5.4/?.lua;$HOME/.luarocks/share/lua/5.4/?/init.lua;;"
ROCKS_CPATH="$HOME/.luarocks/lib/lua/5.4/?.so;;"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# --------------------------------------------------------- the idle gate

# /proc/loadavg on this box does not decay and is not an instrument. vmstat is.
# This already cost one discarded run.
idle_gate() {
  local idle
  idle=$(vmstat 1 3 | tail -1 | awk '{print $15}')
  echo "cpu idle: ${idle}%"
  if [ "${idle:-0}" -lt 90 ]; then
    echo "REFUSING TO MEASURE: the machine is not quiet (${idle}% idle)."
    echo "A number taken here would be about the neighbour process, not akkar."
    exit 1
  fi
}

# ------------------------------------------------------------ lifecycle

stop_all() {
  pkill -f 'luvit-serve.lua'   2>/dev/null
  pkill -f 'rt-akkar-serve'    2>/dev/null
  pkill -f 'lapis-serve'       2>/dev/null
  [ -f /tmp/rt-openresty.pid ] && sudo kill "$(cat /tmp/rt-openresty.pid)" 2>/dev/null
  pkill -f 'nginx: master'     2>/dev/null
  sleep 1
}

wait_for_port() {   # port, seconds
  local port=$1 limit=${2:-20} n=0
  while [ $n -lt $((limit * 10)) ]; do
    curl -s -m 1 -o /dev/null "http://127.0.0.1:$port/ping" && return 0
    sleep .1; n=$((n + 1))
  done
  return 1
}

# D1: from exec to the first 200, in milliseconds. A runtime that takes two
# seconds to boot changes deployment, autoscaling and how tests are written.
# Nobody has measured akkar's.
boot_ms() {   # port, start-command...
  # ITS OWN POLL, AND NOT `wait_for_port`, WHICH SLEEPS A TENTH OF A SECOND.
  #
  # This used `wait_for_port`, whose loop is `sleep .1`. Any boot faster than
  # that is reported as one poll interval: the first curl fails, the shell
  # sleeps 100 ms, the second succeeds. So the published D1 table read
  #
  #     OpenResty 113 ms    Luvit 113 ms    akkar 114 ms
  #
  # and three different runtimes landing on the same number is the signature
  # of a quantised measurement, not of three runtimes being equal. **It was
  # measuring its own sleep.**
  #
  # Re-measured with the poll below, on the same box: an akkar app that
  # requires db, redis, jobs, auth and metrics answers in 29 ms, and akkar
  # alone in 21. `wait_for_port` keeps its 100 ms elsewhere, where it only
  # gates readiness and the granularity costs nothing.
  local port=$1; shift
  local t0 t1 n=0
  t0=$(date +%s%N)
  "$@" >/dev/null 2>&1 &
  while [ $n -lt 15000 ]; do
    curl -s -m 1 -o /dev/null "http://127.0.0.1:$port/ping" && break
    sleep 0.002; n=$((n + 1))
  done
  [ $n -ge 15000 ] && { echo "-1"; return; }
  t1=$(date +%s%N)
  echo $(( (t1 - t0) / 1000000 ))
}

# D2: resident memory of every process serving this port, summed.
rss_kb() {   # port
  local pids total=0
  pids=$(ss -ltnp "sport = :$1" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
  for p in $pids; do
    total=$((total + $(awk '/VmRSS/{print $2}' "/proc/$p/status" 2>/dev/null || echo 0)))
  done
  echo "$total"
}

# D3: THE DIMENSION THAT SEPARATES A RUNTIME FROM A FRAMEWORK.
#
# Open N keep-alive connections, park them, and measure what the process pays
# to hold them: descriptors and resident kilobytes, per connection. akkar's
# own numbers already have consequences here -- a controller costs 2
# descriptors on epoll and 3 on kqueue, which puts a hard wall near 500
# concurrent requests against ulimit -n 1024. No other candidate has ever been
# asked this question.
# MEDIDO EM DOIS TAMANHOS, E A DIVISAO SIMPLES ESTAVA ERRADA.
#
# `(rss1 - rss0) / n` nao e o custo por conexao. O delta tem uma parte FIXA --
# o processo cruzando uma fronteira de arena do alocador enquanto atende as
# primeiras conexoes -- e essa parte fixa era dividida por n e publicada como
# se fosse marginal. Medido no akkar, mesmo binario, mesma maquina:
#
#     n=200    10,24 KB/conexao    delta total 2.048 KB
#     n=800     6,40 KB/conexao    delta total 5.120 KB
#
# O numero cai 38% so por segurar mais conexoes. Resolvendo as duas equacoes:
# marginal 5,12 KB por conexao, fixo 1.024 KB. A 200 conexoes o fixo sozinho
# contribui 5,12 -- exatamente metade do que era publicado.
#
# Isso fez uma "regressao de 54% no custo por conexao ociosa" aparecer entre
# duas execucoes do bench quando o custo marginal nao tinha mudado: o que
# mudou foi o degrau fixo, num commit cujo heap Lua e IDENTICO (1.677,5 contra
# 1.677,3 KB) e cujo modulo isolado custa ZERO. Fronteira de malloc, nao codigo.
#
# O marginal e o numero que preve o que 10.000 conexoes custam. O fixo e real
# e vale reportar, mas e por PROCESSO e nao por conexao. Os dois, separados.
idle_conn_cost() {   # port, how many
  local port=$1 n=${2:-200}
  local pids fd0 fd1 rss0 rss1
  pids=$(ss -ltnp "sport = :$port" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
  [ -z "$pids" ] && { echo "- - -"; return; }

  count_fds() { local t=0; for p in $pids; do t=$((t + $(ls "/proc/$p/fd" 2>/dev/null | wc -l))); done; echo $t; }

  fd0=$(count_fds); rss0=$(rss_kb "$port")

  # Hold the connections open from a helper that does nothing but park them.
  python3 - "$port" "$n" <<'PY' &
import socket, sys, time
port, n = int(sys.argv[1]), int(sys.argv[2])
socks = []
for _ in range(n):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=5)
        s.sendall(b"GET /ping HTTP/1.1\r\nHost: x\r\nConnection: keep-alive\r\n\r\n")
        s.recv(4096)
        socks.append(s)
    except Exception:
        break
sys.stderr.write("held %d\n" % len(socks))
time.sleep(12)
PY
  local holder=$!
  sleep 5
  fd1=$(count_fds); rss1=$(rss_kb "$port")
  wait $holder 2>/dev/null

  awk -v f0="$fd0" -v f1="$fd1" -v r0="$rss0" -v r1="$rss1" -v n="$n" \
    'BEGIN { printf "%d %.3f %d", f1-f0, (f1-f0)/n, r1-r0 }'
}

# O marginal, resolvido a partir de dois tamanhos.
#
#     delta(n) = fixo + marginal * n
#
# Duas medicoes bastam. Reportar so uma e reportar `fixo/n + marginal` e
# chamar de marginal, que e exatamente o defeito que este bloco existe para
# nao repetir.
idle_conn_marginal() {   # port
  local port=$1 small=200 large=800
  local d_small d_large
  d_small=$(idle_conn_cost "$port" $small | awk '{print $3}')
  d_large=$(idle_conn_cost "$port" $large | awk '{print $3}')
  if [ -z "$d_small" ] || [ -z "$d_large" ]; then echo "- -"; return; fi

  awk -v ds="$d_small" -v dl="$d_large" -v s="$small" -v l="$large" 'BEGIN {
    marginal = (dl - ds) / (l - s)
    fixo     = ds - marginal * s
    # Um marginal negativo significa que o degrau engoliu o sinal. Dizer isso
    # e melhor que publicar um numero com o sinal invertido.
    if (marginal < 0) printf "INVERTIDO %.0f", fixo
    else              printf "%.2f %.0f", marginal, fixo
  }'
}

# D4: throughput and the tail. No mean -- a mean hides the tail, and the tail
# is the whole question.
load() {   # port, path
  taskset -c "$GEN_CPUS" wrk -t"$THREADS" -c"$CONNS" -d"${DUR}s" --latency \
    "${WRK_HEADERS[@]}" "http://127.0.0.1:$1$2" 2>/dev/null
}

# wrk 4.2 prints `50%    1.23ms` under "Latency Distribution", NOT the
# `50.000%` form. The first version of this matched only the latter and
# reported every percentile as "-", throwing away the tail -- and the tail is
# the whole question for a request pipeline. Both spellings match now.
parse_wrk() {   # stdin
  awk '
    /Requests\/sec/  { rps = $2 }
    /^ *50(\.000)?%/ { p50 = $2 }
    /^ *99(\.000)?%/ { p99 = $2 }
    # $5, NOT $4. wrk prints `Non-2xx or 3xx responses: 18640`, so $4 is the
    # literal word `responses:` -- a truthy-looking string in the column where
    # a count belongs. THIS HID A REAL DEFECT: a run reported
    # `non2xx responses:` while akkar was answering 18,640 errors out of
    # 111,651 requests, and the number that run published was taken from a
    # server failing one request in six.
    /Non-2xx or 3xx/ { bad = $5 }
    END { printf "%s %s %s %s", (rps?rps:"0"), (p50?p50:"-"), (p99?p99:"-"), (bad?bad:"0") }'
}

# --------------------------------------------------------------- start

start_akkar() {
  cd "$RT/svc" || return 1
  LUA_PATH="$ROCKS_PATH" LUA_CPATH="$ROCKS_CPATH" \
    taskset -c "$SVC_CPUS" lua5.4 rt-akkar-serve.lua "$AKKAR_PORT" 10
}
start_luvit() {
  cd "$RT/svc" || return 1
  taskset -c "$SVC_CPUS" "$RT/luvit/luvit" luvit-serve.lua "$LUVIT_PORT"
}
start_openresty() {
  taskset -c "$SVC_CPUS" openresty -p "$RT/svc/openresty" -c conf/nginx.conf
}
start_lapis() {
  cd "$RT/svc" || return 1
  LUA_PATH="./?.lua;$ROCKS_PATH" LUA_CPATH="$ROCKS_CPATH" \
    taskset -c "$SVC_CPUS" lua5.4 lapis-serve-run.lua "$LAPIS_PORT"
}

CANDIDATES="akkar luvit openresty lapis"
port_of() { case $1 in akkar) echo $AKKAR_PORT;; luvit) echo $LUVIT_PORT;;
                        openresty) echo $OPENRESTY_PORT;; lapis) echo $LAPIS_PORT;; esac; }

# ================================================================= run

say "idle gate"
idle_gate

say "Rule 1 — equivalence, before any clock starts"
stop_all
declare -A BOOT
for c in $CANDIDATES; do
  p=$(port_of "$c")
  BOOT[$c]=$(boot_ms "$p" "start_$c")
  if [ "${BOOT[$c]}" = "-1" ]; then
    echo "$c: DID NOT START — excluded from this run"
    continue
  fi
  body=$(curl -s -m 5 "http://127.0.0.1:$p/ping")
  canon=$(printf '%s' "$body" | python3 -c 'import json,sys;print(json.dumps(json.loads(sys.stdin.read()),sort_keys=True,separators=(",",":")))' 2>/dev/null)
  printf '%-10s boot %5s ms   /ping %s\n' "$c" "${BOOT[$c]}" "${canon:-UNPARSEABLE}"
  [ "$canon" = '{"pong":true}' ] || { echo "  ^ NOT EQUIVALENT — gate failed"; exit 1; }
done

say "D2 — resident memory, idle"
for c in $CANDIDATES; do
  p=$(port_of "$c")
  printf '%-10s %8s KB\n' "$c" "$(rss_kb "$p")"
done

say "D3 — cost per idle keep-alive connection"
echo "KB/conn is the MARGINAL cost, solved from n=200 and n=800. The fixed"
echo "step is per PROCESS and is reported beside it rather than divided by n."
printf '%-10s %8s %10s %10s %10s\n' candidate fds fds/conn KB/conn fixed_KB
for c in $CANDIDATES; do
  p=$(port_of "$c")
  fds_part=$(idle_conn_cost "$p" 200 | awk '{print $1" "$2}')
  marg_part=$(idle_conn_marginal "$p")
  printf '%-10s %8s %10s %10s %10s\n' "$c" $fds_part $marg_part
done

say "D4 — throughput and tail on /ping, ${REPS} reps, alternating order"
echo "request shape: $SHAPE ($((${#WRK_HEADERS[@]} / 2)) extra headers) -- numbers from"
echo "different shapes are not comparable; see the note beside SHAPE above."
for r in $(seq 1 "$REPS"); do
  for c in $CANDIDATES; do
    p=$(port_of "$c")
    read -r rps p50 p99 bad <<<"$(load "$p" /ping | parse_wrk)"
    printf 'rep%-2s %-10s %12s rps   p50 %-9s p99 %-9s non2xx %s\n' \
      "$r" "$c" "$rps" "$p50" "$p99" "$bad"
    echo "$r $c $rps $p50 $p99 $bad" >> "$OUT/d4-ping.txt"
  done
done

say "Rule 3 — the spread each candidate showed, as its noise floor"
# A difference smaller than the larger of two floors is not a result. Printed
# rather than left for someone to eyeball a column of numbers.
# FIELD 6 IS THE ERROR COUNT AND THIS USED TO IGNORE IT.
#
# `parse_wrk` was fixed to read the right awk field, and this summariser was
# left reading only $2 and $3 -- so a repetition that failed 16,529 of its
# requests was averaged into the mean like any other, with the evidence
# printed on the line above it and nothing acting on it. Half a gate is not a
# gate: the harness went on publishing a number from a failing server, just
# more legibly.
#
# A candidate with ANY failing repetition is now reported as such and its mean
# is refused, because a mean over a server that was erroring is not slower or
# faster, it is not a measurement. Errors are cheap to serve, so such a number
# flatters the candidate producing them.
awk '{ n[$2]++; s[$2]+=$3; bad[$2] += $6
       if (!(($2) in mx) || $3 > mx[$2]) mx[$2] = $3
       if (!(($2) in mn) || $3 < mn[$2]) mn[$2] = $3 }
     END { for (c in n) {
             if (bad[c] > 0)
               printf "%-10s REFUSED -- %d non-2xx across %d reps; a mean over a failing server is not a measurement\n",
                 c, bad[c], n[c]
             else
               printf "%-10s mean %10.0f rps   spread %.2f%%\n",
                 c, s[c]/n[c], 100*(mx[c]-mn[c])/(s[c]/n[c])
           } }' "$OUT/d4-ping.txt" | sort

say "D6 — the artefact you deploy"
echo "measured separately; akkar's is 5.08 MB via \`akkar build\` (docs/RUNTIME.md)"

stop_all
say "NOT covered by this run"
echo "D5 saturation and D7 dependency-down are a second pass."
echo "Nothing here is a claim until it is in RESULTS.md with the box's state."
