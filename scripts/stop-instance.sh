#!/usr/bin/env bash
# stop-instance.sh <id> [drop-netns]
# Stops expose/gost/warp-svc/dbus for ONE instance only.
# NEVER pkill -x by name: netns does not isolate the PID table — that kills ALL peers.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

id="${1:?usage: stop-instance.sh <id> [drop-netns]}"
drop_ns="${2:-}"
run="$(instance_run_dir "$id")"
ns="$(ns_name "$id")"

_kill_pid() {
  local pid="$1" label="$2"
  [ -n "$pid" ] || return 0
  # only numeric pids
  case "$pid" in
    ''|*[!0-9]*) return 0 ;;
  esac
  if kill -0 "$pid" 2>/dev/null; then
    log "instance ${id}: stop ${label} pid=${pid}"
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  fi
}

_kill_pidfile() {
  local pf="$1" label="$2"
  if [ -f "$pf" ]; then
    local pid
    pid="$(cat "$pf" 2>/dev/null || true)"
    _kill_pid "$pid" "$label"
    rm -f "$pf"
  fi
}

# Kill processes whose /proc/PID/ns/net matches this netns (safe residual cleanup).
# Does NOT use pkill -x (would slaughter every warp-svc in the container).
_kill_in_netns_by_comm() {
  local comm="$1"
  local ns_path nino p pns pcomm
  ns_path="/var/run/netns/${ns}"
  [ -e "$ns_path" ] || ns_path="/run/netns/${ns}"
  [ -e "$ns_path" ] || return 0
  nino="$(stat -c %i "$ns_path" 2>/dev/null || true)"
  [ -n "$nino" ] || return 0

  # prefer ip netns pids if available
  if command -v ip >/dev/null 2>&1; then
    local pids
    pids="$(ip netns pids "$ns" 2>/dev/null || true)"
    for p in $pids; do
      pcomm="$(cat "/proc/$p/comm" 2>/dev/null || true)"
      if [ "$pcomm" = "$comm" ]; then
        _kill_pid "$p" "${comm}(ns)"
      fi
    done
    return 0
  fi

  # fallback: scan /proc for matching net ns inode + comm
  for p in /proc/[0-9]*; do
    p="${p#/proc/}"
    pns="$(stat -c %i "/proc/$p/ns/net" 2>/dev/null || true)"
    [ "$pns" = "$nino" ] || continue
    pcomm="$(cat "/proc/$p/comm" 2>/dev/null || true)"
    if [ "$pcomm" = "$comm" ]; then
      _kill_pid "$p" "${comm}(ns-scan)"
    fi
  done
}

_kill_pidfile "$(pidfile_expose "$id")" "expose"
_kill_pidfile "$(pidfile_gost "$id")" "gost"
_kill_pidfile "$(pidfile_svc "$id")" "warp-svc"
_kill_pidfile "$(pidfile_dbus "$id")" "dbus"

# residual in this netns only
_kill_in_netns_by_comm "warp-svc"
_kill_in_netns_by_comm "microsocks"
_kill_in_netns_by_comm "gost"

# socket holders for THIS runtime dir only (path is per-id)
if [ -e "${run}/warp_service" ] || [ -S "${run}/warp_service" ]; then
  fuser -k "${run}/warp_service" 2>/dev/null || true
  sleep 0.3
fi
rm -f "${run}/warp_service" 2>/dev/null || true
if [ -d "$run" ]; then
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
