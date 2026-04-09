#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

shopt -s nullglob

for yaml in "$PROGRAMS_DIR"/*.yaml; do
  program="$(python3 "$SCRIPT_DIR/reconlib.py" get "$yaml" program | tr '[:upper:]' '[:lower:]')"
  if [[ -z "$program" ]]; then
    log ERROR system "Skipping program file without program key: $yaml"
    continue
  fi

  mkdir -p "$(target_dir "$program")"
  if [[ ! -f "$(job_file "$program")" ]]; then
    update_job_status "$program" pending "" ""
    log INFO "$program" "Created job file"
  fi
done
