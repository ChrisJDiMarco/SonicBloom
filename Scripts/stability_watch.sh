#!/usr/bin/env bash
set -euo pipefail

duration_seconds="${1:-1800}"
interval_seconds="${2:-30}"
output_dir="dist/stability"
mkdir -p "$output_dir"

stamp="$(date +%Y%m%d-%H%M%S)"
log="$output_dir/SonicBloom-stability-$stamp.log"
deadline=$((SECONDS + duration_seconds))

{
  echo "SonicBloom stability watch"
  echo "Started: $(date)"
  echo "Duration: ${duration_seconds}s"
  echo "Interval: ${interval_seconds}s"
  echo "Commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo
} >> "$log"

while (( SECONDS < deadline )); do
  pid="$(pgrep -x SonicBloom | head -1 || true)"
  {
    echo "== $(date) =="
    if [[ -n "$pid" ]]; then
      ps -p "$pid" -o pid,%cpu,rss,etime,command
    else
      echo "SonicBloom: not running"
    fi
    ps -axo pid,%cpu,rss,comm | awk '/coreaudiod|SonicBloom/ {print}'
    ls -t "$HOME/Library/Logs/DiagnosticReports"/SonicBloom*.crash 2>/dev/null | head -3 || true
    echo
  } >> "$log"
  sleep "$interval_seconds"
done

echo "Finished: $(date)" >> "$log"
echo "$log"
