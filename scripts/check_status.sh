#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

echo "== Tools =="
for tool in subfinder pd-httpx httpx dirsearch anew; do
  if command -v "$tool" >/dev/null 2>&1; then
    printf '%s: %s\n' "$tool" "$(command -v "$tool")"
  else
    printf '%s: missing\n' "$tool"
  fi
done

echo
echo "== Python =="
python3 --version 2>/dev/null || true
python3.11 --version 2>/dev/null || true

echo
echo "== S3 =="
printf 'FINDINGS_S3_BUCKET=%s\n' "${FINDINGS_S3_BUCKET:-unset}"
printf 'FINDINGS_S3_PREFIX=%s\n' "${FINDINGS_S3_PREFIX:-recon}"

echo
echo "== Cron =="
crontab -l 2>/dev/null || true

echo
echo "== Weekly Scan =="
printf 'DIRSEARCH_MAX_RATE=%s\n' "${DIRSEARCH_MAX_RATE:-1}"
printf 'DIRSEARCH_THREADS=%s\n' "${DIRSEARCH_THREADS:-5}"
printf 'DIRSEARCH_DELAY=%s\n' "${DIRSEARCH_DELAY:-0.2}"
printf 'DIRSEARCH_INCLUDE_STATUS=%s\n' "${DIRSEARCH_INCLUDE_STATUS:-200-299,403,500-599}"

echo
echo "== Subfinder Config =="
printf 'SUBFINDER_CONFIG_FILE=%s\n' "$SUBFINDER_CONFIG_FILE"
printf 'SUBFINDER_PROVIDER_CONFIG_FILE=%s\n' "$SUBFINDER_PROVIDER_CONFIG_FILE"

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
