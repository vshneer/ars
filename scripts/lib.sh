#!/usr/bin/env bash

set -euo pipefail

RECON_ROOT="${RECON_ROOT:-/recon}"
PROGRAMS_DIR="${PROGRAMS_DIR:-$RECON_ROOT/programs}"
TARGETS_DIR="${TARGETS_DIR:-$RECON_ROOT/targets}"
JOBS_DIR="${JOBS_DIR:-$RECON_ROOT/jobs}"
CONFIG_DIR="${CONFIG_DIR:-$RECON_ROOT/config}"
LOG_DIR="${LOG_DIR:-$RECON_ROOT/logs}"
NUCLEI_TEMPLATES_DIR="${NUCLEI_TEMPLATES_DIR:-$HOME/nuclei-templates}"
SUBFINDER_CONFIG_FILE="${SUBFINDER_CONFIG_FILE:-$CONFIG_DIR/subfinder.yaml}"
SUBFINDER_PROVIDER_CONFIG_FILE="${SUBFINDER_PROVIDER_CONFIG_FILE:-$CONFIG_DIR/subfinder-config.yaml}"
NOTIFY_CONFIG_FILE="${NOTIFY_CONFIG_FILE:-$CONFIG_DIR/notify-config.yaml}"
FINDINGS_S3_BUCKET="${FINDINGS_S3_BUCKET:-}"
FINDINGS_S3_PREFIX="${FINDINGS_S3_PREFIX:-recon}"
DIRSEARCH_MAX_RATE="${DIRSEARCH_MAX_RATE:-1}"
DIRSEARCH_THREADS="${DIRSEARCH_THREADS:-5}"
DIRSEARCH_DELAY="${DIRSEARCH_DELAY:-0.2}"
DIRSEARCH_INCLUDE_STATUS="${DIRSEARCH_INCLUDE_STATUS:-200-299,403,500-599}"

mkdir -p "$PROGRAMS_DIR" "$TARGETS_DIR" "$JOBS_DIR" "$CONFIG_DIR" "$LOG_DIR"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  local level="$1"
  shift
  local program="${1:-system}"
  if [[ $# -gt 1 ]]; then
    shift
  fi
  printf '%s [%s] [%s] %s\n' "$(timestamp)" "$level" "$program" "$*"
}

program_yaml() {
  printf '%s/%s.yaml' "$PROGRAMS_DIR" "$1"
}

target_dir() {
  printf '%s/%s' "$TARGETS_DIR" "$1"
}

job_file() {
  printf '%s/%s.job' "$JOBS_DIR" "$1"
}

update_job_status() {
  local program="$1"
  local status="$2"
  local started_at="${3:-}"
  local finished_at="${4:-}"
  local job
  job="$(job_file "$program")"
  {
    printf 'program=%s\n' "$program"
    printf 'status=%s\n' "$status"
    if [[ -n "$started_at" ]]; then
      printf 'started_at=%s\n' "$started_at"
    fi
    if [[ -n "$finished_at" ]]; then
      printf 'finished_at=%s\n' "$finished_at"
    fi
  } >"$job"
}
