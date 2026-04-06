#!/usr/bin/env bash

set -euo pipefail

REPO_URL="${REPO_URL:-}"
REPO_DIR="${REPO_DIR:-/recon-repo}"
RUNTIME_DIR="${RUNTIME_DIR:-/recon}"
INSTALL_USER="${SUDO_USER:-${USER:-root}}"
PROGRAMS_DIR="$RUNTIME_DIR/programs"
TARGETS_DIR="$RUNTIME_DIR/targets"
JOBS_DIR="$RUNTIME_DIR/jobs"
CONFIG_DIR="$RUNTIME_DIR/config"
LOG_DIR="$RUNTIME_DIR/logs"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "This script is intended for Ubuntu 22.04 EC2 hosts." >&2
  exit 1
fi

if [[ ! -f /etc/os-release ]] || ! grep -q 'Ubuntu' /etc/os-release; then
  echo "Ubuntu is required." >&2
  exit 1
fi

sudo_cmd=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  sudo_cmd="sudo"
fi

install_packages() {
  $sudo_cmd apt-get update
  $sudo_cmd apt-get install -y \
    ca-certificates \
    curl \
    git \
    golang-go \
    cron \
    jq \
    python3 \
    python3-pip \
    unzip
}

install_go_tools() {
  export GOPATH="${GOPATH:-$HOME/go}"
  export PATH="$PATH:$GOPATH/bin"

  go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
  go install github.com/projectdiscovery/httpx/cmd/httpx@latest
  go install github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest
  go install github.com/projectdiscovery/notify/cmd/notify@latest
  go install github.com/tomnomnom/anew@latest

  $sudo_cmd mkdir -p /usr/local/bin
  for bin in subfinder httpx nuclei notify anew; do
    if [[ -x "$GOPATH/bin/$bin" ]]; then
      $sudo_cmd ln -sf "$GOPATH/bin/$bin" "/usr/local/bin/$bin"
    fi
  done
}

setup_runtime() {
  $sudo_cmd mkdir -p "$PROGRAMS_DIR" "$TARGETS_DIR" "$JOBS_DIR" "$CONFIG_DIR" "$LOG_DIR"
  $sudo_cmd chown -R "$INSTALL_USER:$INSTALL_USER" "$RUNTIME_DIR"
  chmod 755 "$RUNTIME_DIR" "$PROGRAMS_DIR" "$TARGETS_DIR" "$JOBS_DIR" "$CONFIG_DIR" "$LOG_DIR"
}

setup_repo() {
  if [[ -z "$REPO_URL" ]]; then
    if [[ -d "$REPO_DIR/.git" ]]; then
      echo "Repo already exists at $REPO_DIR"
      return
    fi
    echo "Set REPO_URL to clone the repo on first install." >&2
    exit 1
  fi

  if [[ -d "$REPO_DIR/.git" ]]; then
    $sudo_cmd chown -R "$INSTALL_USER:$INSTALL_USER" "$REPO_DIR"
    if [[ "$INSTALL_USER" == "root" ]]; then
      git -C "$REPO_DIR" pull --ff-only
    else
      $sudo_cmd -u "$INSTALL_USER" git -C "$REPO_DIR" pull --ff-only
    fi
  else
    $sudo_cmd mkdir -p "$REPO_DIR"
    $sudo_cmd chown "$INSTALL_USER:$INSTALL_USER" "$REPO_DIR"
    if [[ "$INSTALL_USER" == "root" ]]; then
      git clone "$REPO_URL" "$REPO_DIR"
    else
      $sudo_cmd -u "$INSTALL_USER" git clone "$REPO_URL" "$REPO_DIR"
    fi
  fi
}

install_cron() {
  local sync_job="*/5 * * * * RECON_ROOT=$RUNTIME_DIR $REPO_DIR/scripts/sync_programs.sh >> $LOG_DIR/scheduler.log 2>&1"
  local run_job="* * * * * RECON_ROOT=$RUNTIME_DIR $REPO_DIR/scripts/run_jobs.sh >> $LOG_DIR/workers.log 2>&1"
  local update_job="0 */6 * * * RECON_ROOT=$RUNTIME_DIR $REPO_DIR/scripts/update_templates.sh >> $LOG_DIR/templates.log 2>&1"
  local path_line="PATH=/usr/local/bin:/usr/bin:/bin"

  local current
  current="$(crontab -l 2>/dev/null || true)"

  {
    printf '%s\n' "$path_line"
    printf '%s\n' "$current"
    printf '%s\n' "$sync_job"
    printf '%s\n' "$run_job"
    printf '%s\n' "$update_job"
  } | awk 'NF && !seen[$0]++' | crontab -
}

main() {
  install_packages
  install_go_tools
  setup_runtime
  setup_repo
  install_cron

  echo "EC2 setup complete."
  echo "Next: copy config examples into $CONFIG_DIR and set RECON_USE_SUBFINDER/HTTPX/NUCLEI=true if desired."
}

main "$@"
