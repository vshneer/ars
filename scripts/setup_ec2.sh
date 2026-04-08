#!/usr/bin/env bash

set -euo pipefail

REPO_URL="${REPO_URL:-}"
REPO_DIR="${REPO_DIR:-/recon-repo}"
RUNTIME_DIR="${RUNTIME_DIR:-/recon}"
INSTALL_USER="${INSTALL_USER:-${SUDO_USER:-${USER:-root}}}"
INSTALL_HOME="${INSTALL_HOME:-$(getent passwd "$INSTALL_USER" | cut -d: -f6)}"
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

run_as_install_user() {
  if [[ "$INSTALL_USER" == "$(id -un)" ]]; then
    "$@"
  else
    sudo -H -u "$INSTALL_USER" "$@"
  fi
}

install_packages() {
  $sudo_cmd apt-get update
  $sudo_cmd apt-get install -y \
    ca-certificates \
    awscli \
    curl \
    git \
    cron \
    jq \
    python3 \
    python3-pip \
    unzip

  systemctl enable --now amazon-ssm-agent 2>/dev/null || true
}

setup_swap() {
  if swapon --show | awk 'NR>1 {found=1} END {exit !found}'; then
    return
  fi

  local swapfile="/swapfile"
  if [[ ! -f "$swapfile" ]]; then
    fallocate -l 2G "$swapfile" 2>/dev/null || dd if=/dev/zero of="$swapfile" bs=1M count=2048 status=none
    chmod 600 "$swapfile"
    mkswap "$swapfile" >/dev/null
  fi

  swapon "$swapfile"
  if ! grep -q '^/swapfile ' /etc/fstab; then
    printf '%s\n' '/swapfile none swap sw 0 0' >> /etc/fstab
  fi
}

install_go_toolchain() {
  local go_version="${GO_VERSION:-1.24.0}"
  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "Unsupported architecture for Go install" >&2; exit 1 ;;
  esac

  local tmpdir
  tmpdir="$(mktemp -d)"
  curl -fsSL "https://go.dev/dl/go${go_version}.linux-${arch}.tar.gz" -o "$tmpdir/go.tgz"
  $sudo_cmd rm -rf /usr/local/go
  $sudo_cmd tar -C /usr/local -xzf "$tmpdir/go.tgz"
  export PATH="/usr/local/go/bin:$PATH"
}

install_go_tools() {
  export PATH="/usr/local/go/bin:$PATH"
  export HOME="${HOME:-$INSTALL_HOME}"
  export GOPATH="${GOPATH:-$HOME/go}"
  export PATH="$PATH:$GOPATH/bin"
  export GOMAXPROCS="${GOMAXPROCS:-1}"
  export GOFLAGS="${GOFLAGS:--p=1}"

  go install -p 1 github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
  go install -p 1 github.com/projectdiscovery/httpx/cmd/httpx@latest
  go install -p 1 github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest
  go install -p 1 github.com/projectdiscovery/notify/cmd/notify@latest
  go install -p 1 github.com/tomnomnom/anew@latest

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
      run_as_install_user git -C "$REPO_DIR" pull --ff-only
    fi
  else
    $sudo_cmd mkdir -p "$REPO_DIR"
    $sudo_cmd chown "$INSTALL_USER:$INSTALL_USER" "$REPO_DIR"
    if [[ "$INSTALL_USER" == "root" ]]; then
      git clone "$REPO_URL" "$REPO_DIR"
    else
      run_as_install_user git clone "$REPO_URL" "$REPO_DIR"
    fi
  fi
}

install_cron() {
  local scanner_env="RECON_USE_SUBFINDER=${RECON_USE_SUBFINDER:-false} RECON_USE_HTTPX=${RECON_USE_HTTPX:-false} RECON_USE_NUCLEI=${RECON_USE_NUCLEI:-false}"
  local sync_job="*/5 * * * * RECON_ROOT=$RUNTIME_DIR $scanner_env $REPO_DIR/scripts/sync_programs.sh >> $LOG_DIR/scheduler.log 2>&1"
  local run_job="* * * * * RECON_ROOT=$RUNTIME_DIR $scanner_env $REPO_DIR/scripts/run_jobs.sh >> $LOG_DIR/workers.log 2>&1"
  local update_job="0 */6 * * * RECON_ROOT=$RUNTIME_DIR $scanner_env $REPO_DIR/scripts/update_templates.sh >> $LOG_DIR/templates.log 2>&1"
  local path_line="PATH=/usr/local/bin:/usr/bin:/bin"

  local current
  if [[ "$INSTALL_USER" == "$(id -un)" ]]; then
    current="$(crontab -l 2>/dev/null || true)"
  else
    current="$(sudo -u "$INSTALL_USER" crontab -l 2>/dev/null || true)"
  fi

  local cleaned_current
  cleaned_current="$(printf '%s\n' "$current" | grep -v '/recon-repo/scripts/' | grep -v 'RECON_USE_' || true)"

  {
    printf '%s\n' "$path_line"
    printf '%s\n' "$cleaned_current"
    printf '%s\n' "$sync_job"
    printf '%s\n' "$run_job"
    printf '%s\n' "$update_job"
  } | awk 'NF && !seen[$0]++' | {
    if [[ "$INSTALL_USER" == "$(id -un)" ]]; then
      crontab -
    else
      sudo -u "$INSTALL_USER" crontab -
    fi
  }
}

main() {
  install_packages
  setup_swap
  install_go_toolchain
  install_go_tools
  setup_runtime
  setup_repo
  install_cron

  echo "EC2 setup complete."
  echo "Next: copy config examples into $CONFIG_DIR and set RECON_USE_SUBFINDER/HTTPX/NUCLEI=true if desired."
}

main "$@"
