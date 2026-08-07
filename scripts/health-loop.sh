#!/usr/bin/env bash
# health-loop + optional scheduled rotate (ROTATE_SCHEDULE_SEC>0)
set -euo pipefail
INTERVAL="${HEALTH_INTERVAL:-60}"
SCRIPTS_DIR="${SCRIPTS_DIR:-/opt/warp-pool/scripts}"
# 0=off; e.g. 3600 = rotate all instances hourly (serial, respects cooldown if set)
ROTATE_SCHEDULE_SEC="${ROTATE_SCHEDULE_SEC:-0}"
DATA_DIR="${DATA_DIR:-/data}"
last_sched=0

while true; do
  bash "${SCRIPTS_DIR}/health-once.sh" || true
  if [ "${ROTATE_SCHEDULE_SEC}" -gt 0 ] 2>/dev/null; then
    now="$(date -u +%s)"
    if [ $((now - last_sched)) -ge "${ROTATE_SCHEDULE_SEC}" ]; then
      echo "==> [warp-pool] schedule rotate all (every ${ROTATE_SCHEDULE_SEC}s)"
      bash "${SCRIPTS_DIR}/rotate-instance.sh" all "${ROTATE_MODE:-restart}" || true
      last_sched="$now"
      mkdir -p "${DATA_DIR}/state"
      echo "{\"last_schedule\":$(date -u +%Y-%m-%dT%H:%M:%SZ | jq -R .),\"interval\":${ROTATE_SCHEDULE_SEC}}" \
        > "${DATA_DIR}/state/schedule.json" 2>/dev/null || true
    fi
  fi
  sleep "$INTERVAL"
done
