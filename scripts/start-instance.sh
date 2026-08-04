#!/usr/bin/env bash
# Start wireproxy for instance id; write pid file
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ID="${1:?usage: start-instance.sh <id>}"
ensure_dirs "$ID"
DIR="$(instance_dir "$ID")"
CONF="${DIR}/wireproxy.conf"
PIDFILE="${PID_DIR}/wireproxy-${ID}.pid"

if [ ! -f "$CONF" ]; then
  err "instance ${ID}: missing $CONF — run ensure-instance.sh first"
  exit 1
fi

if [ -f "$PIDFILE" ]; then
  old="$(cat "$PIDFILE" || true)"
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    log "instance ${ID}: wireproxy already running pid=$old"
    exit 0
  fi
  rm -f "$PIDFILE"
fi

log "instance ${ID}: starting wireproxy on port $(instance_port "$ID")"
wireproxy -c "$CONF" &
echo $! > "$PIDFILE"
sleep 1
if ! kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  err "instance ${ID}: wireproxy exited immediately"
  rm -f "$PIDFILE"
  exit 1
fi
