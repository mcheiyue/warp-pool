#!/usr/bin/env bash
# health-once v0.6: seat grant/deny; protect seated; no collision auto-kick
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

FAILURES_THR="${HEALTH_FAILURES:-3}"
AUTO_ROTATE="${HEALTH_AUTO_ROTATE:-0}"
AUTO_REDRAW="${AUTO_REDRAW_ON_COLLISION:-0}"

mkdir -p "${DATA_DIR}/state" "${PID_DIR}"

exec 8>"${PID_DIR}/health-once.lock"
if ! flock -n 8; then
  log "health-once already running — skip"
  exit 0
fi

to_start=()
to_redraw=()

while read -r id; do
  [ -n "$id" ] || continue
  dir="$(instance_dir "$id")"
  [ -d "$dir" ] || continue
  meta="${dir}/meta.json"
  pidfile="$(pidfile_svc "$id")"
  failures=0
  collision_streak=0
  last_rotate=""
  prev_v4=""
  if [ -f "$meta" ]; then
    failures="$(jq -r '.failures // 0' "$meta" 2>/dev/null || echo 0)"
    collision_streak="$(jq -r '.collision_streak // 0' "$meta" 2>/dev/null || echo 0)"
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

  if has_active_rotate_lock "$id"; then
    log_throttled "rotate-skip-${id}" "${LOG_THROTTLE_SEC:-300}" \
      "instance ${id}: rotate in progress — skip"
    continue
  fi

  if heal_stale_rotate_drain "$id"; then
    if [ -f "$meta" ]; then
      failures="$(jq -r '.failures // 0' "$meta" 2>/dev/null || echo 0)"
      collision_streak="$(jq -r '.collision_streak // 0' "$meta" 2>/dev/null || echo 0)"
      last_rotate="$(jq -r '.last_rotate // empty' "$meta" 2>/dev/null || true)"
    fi
  fi

  if [ "$alive" -eq 0 ]; then
    if ! is_pool_eligible "$id"; then
      log_throttled "parked-${id}" "${LOG_THROTTLE_SEC:-300}" \
        "instance ${id}: process dead + not pooled — leave parked"
      write_meta "$id" false "" "$failures" "$last_rotate" "" "" false
      continue
    fi
    log "instance ${id}: process dead — marking unhealthy"
    failures=$((failures + 1))
    write_meta "$id" false "" "$failures" "$last_rotate" "" "" false
    meta_set_field "$id" collision_streak 0 2>/dev/null || true
    if [ "${SUPERVISE_RESTART:-1}" = "1" ]; then
      to_start+=("$id")
    fi
    continue
  fi

  if ip="$(probe_instance "$id")"; then
    if acquire_unique_lock 10; then
      if v4_conflicts "$id" "$ip"; then
        release_unique_lock
        collision_streak=$((collision_streak + 1))
        # deny seat; keep process; NEVER rotate an already-seated peer
        write_meta "$id" false "$ip" "$failures" "$last_rotate" "$(cat "$pidfile")" "" false
        meta_set_field "$id" collision_streak "$collision_streak" 2>/dev/null || true
        log "seat deny id=${id} ip=${ip} reason=v4_collision streak=${collision_streak}"
        # optional: redraw only THIS candidate if not already seated and switch on
        if [ "$AUTO_REDRAW" = "1" ] && ! is_seated "$id"; then
          if auto_rotate_allowed "$id"; then
            to_redraw+=("$id")
          fi
        fi
      else
        if [ -n "$ip" ] && [ -n "$prev_v4" ] && [ "$ip" != "$prev_v4" ]; then
          append_ip_history "$id" "$prev_v4" "$ip" "probe"
          log "instance ${id}: ip change ${prev_v4} → ${ip} (probe)"
        elif [ -n "$ip" ] && [ -z "$prev_v4" ]; then
          append_ip_history "$id" "" "$ip" "observe"
        fi
        write_meta "$id" true "$ip" 0 "$last_rotate" "$(cat "$pidfile")" "" true
        meta_set_field "$id" collision_streak 0 2>/dev/null || true
        release_unique_lock
        if is_pool_eligible "$id"; then
          log "seat grant id=${id} ip=${ip} pooled socks=$(socks_addr "$id")"
        else
          log "instance ${id}: healthy v4=${ip} unique but not pooled — skip backends"
        fi
      fi
    else
      write_meta "$id" false "$ip" "$failures" "$last_rotate" "$(cat "$pidfile")" "" false
      log "instance ${id}: unique lock busy — skip seat this pass v4=${ip}"
    fi
  else
    failures=$((failures + 1))
    write_meta "$id" false "" "$failures" "$last_rotate" "$(cat "$pidfile")" "" false
    log "instance ${id}: probe fail failures=${failures}"
    # probe fail: only start-level recovery via AUTO_ROTATE (legacy) — prefer start not hard
    if [ "$AUTO_ROTATE" = "1" ] && [ "$failures" -ge "$FAILURES_THR" ]; then
      if auto_rotate_allowed "$id" && ! is_seated "$id"; then
        to_redraw+=("$id")
      fi
    fi
  fi
done < <(list_instance_ids)

rebuild_healthy_json || true
log "healthy.json updated: $(cat "${DATA_DIR}/state/healthy.json" 2>/dev/null || echo '{}')"

exec 8>&- || true

for sid in "${to_start[@]+"${to_start[@]}"}"; do
  [ -n "$sid" ] || continue
  log "instance ${sid}: deferred start (was dead)"
  bash "${SCRIPTS_DIR}/start-instance.sh" "$sid" || true
done

# candidate redraw only (hard); never touches seated peers inside rotate of self
for rid in "${to_redraw[@]+"${to_redraw[@]}"}"; do
  [ -n "$rid" ] || continue
  if is_seated "$rid"; then
    log "instance ${rid}: skip redraw — already seated (protect)"
    continue
  fi
  log "instance ${rid}: deferred candidate redraw (hard)"
  bash "${SCRIPTS_DIR}/rotate-instance.sh" "$rid" hard || true
done

if [ "${#to_start[@]}" -gt 0 ] || [ "${#to_redraw[@]}" -gt 0 ]; then
  sleep 2
  rebuild_healthy_json || true
fi
