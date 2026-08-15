#!/usr/bin/env bash
# Samples system state to disk every 5 seconds.
#
# Two machines died mid-benchmark and left nothing to read: the console log
# showed a healthy login prompt and no kernel message of any kind, which ruled
# out OOM, file-max and conntrack exhaustion but named no replacement. Three
# hypotheses were argued from symptoms alone and two of them were wrong.
#
# This is the file that ends that. It costs one process and a few KB a minute.
LOG=/var/log/akkar-watch.log
echo "# started $(date -u +%FT%TZ) on $(hostname)" >> "$LOG"
echo "# time load procs threads fd_used fd_max conntrack ct_max mem_avail_mb tcp_estab tcp_tw sshd" >> "$LOG"
while true; do
  read -r fd_used fd_free fd_max < /proc/sys/fs/file-nr
  ct=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo 0)
  ct_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo 0)
  printf '%s %s %s %s %s %s %s %s %s %s %s %s\n' \
    "$(date -u +%FT%TZ)" \
    "$(cut -d' ' -f1 /proc/loadavg)" \
    "$(ls -d /proc/[0-9]* | wc -l)" \
    "$(cut -d' ' -f4 /proc/loadavg | cut -d/ -f2)" \
    "$fd_used" "$fd_max" "$ct" "$ct_max" \
    "$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)" \
    "$(ss -tan state established 2>/dev/null | wc -l)" \
    "$(ss -tan state time-wait 2>/dev/null | wc -l)" \
    "$(pgrep -c sshd 2>/dev/null || echo 0)" \
    >> "$LOG"
  sleep 5
done
