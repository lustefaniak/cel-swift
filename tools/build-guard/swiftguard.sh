#!/bin/bash
# Memory watchdog for Swift builds (macOS ignores ulimit -v/-d). Kills any swift-frontend over PER_GB,
# and the biggest swift process when all of them together exceed TOTAL_GB. Started by swiftlock.
PER_GB=${PER_GB:-8}; TOTAL_GB=${TOTAL_GB:-24}; LOG=${LOG:-$HOME/.cache/cel-swift-build-guard/guard.log}
mkdir -p "$(dirname "$LOG")"
while true; do
  total=0; big=""; bigrss=0
  while read -r rss pid cmd; do
    total=$((total+rss))
    if [ "$rss" -gt "$bigrss" ]; then bigrss=$rss; big=$pid; bigcmd=$cmd; fi
    if [ "$rss" -gt $((PER_GB*1048576)) ]; then
      files=$(echo "$cmd" | tr ' ' '\n' | grep -A1 -e '-primary-file' | grep -v -e '-primary-file' -e '^--$' | xargs -n1 basename 2>/dev/null | tr '\n' ' ')
      echo "$(date '+%F %T') KILL pid=$pid rss=$((rss/1048576))GB files=[$files] cmd=${cmd:0:300}" >> "$LOG"
      kill -9 "$pid"
    fi
  done < <(ps -axo rss=,pid=,command= | awk '$3 ~ /swift-frontend|swift-build|swift-test|swiftc|xctest|CELConformance|cel-swiftPackageTests/')
  if [ "$total" -gt $((TOTAL_GB*1048576)) ] && [ -n "$big" ]; then
    echo "$(date '+%F %T') KILL-TOTAL total=$((total/1048576))GB pid=$big rss=$((bigrss/1048576))GB cmd=${bigcmd:0:300}" >> "$LOG"
    kill -9 "$big"
  fi
  sleep 0.5
done
