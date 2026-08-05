#!/usr/bin/env bash
# start-instance.sh <id> — dbus + warp-svc proxy mode on INSTANCE_PORT_BASE+id
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

id="${1:?usage: start-instance.sh <id>}"
port="$(instance_port "$id")"
state="$(instance_state_dir "$id")"
run="$(instance_run_dir "$id")"
dbus_dir="$(instance_dbus_dir "$id")"
dbus_sock="${dbus_dir}/system_bus_socket"
pf_svc="$(pidfile_svc "$id")"
pf_dbus="$(pidfile_dbus "$id")"

ensure_dirs "$id"

# already running?
if [ -f "$pf_svc" ]; then
  old="$(cat "$pf_svc" || true)"
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    log "instance ${id}: warp-svc already running pid=${old}"
    exit 0
  fi
fi

# per-instance dbus
if [ -S "$dbus_sock" ]; then
  log "instance ${id}: dbus socket exists, reuse if possible"
else
  sudo rm -f "${dbus_dir}/pid" 2>/dev/null || true
  sudo dbus-daemon \
    --address="unix:path=${dbus_sock}" \
    --config-file=/usr/share/dbus-1/system.conf \
    --nopidfile --nofork >/dev/null 2>&1 &
  echo $! | sudo tee "$pf_dbus" >/dev/null
  # dbus may be root; record host-visible pid from $!
  echo $! > "$pf_dbus" 2>/dev/null || true
  sleep 1
fi

log "instance ${id}: starting warp-svc (proxy port ${port})"
sudo env \
  STATE_DIRECTORY="$state" \
  RUNTIME_DIRECTORY="$run" \
  DBUS_SYSTEM_BUS_ADDRESS="unix:path=${dbus_sock}" \
  warp-svc --accept-tos &
svc_pid=$!
echo "$svc_pid" > "$pf_svc"

if ! wait_daemon_ready "$id" "$WARP_CONNECT_TIMEOUT"; then
  err "instance ${id}: daemon not ready within ${WARP_CONNECT_TIMEOUT}s"
  # continue anyway — register may still work
fi

# register if needed
if [ ! -f "${state}/reg.json" ]; then
  log "instance ${id}: registration new"
  reg_ok=0
  for attempt in 1 2 3 4 5; do
    if wcli "$id" registration new 2>/dev/null; then
      reg_ok=1
      break
    fi
    backoff=$((attempt * 3 + RANDOM % 3))
    log "instance ${id}: register attempt ${attempt} failed, sleep ${backoff}s"
    sleep "$backoff"
  done
  if [ "$reg_ok" -ne 1 ]; then
    err "instance ${id}: registration failed"
    exit 1
  fi
  if [ -n "${WARP_LICENSE_KEY:-${LICENSE_KEY:-}}" ]; then
    key="${WARP_LICENSE_KEY:-$LICENSE_KEY}"
    wcli "$id" registration license "$key" 2>/dev/null || log "instance ${id}: license apply failed (continue free)"
  fi
fi

  wcli "$id" mode proxy
wcli "$id" proxy port "$port"
wcli "$id" connect
wcli "$id" debug qlog disable 2>/dev/null || true

# CF proxy is 127.0.0.1-only; relay to 0.0.0.0 for Docker port-publish / host direct
if [ "${ENABLE_EXPOSE:-1}" = "1" ]; then
  exp="$(expose_port "$id")"
  pf_exp="$(pidfile_expose "$id")"
  if [ -f "$pf_exp" ]; then
    old_exp="$(cat "$pf_exp" || true)"
    if [ -n "$old_exp" ] && kill -0 "$old_exp" 2>/dev/null; then
      kill "$old_exp" 2>/dev/null || true
      sleep 1
    fi
    rm -f "$pf_exp"
  fi
  log "instance ${id}: expose 0.0.0.0:${exp} -> 127.0.0.1:${port}"
  warppool expose --listen "0.0.0.0:${exp}" --backend "127.0.0.1:${port}" &
  echo $! > "$pf_exp"
fi

log "instance ${id}: proxy on 127.0.0.1:${port} expose=$(expose_port "$id") pid=$(cat "$pf_svc")"
