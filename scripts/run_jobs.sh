#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

MAX_JOBS="${MAX_JOBS:-5}"
log INFO system "Job scheduler started"

shopt -s nullglob
pids=()
declare -A seen_programs=()

for job in "$JOBS_DIR"/*.job; do
  program="$(awk -F= '$1 == "program" {print $2}' "$job" | tr '[:upper:]' '[:lower:]')"

  [[ -z "$program" ]] && continue
  if [[ -n "${seen_programs[$program]:-}" ]]; then
    continue
  fi
  seen_programs["$program"]=1

  if [[ -d "$(target_dir "$program")/lock" ]]; then
    log INFO "$program" "Already running"
    continue
  fi

  while [[ "${#pids[@]}" -ge "$MAX_JOBS" ]]; do
    wait "${pids[0]}" || true
    pids=("${pids[@]:1}")
  done

  "$SCRIPT_DIR/run_pipeline.sh" "$program" &
  pids+=("$!")
done

for pid in "${pids[@]}"; do
  wait "$pid" || true
done

log INFO system "Job scheduler finished"
