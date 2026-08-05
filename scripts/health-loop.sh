#!/usr/bin/env bash
set -euo pipefail
INTERVAL="${HEALTH_INTERVAL:-60}"
SCRIPTS_DIR="${SCRIPTS_DIR:-/opt/warp-pool/scripts}"
while true; do
  bash "${SCRIPTS_DIR}/health-once.sh" || true
  sleep "$INTERVAL"
done
