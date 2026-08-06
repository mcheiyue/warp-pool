#!/usr/bin/env bash
# warp-pool v0.3: Warp mode × netns × N + warppool aggregate/control/UI
set -euo pipefail

export DATA_DIR="${DATA_DIR:-/data}"
export SCRIPTS_DIR="${SCRIPTS_DIR:-/opt/warp-pool/scripts}"
export PID_DIR="${PID_DIR:-/run/warp-pool}"
export WARP_INSTANCES="${WARP_INSTANCES:-2}"
export INSTANCE_PORT_BASE="${INSTANCE_PORT_BASE:-40000}"
export EXPOSE_PORT_BASE="${EXPOSE_PORT_BASE:-11000}"
export ENABLE_EXPOSE="${ENABLE_EXPOSE:-1}"
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
export DEREGISTER_ON_SHUTDOWN="${DEREGISTER_ON_SHUTDOWN:-0}"
export ROTATE_MODE="${ROTATE_MODE:-restart}"
export BOOT_HEALTH_WAIT="${BOOT_HEALTH_WAIT:-120}"
export WARP_CONNECT_TIMEOUT="${WARP_CONNECT_TIMEOUT:-45}"
export WEB_ROOT="${WEB_ROOT:-/opt/warp-pool/web}"

# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/lib.sh"

if [ "$(id -u)" -ne 0 ]; then
  err "v0.3 requires root (netns/tun/iptables)"
  exit 1
fi

mkdir -p /run "${PID_DIR}" "${DATA_DIR}/instances" "${DATA_DIR}/state"
# fix /run/netns for container restart (stale mount after docker restart)
mkdir -p /run/netns
mount --make-shared /run/netns 2>/dev/null || true
ensure_host_forward

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
    bash "${SCRIPTS_DIR}/stop-instance.sh" "$id" drop-netns 2>/dev/null || true
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
        log "instance ${id}: ready v4=${ip}"
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
  bash "${SCRIPTS_DIR}/health-loop.sh" >/tmp/health-loop.log 2>&1 &
  PIDS+=($!)
  log "health-loop pid=$!"
fi

if [ "$ENABLE_AGGREGATE" = "1" ] && [ "$started" -ge 1 ]; then
  warppool aggregate --listen "0.0.0.0:${AGG_SOCKS_PORT}" --healthy "${DATA_DIR}/state/healthy.json" \
    >/tmp/aggregate.log 2>&1 &
  PIDS+=($!)
  log "aggregate pid=$! on :${AGG_SOCKS_PORT}"
fi

if [ "$ENABLE_CONTROL" = "1" ]; then
  warppool control \
    --listen "${CONTROL_BIND}:${CONTROL_PORT}" \
    --data "${DATA_DIR}" \
    --scripts "${SCRIPTS_DIR}" \
    --token "${CONTROL_TOKEN}" \
    --web "${WEB_ROOT}" \
    >/tmp/control.log 2>&1 &
  PIDS+=($!)
  log "control+ui pid=$! on ${CONTROL_BIND}:${CONTROL_PORT} web=${WEB_ROOT}"
fi

log "supervising..."
while true; do
  alive=0
  for ((id = 0; id < WARP_INSTANCES; id++)); do
    # skip while rotate lock held
    if [ -f "${PID_DIR}/rotate-${id}.lock" ]; then
      alive=$((alive + 1))
      continue
    fi
    pf="$(pidfile_svc "$id")"
    if [ -f "$pf" ]; then
      pid="$(cat "$pf" || true)"
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        alive=$((alive + 1))
      else
        log "instance ${id}: dead, restarting"
        bash "${SCRIPTS_DIR}/start-instance.sh" "$id" || true
        if [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null || true)" 2>/dev/null; then
          alive=$((alive + 1))
        fi
      fi
    fi
  done
  if [ "$alive" -lt 1 ]; then
    err "all warp-svc processes dead"
    exit 1
  fi
  sleep 5
done
