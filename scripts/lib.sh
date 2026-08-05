#!/usr/bin/env bash
# shared helpers for warp-pool v0.2 (official warp-svc proxy)
set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
INSTANCE_PORT_BASE="${INSTANCE_PORT_BASE:-40000}"
SCRIPTS_DIR="${SCRIPTS_DIR:-/opt/warp-pool/scripts}"
PID_DIR="${PID_DIR:-/run/warp-pool}"
WARP_CONNECT_TIMEOUT="${WARP_CONNECT_TIMEOUT:-45}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-10}"

log() { echo "==> [warp-pool] $*"; }
err() { echo "==> [warp-pool][ERROR] $*" >&2; }

instance_dir() {
  echo "${DATA_DIR}/instances/$1"
}

instance_state_dir() {
  echo "$(instance_dir "$1")/state"
}

instance_run_dir() {
  echo "/run/warp-$1"
}

instance_dbus_dir() {
  echo "/run/dbus-$1"
}

instance_dbus_addr() {
  echo "unix:path=$(instance_dbus_dir "$1")/system_bus_socket"
}

instance_port() {
  local id="$1"
  echo $((INSTANCE_PORT_BASE + id))
}

pidfile_svc() {
  echo "${PID_DIR}/warp-svc-${1}.pid"
}

pidfile_dbus() {
  echo "${PID_DIR}/dbus-${1}.pid"
}

ensure_dirs() {
  local id="$1"
  mkdir -p "$(instance_dir "$id")" "$(instance_state_dir "$id")" "${DATA_DIR}/state" "${PID_DIR}"
  sudo mkdir -p "$(instance_run_dir "$id")" "$(instance_dbus_dir "$id")"
}

# Run warp-cli against instance id's isolated runtime/dbus
wcli() {
  local id="$1"
  shift
  sudo env \
    STATE_DIRECTORY="$(instance_state_dir "$id")" \
    RUNTIME_DIRECTORY="$(instance_run_dir "$id")" \
    DBUS_SYSTEM_BUS_ADDRESS="$(instance_dbus_addr "$id")" \
    warp-cli --accept-tos "$@"
}

write_meta() {
  local id="$1"
  local healthy="${2:-false}"
  local ip="${3:-}"
  local failures="${4:-0}"
  local last_rotate="${5:-}"
  local pid="${6:-}"
  local dir meta
  dir="$(instance_dir "$id")"
  mkdir -p "$dir"
  meta="${dir}/meta.json"
  # last_rotate: empty string clears; omit pass-through from caller
  jq -n \
    --argjson id "$id" \
    --argjson healthy "$healthy" \
    --arg ip "$ip" \
    --argjson failures "$failures" \
    --arg last_rotate "$last_rotate" \
    --arg pid "$pid" \
    --argjson port "$(instance_port "$id")" \
    '{id:$id, healthy:$healthy, ip:$ip, failures:$failures, last_rotate:$last_rotate, pid:$pid, port:$port, updated:(now|todate)}' \
    > "${meta}.tmp"
  mv "${meta}.tmp" "$meta"
}

# Probe SOCKS on instance proxy port; print ip= on success
probe_instance() {
  local id="$1"
  local port out ip warp
  port="$(instance_port "$id")"
  out="$(curl -sS --max-time "${HEALTH_TIMEOUT}" \
    --socks5-hostname "127.0.0.1:${port}" \
    "https://cloudflare.com/cdn-cgi/trace" 2>/dev/null || true)"
  warp="$(echo "$out" | awk -F= '/^warp=/{print $2}')"
  ip="$(echo "$out" | awk -F= '/^ip=/{print $2}')"
  if echo "${warp:-}" | grep -qE '^(on|plus)$'; then
    echo "${ip:-unknown}"
    return 0
  fi
  return 1
}

wait_daemon_ready() {
  local id="$1"
  local timeout="${2:-$WARP_CONNECT_TIMEOUT}"
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    if wcli "$id" status 2>/dev/null | grep -qE '(Status|Connected|Connecting)'; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}
