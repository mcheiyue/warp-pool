#!/usr/bin/env bash
# stop-instance.sh <id> [keep-netns]
# Stops expose/gost/warp-svc/dbus. Keeps netns+STATE by default (for rotate restart).
# Always clears RUNTIME_DIRECTORY unix sockets so next warp-svc can bind.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

id="${1:?usage: stop-instance.sh <id> [drop-netns]}"
drop_ns="${2:-}"
run="$(instance_run_dir "$id")"
ns="$(ns_name "$id")"

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

# netns 内可能残留未写进 pidfile 的 warp-svc（抢 /run/warp-N/warp_service）
if ip netns list 2>/dev/null | grep -qE "^${ns}[[:space:]]" || \
   [ -e "/var/run/netns/${ns}" ] || [ -e "/run/netns/${ns}" ]; then
  ns_exec "$id" bash -c '
    pkill -x warp-svc 2>/dev/null || true
    pkill -x microsocks 2>/dev/null || true
    sleep 0.5
    pkill -9 -x warp-svc 2>/dev/null || true
    pkill -9 -x microsocks 2>/dev/null || true
  ' 2>/dev/null || true
fi

# 关键：清 runtime unix socket，否则下次 start 报 Unix socket already bound
rm -f "${run}/warp_service" 2>/dev/null || true
if [ -d "$run" ]; then
  # 只删 socket 节点，不动目录本身
  find "$run" -maxdepth 1 -type s -delete 2>/dev/null || true
fi
rm -f "$(instance_dbus_dir "$id")/system_bus_socket" 2>/dev/null || true

if [ "$drop_ns" = "drop-netns" ]; then
  veth="$(veth_host "$id")"
  ip link del "$veth" 2>/dev/null || true
  ip netns del "$ns" 2>/dev/null || true
  log "instance ${id}: netns dropped"
fi

log "instance ${id}: stopped"
