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
    software-properties-common \
    python3 \
    python3-pip \
    unzip

  systemctl enable --now amazon-ssm-agent 2>/dev/null || true
}

install_python311() {
  if command -v python3.11 >/dev/null 2>&1; then
    return 0
  fi

  $sudo_cmd add-apt-repository -y ppa:deadsnakes/ppa >/dev/null 2>&1 || true
  $sudo_cmd apt-get update
  $sudo_cmd apt-get install -y python3.11 python3.11-venv python3.11-dev python3.11-distutils
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
  export HOME="$INSTALL_HOME"
  export GOPATH="${GOPATH:-$HOME/go}"
  export PATH="$PATH:$GOPATH/bin"
  export GOMAXPROCS="${GOMAXPROCS:-1}"
  export GOFLAGS="${GOFLAGS:--p=1}"

  go install -p 1 github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
  go install -p 1 github.com/projectdiscovery/httpx/cmd/httpx@latest
  go install -p 1 github.com/tomnomnom/anew@latest

  $sudo_cmd mkdir -p /usr/local/bin
  for bin in subfinder httpx anew; do
    if [[ -x "$GOPATH/bin/$bin" ]]; then
      $sudo_cmd ln -sf "$GOPATH/bin/$bin" "/usr/local/bin/$bin"
    fi
  done
}

ensure_tool() {
  local name="$1"
  local package="$2"

  if command -v "$name" >/dev/null 2>&1; then
    return 0
  fi

  export PATH="/usr/local/go/bin:$PATH"
  export HOME="$INSTALL_HOME"
  export GOPATH="${GOPATH:-$HOME/go}"
  export PATH="$PATH:$GOPATH/bin"
  go install -p 1 "$package@latest"
  $sudo_cmd ln -sf "$GOPATH/bin/$name" "/usr/local/bin/$name"

  if ! command -v "$name" >/dev/null 2>&1; then
    echo "Failed to install required tool: $name" >&2
    exit 1
  fi
}

verify_scanner_tooling() {
  ensure_tool subfinder github.com/projectdiscovery/subfinder/v2/cmd/subfinder
  ensure_tool httpx github.com/projectdiscovery/httpx/cmd/httpx
  ensure_tool anew github.com/tomnomnom/anew
}

install_dirsearch_tool() {
  install_python311

  if command -v dirsearch >/dev/null 2>&1; then
    return 0
  fi

  if ! command -v python3.11 >/dev/null 2>&1; then
    echo "python3.11 missing; dirsearch installation failed" >&2
    exit 1
  fi

  export HOME="$INSTALL_HOME"
  python3.11 -m ensurepip --upgrade >/dev/null 2>&1 || true
  python3.11 -m pip install --user --upgrade pip >/dev/null 2>&1 || true
  python3.11 -m pip install --user git+https://github.com/maurosoria/dirsearch.git >/dev/null 2>&1 || {
    echo "dirsearch install failed" >&2
    exit 1
  }

  if [[ -x "$INSTALL_HOME/.local/bin/dirsearch" ]]; then
    $sudo_cmd ln -sf "$INSTALL_HOME/.local/bin/dirsearch" /usr/local/bin/dirsearch
  fi

  if ! command -v dirsearch >/dev/null 2>&1; then
    echo "Failed to install required tool: dirsearch" >&2
    exit 1
  fi
}

setup_runtime() {
  $sudo_cmd mkdir -p "$PROGRAMS_DIR" "$TARGETS_DIR" "$JOBS_DIR" "$CONFIG_DIR" "$LOG_DIR"
  if [[ ! -f "$CONFIG_DIR/subfinder.yaml" ]]; then
    $sudo_cmd touch "$CONFIG_DIR/subfinder.yaml"
  fi
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

link_runtime_programs() {
  if [[ -d "$REPO_DIR/programs" ]]; then
    rm -rf "$PROGRAMS_DIR"
    ln -s "$REPO_DIR/programs" "$PROGRAMS_DIR"
  fi
}

install_cron() {
  local scanner_env="RECON_USE_SUBFINDER=${RECON_USE_SUBFINDER:-true} RECON_USE_HTTPX=${RECON_USE_HTTPX:-true} RECON_USE_DIRSEARCH=${RECON_USE_DIRSEARCH:-true} FINDINGS_S3_BUCKET=${FINDINGS_S3_BUCKET:-} FINDINGS_S3_PREFIX=${FINDINGS_S3_PREFIX:-recon} DIRSEARCH_MAX_RATE=${DIRSEARCH_MAX_RATE:-1} DIRSEARCH_THREADS=${DIRSEARCH_THREADS:-5} DIRSEARCH_DELAY=${DIRSEARCH_DELAY:-0.2}"
  local sync_job="0 3 * * 0 RECON_ROOT=$RUNTIME_DIR $scanner_env $REPO_DIR/scripts/sync_programs.sh >> $LOG_DIR/scheduler.log 2>&1"
  local run_job="15 3 * * 0 RECON_ROOT=$RUNTIME_DIR $scanner_env $REPO_DIR/scripts/run_jobs.sh >> $LOG_DIR/workers.log 2>&1"
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
  verify_scanner_tooling
  install_dirsearch_tool
  setup_runtime
  setup_repo
  link_runtime_programs
  install_cron

  echo "EC2 setup complete."
  echo "Next: copy config examples into $CONFIG_DIR and set RECON_USE_SUBFINDER/HTTPX/DIRSEARCH plus FINDINGS_S3_BUCKET if desired."
}

main "$@"
