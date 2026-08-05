#!/usr/bin/env bash
# stop-instance.sh <id>
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

id="${1:?usage: stop-instance.sh <id>}"
pf_svc="$(pidfile_svc "$id")"
pf_dbus="$(pidfile_dbus "$id")"

if [ -f "$pf_svc" ]; then
  pid="$(cat "$pf_svc" || true)"
  if [ -n "$pid" ]; then
    log "instance ${id}: stop warp-svc pid=${pid}"
    sudo kill "$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    sudo kill -9 "$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
  fi
  rm -f "$pf_svc"
fi

if [ -f "$pf_dbus" ]; then
  dpid="$(cat "$pf_dbus" || true)"
  if [ -n "$dpid" ]; then
    sudo kill "$dpid" 2>/dev/null || kill "$dpid" 2>/dev/null || true
  fi
  rm -f "$pf_dbus"
fi

# best-effort cleanup sockets
sudo rm -f "$(instance_dbus_dir "$id")/system_bus_socket" 2>/dev/null || true
log "instance ${id}: stopped"
