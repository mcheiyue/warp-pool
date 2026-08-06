#!/usr/bin/env bash
# stop-instance.sh <id> [keep-netns]
# Stops expose/gost/warp-svc/dbus. Keeps netns+STATE by default (for rotate restart).
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

id="${1:?usage: stop-instance.sh <id> [drop-netns]}"
drop_ns="${2:-}"

_kill_pidfile() {
  local pf="$1" label="$2"
  if [ -f "$pf" ]; then
    local pid
    pid="$(cat "$pf" || true)"
    if [ -n "$pid" ]; then
      log "instance ${id}: stop ${label} pid=${pid}"
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
    fi
    rm -f "$pf"
  fi
}

_kill_pidfile "$(pidfile_expose "$id")" "expose"
_kill_pidfile "$(pidfile_gost "$id")" "gost"
_kill_pidfile "$(pidfile_svc "$id")" "warp-svc"
_kill_pidfile "$(pidfile_dbus "$id")" "dbus"

rm -f "$(instance_dbus_dir "$id")/system_bus_socket" 2>/dev/null || true

if [ "$drop_ns" = "drop-netns" ]; then
  name="$(ns_name "$id")"
  veth="$(veth_host "$id")"
  ip link del "$veth" 2>/dev/null || true
  ip netns del "$name" 2>/dev/null || true
  log "instance ${id}: netns dropped"
fi

log "instance ${id}: stopped"
