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

mkdir -p /run "${PID_DIR}" "${DATA_DIR}/instances" "${DATA_DIR}/state" "${DATA_DIR}/logs"
# fix /run/netns for container restart (stale mount after docker restart)
umount -l /run/netns 2>/dev/null || true
rm -rf /run/netns/*
mkdir -p /run/netns
mount --make-shared /run/netns 2>/dev/null || true
# 启动兜底：清掉残留 netns(wp*) / veth(vwp*)，避免 RTNETLINK 复发
NETNS_PREFIX="${NETNS_PREFIX:-wp}"
if command -v ip >/dev/null 2>&1; then
  while read -r ns _; do
    case "$ns" in
      "${NETNS_PREFIX}"*) ip netns del "$ns" 2>/dev/null || true ;;
    esac
  done < <(ip netns list 2>/dev/null || true)
  # ip -o link: "N: name: <flags> ..."
  while read -r iface; do
    case "$iface" in
      "v${NETNS_PREFIX}"*) ip link del "$iface" 2>/dev/null || true ;;
    esac
  done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' || true)
fi
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
    probed=0
    for ((t = 0; t < BOOT_HEALTH_WAIT; t += 3)); do
      if probe_instance "$id" >/dev/null; then
        probed=1
        break
      fi
      sleep 3
    done
    if [ "$probed" = "1" ]; then
      if ip="$(ensure_instance_unique "$id")"; then
        log "instance ${id}: ready v4=${ip} unique=true"
        ready=1
      else
        err "instance ${id}: healthy probe but v4_collision (not ready)"
      fi
    fi
    if [ "$ready" = "1" ]; then
      started=$((started + 1))
    else
      err "instance ${id}: started but not healthy/unique within ${BOOT_HEALTH_WAIT}s"
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

# hot desired N from control API (POST /instances → state/desired_n.json)
_read_desired_n() {
  local f="${DATA_DIR}/state/desired_n.json" n=""
  if [ -f "$f" ]; then
    n="$(jq -r '.desired // .n // empty' "$f" 2>/dev/null || true)"
  fi
  if [ -n "$n" ] && [ "$n" -ge 1 ] 2>/dev/null; then
    echo "$n"
  else
    echo "${WARP_INSTANCES}"
  fi
}

# instance dirs under /data/instances/<id> are source of truth (DELETE removes dir)
_count_instance_dirs() {
  local n=0 d
  for d in "${DATA_DIR}/instances"/*; do
    [ -d "$d" ] || continue
    [[ "$(basename "$d")" =~ ^[0-9]+$ ]] || continue
    n=$((n + 1))
  done
  echo "$n"
}

_max_instance_id() {
  local max=-1 id
  for d in "${DATA_DIR}/instances"/*; do
    [ -d "$d" ] || continue
    id="$(basename "$d")"
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    if [ "$id" -gt "$max" ]; then max="$id"; fi
  done
  echo "$max"
}

_next_free_id() {
  local id=0
  while [ -d "${DATA_DIR}/instances/${id}" ]; do
    id=$((id + 1))
  done
  echo "$id"
}

log "supervising..."
while true; do
  desired="$(_read_desired_n)"
  cur="$(_count_instance_dirs)"

  # legacy remove-id (API now removes directly; keep for race/compat)
  if [ -f "${DATA_DIR}/state/remove-id" ]; then
    rid="$(tr -d ' \n\r' < "${DATA_DIR}/state/remove-id" || true)"
    rm -f "${DATA_DIR}/state/remove-id"
    if [ -n "$rid" ] && [ "$rid" -ge 0 ] 2>/dev/null; then
      log "hot-remove instance ${rid}"
      if [ -x "${SCRIPTS_DIR}/remove-instance.sh" ]; then
        bash "${SCRIPTS_DIR}/remove-instance.sh" "$rid" 2>/dev/null || true
      else
        SUPERVISE_RESTART=0 bash "${SCRIPTS_DIR}/stop-instance.sh" "$rid" drop-netns 2>/dev/null || true
        rm -rf "${DATA_DIR}/instances/${rid}"
      fi
      cur="$(_count_instance_dirs)"
      SUPERVISE_RESTART=0 bash "${SCRIPTS_DIR}/health-once.sh" || true
    fi
  fi

  # shrink: if more dirs than desired, remove highest ids
  if [ "$desired" -ge 1 ] 2>/dev/null && [ "$cur" -gt "$desired" ] 2>/dev/null; then
    while [ "$(_count_instance_dirs)" -gt "$desired" ]; do
      hid="$(_max_instance_id)"
      [ "$hid" -ge 0 ] 2>/dev/null || break
      log "hot-shrink remove instance ${hid} (desired=${desired})"
      if [ -x "${SCRIPTS_DIR}/remove-instance.sh" ]; then
        bash "${SCRIPTS_DIR}/remove-instance.sh" "$hid" 2>/dev/null || true
      else
        SUPERVISE_RESTART=0 bash "${SCRIPTS_DIR}/stop-instance.sh" "$hid" drop-netns 2>/dev/null || true
        rm -rf "${DATA_DIR}/instances/${hid}"
      fi
    done
    cur="$(_count_instance_dirs)"
  fi

  # hot-add until dir count == desired (reuse free ids)
  if [ "$desired" -ge 1 ] 2>/dev/null && [ "$cur" -lt "$desired" ] 2>/dev/null; then
    while [ "$(_count_instance_dirs)" -lt "$desired" ]; do
      id="$(_next_free_id)"
      log "hot-add instance ${id} (have=$(_count_instance_dirs) desired=${desired})"
      if bash "${SCRIPTS_DIR}/ensure-instance.sh" "$id" && bash "${SCRIPTS_DIR}/start-instance.sh" "$id"; then
        if ip="$(ensure_instance_unique "$id" 2>/dev/null)"; then
          log "hot-add ${id}: ready v4=${ip}"
        else
          err "hot-add ${id}: start ok but not unique/healthy yet"
        fi
      else
        err "hot-add ${id}: failed to start"
        break
      fi
    done
  fi

  cur="$(_count_instance_dirs)"
  maxid="$(_max_instance_id)"
  if [ "$maxid" -ge 0 ] 2>/dev/null; then
    WARP_INSTANCES=$((maxid + 1))
  else
    WARP_INSTANCES=0
  fi
  # health-once loops 0..N-1; keep N at least desired for empty holes skip
  if [ "$desired" -gt "$WARP_INSTANCES" ] 2>/dev/null; then
    WARP_INSTANCES="$desired"
  fi
  export WARP_INSTANCES

  # restart only ids that still have a data dir (deleted = no revive)
  alive=0
  for d in "${DATA_DIR}/instances"/*; do
    [ -d "$d" ] || continue
    id="$(basename "$d")"
    [[ "$id" =~ ^[0-9]+$ ]] || continue
    if [ -f "${PID_DIR}/rotate-${id}.lock" ]; then
      alive=$((alive + 1))
      continue
    fi
    pf="$(pidfile_svc "$id")"
    if [ -f "$pf" ]; then
      pid="$(cat "$pf" || true)"
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        alive=$((alive + 1))
        continue
      fi
    fi
    log "instance ${id}: dead, restarting"
    bash "${SCRIPTS_DIR}/start-instance.sh" "$id" || true
    if [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null || true)" 2>/dev/null; then
      alive=$((alive + 1))
    fi
  done

  if [ "$alive" -lt 1 ] && [ "$desired" -ge 1 ] 2>/dev/null; then
    err "all warp-svc processes dead (desired=${desired})"
    exit 1
  fi
  sleep 5
done
