#!/usr/bin/env bash
# One health pass: probe all instances, update meta + healthy.json
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

N="${WARP_INSTANCES:-2}"
FAILURES_THR="${HEALTH_FAILURES:-3}"
RECOVERIES_THR="${HEALTH_RECOVERIES:-2}"
AUTO_ROTATE="${HEALTH_AUTO_ROTATE:-0}"

mkdir -p "${DATA_DIR}/state" "${PID_DIR}"
backends_json="[]"

for ((id = 0; id < N; id++)); do
  dir="$(instance_dir "$id")"
  [ -d "$dir" ] || continue
  meta="${dir}/meta.json"
  port="$(instance_port "$id")"
  pidfile="${PID_DIR}/wireproxy-${id}.pid"
  failures=0
  recoveries=0
  last_rotate=""
  if [ -f "$meta" ]; then
    failures="$(jq -r '.failures // 0' "$meta" 2>/dev/null || echo 0)"
    recoveries="$(jq -r '.recoveries // 0' "$meta" 2>/dev/null || echo 0)"
    last_rotate="$(jq -r '.last_rotate // empty' "$meta" 2>/dev/null || true)"
  fi

  alive=0
  if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile" || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      alive=1
    fi
  fi

  if [ "$alive" -eq 0 ]; then
    log "instance ${id}: process dead — marking unhealthy"
    write_meta "$id" false "" "$((failures + 1))" "$last_rotate" ""
    # try restart if conf exists (Phase 2+ supervise)
    if [ -f "${dir}/wireproxy.conf" ] && [ "${SUPERVISE_RESTART:-1}" = "1" ]; then
      bash "${SCRIPTS_DIR}/start-instance.sh" "$id" || true
    fi
    continue
  fi

  if ip="$(probe_instance "$id")"; then
    recoveries=$((recoveries + 1))
    failures=0
    healthy=false
    if [ "$recoveries" -ge "$RECOVERIES_THR" ] || [ "$recoveries" -ge 1 ]; then
      # first success is enough to join after start; recoveries thr for re-join after fail
      healthy=true
    fi
    # simplify: probe ok => healthy
    healthy=true
    write_meta "$id" true "$ip" 0 "$last_rotate" "$(cat "$pidfile")"
    # jq add backend
    backends_json="$(echo "$backends_json" | jq -c --argjson id "$id" --arg addr "127.0.0.1:${port}" '. + [{id:$id, addr:$addr}]')"
    log "instance ${id}: healthy ip=${ip}"
  else
    failures=$((failures + 1))
    recoveries=0
    write_meta "$id" false "" "$failures" "$last_rotate" "$(cat "$pidfile")"
    log "instance ${id}: probe fail failures=${failures}"
    if [ "$AUTO_ROTATE" = "1" ] && [ "$failures" -ge "$FAILURES_THR" ]; then
      log "instance ${id}: auto soft rotate"
      bash "${SCRIPTS_DIR}/rotate-instance.sh" "$id" soft || true
    fi
  fi
done

echo "{\"backends\": ${backends_json}}" | jq -c . > "${DATA_DIR}/state/healthy.json"
log "healthy.json updated: $(cat "${DATA_DIR}/state/healthy.json")"
