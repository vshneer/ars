#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

program="${1:-}"
if [[ -z "$program" ]]; then
  log ERROR system "Usage: run_pipeline.sh <program>"
  exit 1
fi

yaml="$(program_yaml "$program")"
if [[ ! -f "$yaml" ]]; then
  log ERROR "$program" "Missing program YAML: $yaml"
  exit 1
fi

program_target="$(target_dir "$program")"
mkdir -p "$program_target"

started_at="$(timestamp)"

lock_dir="$program_target/lock"
lock_acquired=0
cleanup() {
  if [[ "$lock_acquired" -eq 1 ]]; then
    rm -rf "$lock_dir"
  fi
}
trap cleanup EXIT INT TERM
trap 'update_job_status "$program" failed "$started_at" "$(timestamp)"' ERR

if ! mkdir "$lock_dir" 2>/dev/null; then
  log INFO "$program" "Lock already present, skipping"
  exit 0
fi

lock_acquired=1

update_job_status "$program" running "$started_at" ""

log INFO "$program" "Pipeline started"

subs_file="$program_target/subs.txt"
filtered_file="$program_target/filtered_subs.txt"
live_file="$program_target/live.txt"
findings_raw="$program_target/findings.raw"
findings_file="$program_target/findings.json"

: >"$subs_file"

mapfile -t in_scope < <(python3 "$SCRIPT_DIR/reconlib.py" list "$yaml" in_scope)
mapfile -t out_scope < <(python3 "$SCRIPT_DIR/reconlib.py" list "$yaml" out_of_scope)

for scope in "${in_scope[@]}"; do
  base_scope="${scope#*.}"
  if [[ "$base_scope" == "$scope" ]]; then
    base_scope="$scope"
  fi

  if [[ "${RECON_USE_SUBFINDER:-false}" == "true" ]] && command -v subfinder >/dev/null 2>&1; then
    subfinder_args=(-d "$base_scope" -silent)
    if [[ -f "$SUBFINDER_CONFIG_FILE" ]]; then
      subfinder_args+=(-config "$SUBFINDER_CONFIG_FILE")
    fi
    subfinder "${subfinder_args[@]}" >>"$subs_file" 2>/dev/null || true
  else
    printf '%s\n' "$base_scope" >>"$subs_file"
  fi
done

sort -u "$subs_file" -o "$subs_file" || true
python3 "$SCRIPT_DIR/reconlib.py" filter-scope "$yaml" "$subs_file" "$filtered_file"

probe_live_host() {
  local host="$1"
  local scheme url status
  for scheme in https http; do
    url="${scheme}://${host}"
    status="$(curl -k -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || true)"
    case "$status" in
      2*|3*)
        printf '%s\n' "$url"
        return 0
        ;;
    esac
  done
  return 1
}

: >"$live_file"
if [[ "${RECON_USE_HTTPX:-false}" == "true" ]] && command -v httpx >/dev/null 2>&1; then
  httpx -silent -json -tech-detect -status-code <"$filtered_file" >"$live_file" 2>/dev/null || true
else
  while IFS= read -r host; do
    [[ -z "$host" ]] && continue
    probe_live_host "$host" >>"$live_file" || true
  done <"$filtered_file"
fi

if [[ "${RECON_USE_NUCLEI:-false}" == "true" ]] && [[ -s "$live_file" ]] && command -v nuclei >/dev/null 2>&1 && [[ -d "$NUCLEI_TEMPLATES_DIR" ]]; then
  nuclei -l "$live_file" -tags cves,misconfig,exposure -severity medium,high,critical -json -o "$findings_raw" -t "$NUCLEI_TEMPLATES_DIR" 2>/dev/null || true
else
  : >"$findings_raw"
fi

python3 "$SCRIPT_DIR/reconlib.py" annotate-findings "$program" "$findings_raw" "$findings_file"

if [[ -s "$findings_file" ]] && command -v notify >/dev/null 2>&1 && [[ -f "$NOTIFY_CONFIG_FILE" ]]; then
  notify -pc "$NOTIFY_CONFIG_FILE" <"$findings_file" 2>/dev/null || true
elif [[ -s "$findings_file" ]]; then
  log WARN "$program" "Skipping notify because $NOTIFY_CONFIG_FILE is missing"
fi

finished_at="$(timestamp)"
update_job_status "$program" complete "$started_at" "$finished_at"
log INFO "$program" "Pipeline finished"
