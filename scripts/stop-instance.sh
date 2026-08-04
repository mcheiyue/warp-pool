#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ID="${1:?usage: stop-instance.sh <id>}"
PIDFILE="${PID_DIR}/wireproxy-${ID}.pid"
if [ -f "$PIDFILE" ]; then
  pid="$(cat "$PIDFILE" || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    log "instance ${ID}: stopping pid=$pid"
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$PIDFILE"
fi
