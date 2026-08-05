#!/usr/bin/env bash
set -euo pipefail

export DATA_DIR="${DATA_DIR:-/data}"
export SCRIPTS_DIR="${SCRIPTS_DIR:-/opt/warp-pool/scripts}"
export PID_DIR="${PID_DIR:-/run/warp-pool}"
export WARP_INSTANCES="${WARP_INSTANCES:-2}"
export INSTANCE_PORT_BASE="${INSTANCE_PORT_BASE:-40000}"
export AGG_SOCKS_PORT="${AGG_SOCKS_PORT:-1080}"
export CONTROL_PORT="${CONTROL_PORT:-9090}"
export CONTROL_BIND="${CONTROL_BIND:-127.0.0.1}"
export CONTROL_TOKEN="${CONTROL_TOKEN:-}"
export REGISTER_STAGGER="${REGISTER_STAGGER:-5}"
export REGISTER_JITTER_MAX="${REGISTER_JITTER_MAX:-8}"
export PARTIAL_REGISTER_POLICY="${PARTIAL_REGISTER_POLICY:-degraded}"
export ENABLE_AGGREGATE="${ENABLE_AGGREGATE:-1}"
export ENABLE_CONTROL="${ENABLE_CONTROL:-1}"
export ENABLE_HEALTH="${ENABLE_HEALTH:-1}"
export HEALTH_AUTO_ROTATE="${HEALTH_AUTO_ROTATE:-0}"
export DEREGISTER_ON_SHUTDOWN="${DEREGISTER_ON_SHUTDOWN:-1}"
export ROTATE_MODE="${ROTATE_MODE:-reconnect}"
export BOOT_HEALTH_WAIT="${BOOT_HEALTH_WAIT:-90}"
export WARP_CONNECT_TIMEOUT="${WARP_CONNECT_TIMEOUT:-45}"

# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/lib.sh"

sudo mkdir -p /run "${PID_DIR}" /run/warp-pool
sudo mkdir -p "${DATA_DIR}/instances" "${DATA_DIR}/state"
sudo chown -R warp:warp "${DATA_DIR}" "${PID_DIR}" 2>/dev/null || true
mkdir -p "${DATA_DIR}/instances" "${DATA_DIR}/state" "${PID_DIR}"

if [ "$ENABLE_CONTROL" = "1" ]; then
  case "$CONTROL_BIND" in
    127.0.0.1|localhost|::1|"") ;;
    *)
      if [ -z "$CONTROL_TOKEN" ]; then
        err "CONTROL_BIND=${CONTROL_BIND} is non-loopback but CONTROL_TOKEN is empty"
        exit 1
      fi
      ;;
  esac
fi

PIDS=()

cleanup() {
  log "shutting down..."
  if [ "$DEREGISTER_ON_SHUTDOWN" = "1" ]; then
    for ((id = 0; id < WARP_INSTANCES; id++)); do
      wcli "$id" registration delete 2>/dev/null || true
    done
  fi
  for pid in "${PIDS[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
  for ((id = 0; id < WARP_INSTANCES; id++)); do
    bash "${SCRIPTS_DIR}/stop-instance.sh" "$id" 2>/dev/null || true
  done
  for pid in "${PIDS[@]:-}"; do
    wait "$pid" 2>/dev/null || true
  done
  log "bye"
}
trap cleanup EXIT INT TERM

started=0
for ((id = 0; id < WARP_INSTANCES; id++)); do
  if [ "$id" -gt 0 ]; then
    jitter=0
    if [ "${REGISTER_JITTER_MAX}" -gt 0 ] 2>/dev/null; then
      jitter=$((RANDOM % (REGISTER_JITTER_MAX + 1)))
    fi
    delay=$((REGISTER_STAGGER + jitter))
    log "instance ${id}: stagger sleep ${delay}s"
    sleep "$delay"
  fi

  if bash "${SCRIPTS_DIR}/ensure-instance.sh" "$id" && bash "${SCRIPTS_DIR}/start-instance.sh" "$id"; then
    ready=0
    for ((t = 0; t < BOOT_HEALTH_WAIT; t += 3)); do
      if ip="$(probe_instance "$id")"; then
        write_meta "$id" true "$ip" 0 "" "$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)"
        meta="$(instance_dir "$id")/meta.json"
        if [ -f "$meta" ]; then
          jq 'del(.last_rotate) | . + {last_rotate:""}' "$meta" > "${meta}.tmp" && mv "${meta}.tmp" "$meta"
        fi
        log "instance ${id}: ready ip=${ip}"
        ready=1
        break
      fi
      sleep 3
    done
    if [ "$ready" = "1" ]; then
      started=$((started + 1))
    else
      err "instance ${id}: started but not healthy within ${BOOT_HEALTH_WAIT}s"
      if [ "$PARTIAL_REGISTER_POLICY" = "fail" ]; then
        exit 1
      fi
    fi
  else
    err "instance ${id}: failed to start"
    if [ "$PARTIAL_REGISTER_POLICY" = "fail" ]; then
      exit 1
    fi
  fi
done

if [ "$started" -lt 1 ]; then
  err "no instances started"
  exit 1
fi

log "started ${started}/${WARP_INSTANCES} instances"

bash "${SCRIPTS_DIR}/health-once.sh" || true

if [ "$ENABLE_HEALTH" = "1" ]; then
  bash "${SCRIPTS_DIR}/health-loop.sh" &
  PIDS+=($!)
  log "health-loop pid=$!"
fi

if [ "$ENABLE_AGGREGATE" = "1" ] && [ "$started" -ge 1 ]; then
  warppool aggregate --listen "0.0.0.0:${AGG_SOCKS_PORT}" --healthy "${DATA_DIR}/state/healthy.json" &
  PIDS+=($!)
  log "aggregate pid=$! on :${AGG_SOCKS_PORT}"
fi

if [ "$ENABLE_CONTROL" = "1" ]; then
  warppool control --listen "${CONTROL_BIND}:${CONTROL_PORT}" --data "${DATA_DIR}" --scripts "${SCRIPTS_DIR}" --token "${CONTROL_TOKEN}" &
  PIDS+=($!)
  log "control pid=$! on ${CONTROL_BIND}:${CONTROL_PORT}"
fi

log "supervising..."
while true; do
  alive=0
  for ((id = 0; id < WARP_INSTANCES; id++)); do
    pf="$(pidfile_svc "$id")"
    if [ -f "$pf" ]; then
      pid="$(cat "$pf" || true)"
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        alive=$((alive + 1))
      else
        log "instance ${id}: dead, restarting"
        bash "${SCRIPTS_DIR}/start-instance.sh" "$id" || true
        if [ -f "$pf" ] && kill -0 "$(cat "$pf")" 2>/dev/null; then
          alive=$((alive + 1))
        fi
      fi
    fi
  done

  if [ "$alive" -lt 1 ]; then
    err "all warp-svc processes dead"
    exit 1
  fi

  if [ "$WARP_INSTANCES" = "1" ] && [ "$alive" -lt 1 ]; then
    exit 1
  fi

  sleep 5
done
