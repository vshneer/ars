#!/usr/bin/env bash

set -euo pipefail

TARGET_ROOT="${1:-/recon}"

mkdir -p "$TARGET_ROOT"
cp -R programs scripts config docs README.md "$TARGET_ROOT"/ 2>/dev/null || true
