#!/usr/bin/env bash

set -euo pipefail

shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

program="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
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
pipeline_log="$program_target/pipeline.log"
: >"$pipeline_log"

stage_log() {
  local message="$1"
  log INFO "$program" "$message"
  printf '%s [%s] [%s] %s\n' "$(timestamp)" "INFO" "$program" "$message" >>"$pipeline_log"
}

debug_log() {
  local message="$1"
  if [[ "${RECON_DEBUG:-false}" == "true" ]]; then
    log INFO "$program" "DEBUG: $message"
  fi
  printf '%s [%s] [%s] %s\n' "$(timestamp)" "DEBUG" "$program" "$message" >>"$pipeline_log"
}

line_count() {
  local file="$1"
  if [[ -s "$file" ]]; then
    wc -l <"$file" | tr -d ' '
  else
    printf '0'
  fi
}

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

stage_log "Pipeline started"

subs_file="$program_target/subs.txt"
filtered_file="$program_target/filtered_subs.txt"
live_file="$program_target/live.txt"
live_urls_file="$program_target/live_urls.txt"
seed_file="$program_target/discovery_seeds.txt"
scope_file="$program_target/scope_targets.txt"
raw_subs_file="$program_target/subs.raw.txt"
new_subs_file="$program_target/subs.new.txt"
dirsearch_dir="$program_target/dirsearch"
dirsearch_output="$program_target/dirsearch.out"

: >"$seed_file"
: >"$scope_file"
: >"$raw_subs_file"
: >"$new_subs_file"
: >"$dirsearch_output"
: >"$live_urls_file"
mkdir -p "$dirsearch_dir"

mapfile -t in_scope < <(python3 "$SCRIPT_DIR/reconlib.py" list "$yaml" in_scope)
mapfile -t out_scope < <(python3 "$SCRIPT_DIR/reconlib.py" list "$yaml" out_of_scope)

for scope in "${in_scope[@]}"; do
  base_scope="$scope"
  if [[ "$scope" == \*.* ]]; then
    base_scope="${scope#*.}"
  fi
  printf '%s\n' "$base_scope" >>"$seed_file"
  printf '%s\n' "$base_scope" >>"$scope_file"
done

sort -u "$seed_file" -o "$seed_file" || true
sort -u "$scope_file" -o "$scope_file" || true
stage_log "Discovery seeds prepared: $(line_count "$seed_file") domains"

if [[ "${RECON_USE_SUBFINDER:-true}" == "true" ]] && command -v subfinder >/dev/null 2>&1; then
  subfinder_args=(-dL "$seed_file" -silent)
  if [[ -f "$SUBFINDER_CONFIG_FILE" ]]; then
    subfinder_args+=(-config "$SUBFINDER_CONFIG_FILE")
  fi
  if [[ -f "$SUBFINDER_PROVIDER_CONFIG_FILE" ]]; then
    subfinder_args+=(-pc "$SUBFINDER_PROVIDER_CONFIG_FILE")
  fi
  debug_log "Running: subfinder ${subfinder_args[*]}"
  if ! subfinder "${subfinder_args[@]}" 2>>"$pipeline_log" \
    | grep -E '^[A-Za-z0-9._-]+$' \
    | tee -a "$raw_subs_file" \
    | tee "$new_subs_file" >/dev/null; then
    stage_log "subfinder completed with errors"
  fi
else
  debug_log "subfinder unavailable or disabled; using scope seeds directly"
  cat "$seed_file" | tee -a "$raw_subs_file" | tee "$new_subs_file" >/dev/null
fi

append_unique_lines() {
  local input_file="$1"
  local output_file="$2"
  local existing_file="$3"
  if command -v anew >/dev/null 2>&1; then
    local new_file
    new_file="$(mktemp)"
    cat "$input_file" | anew "$existing_file" >"$new_file"
    cat "$existing_file" "$new_file" 2>/dev/null | awk 'NF && !seen[$0]++' >"$output_file.tmp"
    mv "$output_file.tmp" "$output_file"
    rm -f "$new_file"
    return 0
  fi
  cat "$existing_file" "$input_file" 2>/dev/null | awk 'NF && !seen[$0]++' >"$output_file.tmp"
  mv "$output_file.tmp" "$output_file"
}

append_unique_lines "$new_subs_file" "$subs_file" "$subs_file"
stage_log "Discovery complete: $(line_count "$raw_subs_file") raw hosts, $(line_count "$subs_file") unique total, $(line_count "$new_subs_file") new this run"

probe_candidates="$program_target/probe_candidates.txt"
cat "$new_subs_file" "$scope_file" 2>/dev/null | awk 'NF && !seen[$0]++' >"$probe_candidates"

python3 "$SCRIPT_DIR/reconlib.py" filter-out-scope "$yaml" "$probe_candidates" "$filtered_file"
stage_log "Scope filter complete: $(line_count "$filtered_file") probe candidates after out_of_scope removal"

probe_live_host() {
  local host="$1"
  local scheme url status
  for scheme in https http; do
    url="${scheme}://${host}"
    status="$(curl -k -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null || true)"
    case "$status" in
      000|'') ;;
      *) printf '%s\n' "$url"; return 0 ;;
    esac
  done
  return 1
}

: >"$live_file"
if [[ "${RECON_USE_HTTPX:-true}" == "true" ]] && command -v httpx >/dev/null 2>&1; then
  debug_log "Running: httpx -l $filtered_file -silent -json -tech-detect -status-code"
  if ! httpx -l "$filtered_file" -silent -json -tech-detect -status-code >"$live_file" 2>>"$pipeline_log"; then
    stage_log "httpx completed with errors"
  fi
  python3 - "$live_file" "$live_urls_file" <<'PY'
import json
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
urls = []
if src.exists():
    for line in src.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        url = record.get("url")
        if url:
            urls.append(url)
dst.write_text("\n".join(urls) + ("\n" if urls else ""))
PY
else
  while IFS= read -r host; do
    [[ -z "$host" ]] && continue
    probe_live_host "$host" >>"$live_urls_file" || true
  done <"$filtered_file"
  cp "$live_urls_file" "$live_file"
fi
stage_log "Probe complete: $(line_count "$live_urls_file") live hosts"

dirsearch_hits_file="$program_target/dirsearch_hits.txt"
: >"$dirsearch_hits_file"

if [[ "${RECON_USE_DIRSEARCH:-true}" == "true" ]] && [[ -s "$live_file" ]]; then
  if command -v dirsearch >/dev/null 2>&1; then
    debug_log "Running: dirsearch --urls-file=$live_urls_file --max-rate=${DIRSEARCH_MAX_RATE:-1} --threads=${DIRSEARCH_THREADS:-5} --delay=${DIRSEARCH_DELAY:-0.2} -o $dirsearch_output -O plain"
    if ! dirsearch --urls-file="$live_urls_file" --max-rate="$DIRSEARCH_MAX_RATE" --threads="$DIRSEARCH_THREADS" --delay="$DIRSEARCH_DELAY" -o "$dirsearch_output" -O plain 2>>"$pipeline_log"; then
      stage_log "dirsearch completed with errors"
    fi
  else
    stage_log "dirsearch unavailable; skipping scan"
  fi
fi

if [[ -f "$dirsearch_output" ]]; then
  cp "$dirsearch_output" "$dirsearch_hits_file"
fi
stage_log "Dirsearch complete: $(line_count "$dirsearch_hits_file") output lines"

if [[ -n "$FINDINGS_S3_BUCKET" ]]; then
  run_stamp="$(timestamp | tr ': ' '--')"
  s3_prefix="${FINDINGS_S3_PREFIX%/}/$program/$run_stamp"
  aws s3 cp "$program_target" "s3://$FINDINGS_S3_BUCKET/$s3_prefix" --recursive >>"$pipeline_log" 2>&1 || stage_log "S3 upload completed with errors"
  stage_log "Uploaded artifacts to s3://$FINDINGS_S3_BUCKET/$s3_prefix"
else
  stage_log "Skipping S3 upload because FINDINGS_S3_BUCKET is missing"
fi

stage_log "Summary: new=$(line_count "$new_subs_file") filtered=$(line_count "$filtered_file") probed=$(line_count "$live_file") dirsearch=$(line_count "$dirsearch_hits_file")"

finished_at="$(timestamp)"
update_job_status "$program" complete "$started_at" "$finished_at"
stage_log "Pipeline finished"
