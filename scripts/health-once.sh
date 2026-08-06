#!/usr/bin/env bash
# One health pass: probe all instances via in-ns SOCKS, update meta + healthy.json
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

N="${WARP_INSTANCES:-2}"
FAILURES_THR="${HEALTH_FAILURES:-3}"
AUTO_ROTATE="${HEALTH_AUTO_ROTATE:-0}"

mkdir -p "${DATA_DIR}/state" "${PID_DIR}"
backends_json="[]"

for ((id = 0; id < N; id++)); do
  dir="$(instance_dir "$id")"
  [ -d "$dir" ] || continue
  meta="${dir}/meta.json"
  pidfile="$(pidfile_svc "$id")"
  failures=0
  last_rotate=""
  if [ -f "$meta" ]; then
    failures="$(jq -r '.failures // 0' "$meta" 2>/dev/null || echo 0)"
    last_rotate="$(jq -r '.last_rotate // empty' "$meta" 2>/dev/null || true)"
  fi

  alive=0
  if [ -f "$pidfile" ]; then
    pid="$(cat "$pidfile" || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      alive=1
    fi
  fi

  if [ -f "${PID_DIR}/rotate-${id}.lock" ]; then
    log "instance ${id}: rotate in progress — skip"
    continue
  fi

  if [ "$alive" -eq 0 ]; then
    log "instance ${id}: process dead — marking unhealthy"
    write_meta "$id" false "" "$((failures + 1))" "$last_rotate" ""
    if [ "${SUPERVISE_RESTART:-1}" = "1" ]; then
      bash "${SCRIPTS_DIR}/start-instance.sh" "$id" || true
    fi
    continue
  fi

  if ip="$(probe_instance "$id")"; then
    write_meta "$id" true "$ip" 0 "$last_rotate" "$(cat "$pidfile")"
    backends_json="$(echo "$backends_json" | jq -c \
      --argjson id "$id" \
      --arg addr "$(socks_addr "$id")" \
      '. + [{id:$id, addr:$addr}]')"
    log "instance ${id}: healthy v4=${ip} socks=$(socks_addr "$id")"
  else
    failures=$((failures + 1))
    write_meta "$id" false "" "$failures" "$last_rotate" "$(cat "$pidfile")"
    log "instance ${id}: probe fail failures=${failures}"
    if [ "$AUTO_ROTATE" = "1" ] && [ "$failures" -ge "$FAILURES_THR" ]; then
      log "instance ${id}: auto rotate (${ROTATE_MODE:-restart})"
      bash "${SCRIPTS_DIR}/rotate-instance.sh" "$id" "${ROTATE_MODE:-restart}" || true
    fi
  fi
done

echo "{\"backends\": ${backends_json}}" | jq -c . > "${DATA_DIR}/state/healthy.json"
log "healthy.json updated: $(cat "${DATA_DIR}/state/healthy.json")"
