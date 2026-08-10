#!/usr/bin/env bash
# One health pass: probe all instances via in-ns SOCKS, update meta + healthy.json
# Only unique+healthy instances enter backends (V4_UNIQUE=1)
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

FAILURES_THR="${HEALTH_FAILURES:-3}"
AUTO_ROTATE="${HEALTH_AUTO_ROTATE:-0}"

mkdir -p "${DATA_DIR}/state" "${PID_DIR}"
backends_json="[]"

# Do NOT trust boot-time WARP_INSTANCES alone — health-loop keeps a stale copy
# after POST /instances hot-add. Discover ids from /data/instances.
while read -r id; do
  [ -n "$id" ] || continue
  dir="$(instance_dir "$id")"
  [ -d "$dir" ] || continue
  meta="${dir}/meta.json"
  pidfile="$(pidfile_svc "$id")"
  failures=0
  last_rotate=""
  prev_v4=""
  if [ -f "$meta" ]; then
    failures="$(jq -r '.failures // 0' "$meta" 2>/dev/null || echo 0)"
    last_rotate="$(jq -r '.last_rotate // empty' "$meta" 2>/dev/null || true)"
    prev_v4="$(jq -r '.v4 // .ip // empty' "$meta" 2>/dev/null || true)"
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
    # 出池休眠：不拉起；入池才监督重启
    if ! is_pool_eligible "$id"; then
      log "instance ${id}: process dead + not pooled — leave parked"
      # 不改 pooled/exclude，仅标 unhealthy + 清空运行态
      write_meta "$id" false "" "$failures" "$last_rotate" "" "" false
      continue
    fi
    log "instance ${id}: process dead — marking unhealthy"
    write_meta "$id" false "" "$((failures + 1))" "$last_rotate" "" "" false
    if [ "${SUPERVISE_RESTART:-1}" = "1" ]; then
      bash "${SCRIPTS_DIR}/start-instance.sh" "$id" || true
    fi
    continue
  fi

  if ip="$(probe_instance "$id")"; then
    if acquire_unique_lock 10; then
      if v4_conflicts "$id" "$ip"; then
        release_unique_lock
        failures=$((failures + 1))
        write_meta "$id" false "$ip" "$failures" "$last_rotate" "$(cat "$pidfile")" "" false
        log "instance ${id}: v4 collision ${ip} — failures=${failures}"
        if [ "$AUTO_ROTATE" = "1" ] && [ "$failures" -ge "$FAILURES_THR" ]; then
          log "instance ${id}: v4 collision auto rotate (${ROTATE_MODE:-restart})"
          bash "${SCRIPTS_DIR}/rotate-instance.sh" "$id" "${ROTATE_MODE:-restart}" || true
        fi
      else
        # persist IP change on reconnect/boot (not only explicit rotate)
        if [ -n "$ip" ] && [ -n "$prev_v4" ] && [ "$ip" != "$prev_v4" ]; then
          append_ip_history "$id" "$prev_v4" "$ip" "probe"
          log "instance ${id}: ip change ${prev_v4} → ${ip} (probe)"
        elif [ -n "$ip" ] && [ -z "$prev_v4" ]; then
          append_ip_history "$id" "" "$ip" "observe"
        fi
        write_meta "$id" true "$ip" 0 "$last_rotate" "$(cat "$pidfile")" "" true
        release_unique_lock
        # probe/healthy meta 与是否进 backends 解耦：unpool 仍可 healthy+直连
        if is_pool_eligible "$id"; then
          backends_json="$(echo "$backends_json" | jq -c \
            --argjson id "$id" \
            --arg addr "$(socks_addr "$id")" \
            '. + [{id:$id, addr:$addr}]')"
          log "instance ${id}: healthy v4=${ip} unique=true pooled socks=$(socks_addr "$id")"
        else
          log "instance ${id}: healthy v4=${ip} unique=true but not pooled — skip backends"
        fi
      fi
    else
      # lock busy (rotate committing): keep out of pool this pass
      write_meta "$id" false "$ip" "$failures" "$last_rotate" "$(cat "$pidfile")" "" false
      log "instance ${id}: unique lock busy — skip pool this pass v4=${ip}"
    fi
  else
    failures=$((failures + 1))
    write_meta "$id" false "" "$failures" "$last_rotate" "$(cat "$pidfile")" "" false
    log "instance ${id}: probe fail failures=${failures}"
    if [ "$AUTO_ROTATE" = "1" ] && [ "$failures" -ge "$FAILURES_THR" ]; then
      log "instance ${id}: auto rotate (${ROTATE_MODE:-restart})"
      bash "${SCRIPTS_DIR}/rotate-instance.sh" "$id" "${ROTATE_MODE:-restart}" || true
    fi
  fi
done < <(list_instance_ids)

echo "{\"backends\": ${backends_json}}" | jq -c . > "${DATA_DIR}/state/healthy.json"
log "healthy.json updated: $(cat "${DATA_DIR}/state/healthy.json")"
