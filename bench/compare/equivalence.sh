#!/usr/bin/env bash
#
# Rule 1: every candidate does the same work, and it is proven before any
# clock starts.
#
# A load generator being rejected still reports a number, and the number looks
# like a number.  So does a framework that is fast because it skips the error
# path, or returns a smaller object, or answers 200 to something the others
# reject.  This diffs actual responses.
set -uo pipefail

GIN="${GIN:-8401}"
FASTAPI="${FASTAPI:-8402}"
AKKAR="${AKKAR:-8403}"

fail=0

# Fields only, ignoring key order, since three JSON encoders will not agree on
# ordering and that is not a semantic difference.
canonical() {
  python3 -c '
import json,sys
try:
    print(json.dumps(json.loads(sys.stdin.read()), sort_keys=True, separators=(",",":")))
except Exception as e:
    print("UNPARSEABLE:" + str(e))
'
}

probe() {   # path, expected status
  local path="$1" want="$2"
  local names=(gin fastapi akkar) ports=("$GIN" "$FASTAPI" "$AKKAR")
  local bodies=() statuses=()

  for i in 0 1 2; do
    local out code
    out=$(curl -s --max-time 10 -w '\n%{http_code}' "http://127.0.0.1:${ports[$i]}$path" 2>/dev/null)
    code="${out##*$'\n'}"
    bodies+=("$(printf '%s' "${out%$'\n'*}" | canonical)")
    statuses+=("$code")
  done

  local ok=1
  for i in 0 1 2; do
    [ "${statuses[$i]}" = "$want" ] || ok=0
  done
  [ "${bodies[0]}" = "${bodies[1]}" ] && [ "${bodies[1]}" = "${bodies[2]}" ] || ok=0

  if [ "$ok" -eq 1 ]; then
    printf "  %-22s %s  all three: %s\n" "$path" "$want" "${bodies[0]:0:58}"
  else
    fail=1
    printf "  %-22s MISMATCH\n" "$path"
    for i in 0 1 2; do
      printf "      %-8s %-4s %s\n" "${names[$i]}" "${statuses[$i]}" "${bodies[$i]:0:70}"
    done
  fi
}

echo "# semantic equivalence, checked before any timing"
probe /ping         200
probe /users/42     200
probe /users/999999 404
probe /users/abc    422
probe /users/0      422

echo
if [ "$fail" -eq 0 ]; then
  echo "EQUIVALENT: the three do the same work, so a timing comparison means something."
else
  echo "NOT EQUIVALENT: fix the differences above.  Numbers taken now would compare"
  echo "different work and look exactly like a performance result."
  exit 1
fi
