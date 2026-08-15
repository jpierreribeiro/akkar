#!/usr/bin/env bash
# Copies the study log and the watchdog log off the box, continuously.
#
# Three benchmark machines have gone unreachable mid-run. Twice the results
# were still on the box and unreadable; the third time this script existed and
# destroyed them anyway, because it was written as
#
#     ssh ... > study-live.log
#
# and the shell truncates the file BEFORE running ssh. The cycle where the
# machine died therefore emptied both files -- forty-three good cycles undone
# by the one that failed. Download to a temporary, promote only when something
# arrived.
set -uo pipefail
HOST=${1:?usage: mirror.sh <host> [key]}
KEY=${2:-$HOME/Downloads/colossus.pem}
OUT=$(dirname "$0")/results
mkdir -p "$OUT"

fetch() {                                  # remote-command, destination
  local tmp; tmp=$(mktemp)
  if ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=15 "ubuntu@$HOST" "$1" > "$tmp" 2>/dev/null \
     && [ -s "$tmp" ]; then
    mv "$tmp" "$2"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

while true; do
  fetch 'cat ~/study/study.log'              "$OUT/study.log"
  fetch 'sudo cat /var/log/akkar-watch.log'  "$OUT/watch.log" || {
    echo "$(date -u +%FT%TZ) host unreachable; keeping what we have" >&2
  }
  sleep 30
done
