#!/usr/bin/env bash
# health-once v0.6.1: seat grant/deny; protect seated; sequential seat-push hard
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

FAILURES_THR="${HEALTH_FAILURES:-3}"
AUTO_ROTATE="${HEALTH_AUTO_ROTATE:-0}"
# SEAT_PUSH default on; AUTO_REDRAW_ON_COLLISION overrides if explicitly set
if [ -n "${AUTO_REDRAW_ON_COLLISION:-}" ]; then
  SEAT_PUSH="${AUTO_REDRAW_ON_COLLISION}"
fi
SEAT_PUSH="${SEAT_PUSH:-1}"
SEAT_PUSH_PER_PASS="${SEAT_PUSH_PER_PASS:-1}"

mkdir -p "${DATA_DIR}/state" "${PID_DIR}"

exec 8>"${PID_DIR}/health-once.lock"
if ! flock -n 8; then
  log "health-once already running — skip"
  exit 0
fi

to_start=()
# candidates for seat-push (id list, ordered)
candidates=()

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
        write_meta "$id" false "$ip" "$failures" "$last_rotate" "$(cat "$pidfile")" "" false
        meta_set_field "$id" collision_streak "$collision_streak" 2>/dev/null || true
        log "seat deny id=${id} ip=${ip} reason=v4_collision streak=${collision_streak}"
        # queue for sequential seat-push (never seated peers)
        if is_pool_eligible "$id" && ! is_seated "$id"; then
          candidates+=("$id")
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
    if [ "$AUTO_ROTATE" = "1" ] && [ "$failures" -ge "$FAILURES_THR" ]; then
      if auto_rotate_allowed "$id" && ! is_seated "$id"; then
        candidates+=("$id")
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
  # clear stale start lock if no holder
  rm -f "${PID_DIR}/start-${sid}.lock" 2>/dev/null || true
  bash "${SCRIPTS_DIR}/start-instance.sh" "$sid" || true
done

# ⑤ 全座：eligible 均已入座则不再 hard
_all_eligible_seated=1
_eligible_n=0
_seated_n=0
while read -r _eid; do
  [ -n "$_eid" ] || continue
  is_pool_eligible "$_eid" || continue
  pf="$(pidfile_svc "$_eid")"
  [ -f "$pf" ] && kill -0 "$(cat "$pf" 2>/dev/null || true)" 2>/dev/null || continue
  _eligible_n=$((_eligible_n + 1))
  if is_seated "$_eid"; then
    _seated_n=$((_seated_n + 1))
  else
    _all_eligible_seated=0
  fi
done < <(list_instance_ids)

# v0.6.1: seat-push — hard only candidates; skip when all seated
if [ "$SEAT_PUSH" = "1" ]; then
  if [ "$_eligible_n" -gt 0 ] && [ "$_all_eligible_seated" = "1" ]; then
    log_throttled "seat-push-full" 300 \
      "seat-push skip — all eligible seated (${_seated_n}/${_eligible_n})"
  elif [ "${#candidates[@]}" -eq 0 ]; then
    :
  else
    pushed=0
    for rid in "${candidates[@]+"${candidates[@]}"}"; do
      [ -n "$rid" ] || continue
      if [ "$pushed" -ge "$SEAT_PUSH_PER_PASS" ]; then
        log "seat-push: budget ${SEAT_PUSH_PER_PASS}/pass reached — rest next tick"
        break
      fi
      if is_seated "$rid"; then
        log "seat-push skip id=${rid} — already seated (protect)"
        continue
      fi
      if ! is_pool_eligible "$rid"; then
        continue
      fi
      if ! auto_rotate_allowed "$rid"; then
        log "seat-push skip id=${rid} — cooldown"
        continue
      fi
      if has_active_rotate_lock "$rid"; then
        continue
      fi
      log "seat-push id=${rid} hard redraw (protect seats)"
      if ROTATE_COOLDOWN=0 bash "${SCRIPTS_DIR}/rotate-instance.sh" "$rid" hard; then
        log "seat-push id=${rid} ok"
      else
        log "seat-push id=${rid} fail — seat deny remains, seats untouched"
      fi
      pushed=$((pushed + 1))
    done
  fi
fi

if [ "${#to_start[@]}" -gt 0 ] || [ "${pushed:-0}" -gt 0 ]; then
  sleep 2
  rebuild_healthy_json || true
fi
