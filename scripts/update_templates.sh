#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

if command -v nuclei >/dev/null 2>&1; then
  log INFO system "Updating nuclei templates"
  nuclei -update-templates
else
  log WARN system "nuclei not installed; skipping template update"
fi
