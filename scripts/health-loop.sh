#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

INTERVAL="${HEALTH_INTERVAL:-60}"
log "health-loop interval=${INTERVAL}s"
# initial pass
bash "${SCRIPTS_DIR}/health-once.sh" || true
while true; do
  sleep "$INTERVAL"
  bash "${SCRIPTS_DIR}/health-once.sh" || true
done
