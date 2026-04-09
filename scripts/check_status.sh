#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

echo "== Tools =="
for tool in subfinder httpx nuclei notify anew; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '%s: %s\n' "$tool" "$(command -v "$tool")"
  else
    printf '%s: missing\n' "$tool"
  fi
done

echo
echo "== Cron =="
crontab -l 2>/dev/null || true

echo
echo "== Jobs =="
shopt -s nullglob
for job in "$JOBS_DIR"/*.job; do
  echo "-- $(basename "$job") --"
  cat "$job"
done

echo
echo "== Latest Pipeline Summaries =="
for target in "$TARGETS_DIR"/*; do
  [[ -d "$target" ]] || continue
  if [[ -f "$target/pipeline.log" ]]; then
    echo "-- $(basename "$target") --"
    tail -n 5 "$target/pipeline.log"
  fi
done
