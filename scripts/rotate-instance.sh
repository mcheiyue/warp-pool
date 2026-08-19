#!/usr/bin/env bash
# rotate-instance.sh <id|all> [hard|restart]
# v0.6 default = hard (chen redraw: wipe STATE). restart = keep STATE reconnect.
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TARGET="${1:?usage: rotate-instance.sh <id|all> [hard|restart]}"
MODE="${2:-${ROTATE_MODE:-hard}}"
COOLDOWN="${ROTATE_COOLDOWN:-300}"
GAP="${ROTATE_ALL_GAP:-15}"
REDRAW_MAX="${REDRAW_MAX:-2}"

case "$MODE" in
  soft|reconnect|restart) MODE=restart ;;
  hard|"") MODE=hard ;;
  *) err "unknown mode: $MODE (use hard|restart)"; exit 2 ;;
esac

_restore_rotate_drain() {
  local id="$1"
  local prev="$2"
  local meta tmp
  meta="$(instance_dir "$id")/meta.json"
  [ -f "$meta" ] || return 0
  tmp="${meta}.tmp.$$"
  if [ "$prev" = "true" ]; then
    jq '.pooled=true | .exclude_reason="" | del(.drain_restore_pooled)' "$meta" >"$tmp" && mv "$tmp" "$meta" || true
  else
    jq '.pooled=false | del(.drain_restore_pooled) | if .exclude_reason=="drain" then .exclude_reason="" else . end' "$meta" >"$tmp" && mv "$tmp" "$meta" || true
  fi
  rebuild_healthy_json || true
}

_rotate_cycle() {
  local id="$1"
  local cycle_mode="$2"
  if [ "$cycle_mode" = "hard" ]; then
    log "instance ${id}: hard redraw — wipe STATE + re-register (chen-aligned)"
    bash "${SCRIPTS_DIR}/stop-instance.sh" "$id" || true
    rm -rf "$(instance_state_dir "$id")"
    mkdir -p "$(instance_state_dir "$id")"
  else
    log "instance ${id}: restart warp-svc (keep STATE) — reconnect"
    bash "${SCRIPTS_DIR}/stop-instance.sh" "$id" || true
  fi
  bash "${SCRIPTS_DIR}/ensure-instance.sh" "$id"
  bash "${SCRIPTS_DIR}/start-instance.sh" "$id"
  sleep 5
  _ROTATE_OK=0
  _ROTATE_IP=""
  local i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if _ROTATE_IP="$(probe_instance "$id")"; then
      _ROTATE_OK=1
      break
    fi
    sleep 3
  done
}

rotate_one() {
  local id="$1"
  local dir meta last now last_epoch delta
  local ts attempts=0
  dir="$(instance_dir "$id")"
  if [ ! -d "$dir" ]; then
    err "instance ${id}: not found"
    return 1
  fi
  meta="${dir}/meta.json"

  if [ -f "$meta" ] && [ "${COOLDOWN}" -gt 0 ] 2>/dev/null; then
    last="$(jq -r '.last_rotate // empty' "$meta" 2>/dev/null || true)"
    if [ -n "$last" ]; then
      now="$(date -u +%s)"
      last_epoch=""
      if last_epoch="$(date -u -d "$last" +%s 2>/dev/null || true)" && [ -n "$last_epoch" ]; then
        :
      fi
      if [ -n "$last_epoch" ]; then
        delta=$((now - last_epoch))
        if [ "$delta" -lt "$COOLDOWN" ]; then
          err "instance ${id}: cooldown (${delta}s < ${COOLDOWN}s)"
          return 1
        fi
      fi
    fi
  fi

  local lock="${PID_DIR}/rotate-${id}.lock"
  local prev_pooled
  mkdir -p "${PID_DIR}"
  clear_stale_rotate_lock "$id"
  if [ -f "$lock" ]; then
    err "instance ${id}: rotate already in progress"
    return 1
  fi
  echo $$ > "$lock"
  date +%s > "${lock}.ts" 2>/dev/null || true

  local old_ip
  old_ip="$(jq -r '.v4 // .ip // empty' "$meta" 2>/dev/null || true)"

  prev_pooled="$(jq -r 'if has("pooled") then (if .pooled then "true" else "false" end) else "true" end' "$meta" 2>/dev/null || echo true)"
  # shellcheck disable=SC2064
  trap "rm -f '$lock' '${lock}.ts'; release_unique_lock 2>/dev/null || true; _restore_rotate_drain '$id' '$prev_pooled'" RETURN

  export SUPERVISE_RESTART=0

  write_meta "$id" false "" "$(jq -r '.failures // 0' "$meta" 2>/dev/null || echo 0)" \
    "$(jq -r '.last_rotate // empty' "$meta" 2>/dev/null || true)" "" "" false
  if [ "$prev_pooled" = "true" ]; then
    jq '.pooled=false | .exclude_reason="drain" | .drain_restore_pooled=true' \
      "$meta" >"${meta}.tmp.$$" && mv "${meta}.tmp.$$" "$meta"
  else
    jq '.pooled=false | .exclude_reason="drain" | .drain_restore_pooled=false' \
      "$meta" >"${meta}.tmp.$$" && mv "${meta}.tmp.$$" "$meta"
  fi
  rebuild_healthy_json || true

  local baseline_ip="$old_ip"

  # commit if unique vs other seats.
  # hard redraw: same baseline never auto-ok (was false-unique when pkill killed peers).
  # restart mode: same IP OK only if truly unique among living/seated peers.
  _commit_seat() {
    local cid="$1" cip="$2" cts="$3" creason="$4"
    if [ -n "$baseline_ip" ] && [ "$cip" = "$baseline_ip" ]; then
      if [ "$MODE" = "hard" ] || [ "${attempts:-0}" -gt 1 ]; then
        log "instance ${cid}: hard/retry still same v4 ${cip} — fail (need new egress)"
        return 1
      fi
      if v4_conflicts "$cid" "$cip"; then
        log "instance ${cid}: same v4 ${cip} + pool conflict — fail"
        return 1
      fi
      log "instance ${cid}: restart same v4 ${cip} unique — accept"
      creason="${creason}:same-ip-ok"
    fi
    if [ "${V4_UNIQUE}" = "0" ]; then
      write_meta "$cid" true "$cip" 0 "$cts" "$(cat "$(pidfile_svc "$cid")" 2>/dev/null || true)" "" true
      append_ip_history "$cid" "$baseline_ip" "$cip" "$creason"
      return 0
    fi
    if commit_if_unique "$cid" "$cip" 0 "$cts" "$(cat "$(pidfile_svc "$cid")" 2>/dev/null || true)"; then
      append_ip_history "$cid" "$baseline_ip" "$cip" "$creason"
      return 0
    fi
    return 1
  }

  # first cycle uses MODE; further uniqueness retries always hard (redraw)
  _rotate_cycle "$id" "$MODE"
  attempts=1
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [ "$_ROTATE_OK" != 1 ]; then
    write_meta "$id" false "" 1 "$ts" "$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)" "" false
    err "instance ${id}: probe failed after rotate"
    mark_rotate_fail "$id"
    rebuild_healthy_json || true
    return 1
  fi

  if _commit_seat "$id" "$_ROTATE_IP" "$ts" "rotate:${MODE}"; then
    log "rotate summary id=${id} ok mode=${MODE} ${baseline_ip:-none}→${_ROTATE_IP} attempts=${attempts}"
    mark_rotate_success "$id"
    rebuild_healthy_json || true
    return 0
  fi

  log "instance ${id}: v4 conflict ${_ROTATE_IP} — hard redraw retries (max ${REDRAW_MAX})"

  local r
  for r in $(seq 1 "${REDRAW_MAX}"); do
    sleep "${V4_UNIQUE_BACKOFF}"
    _rotate_cycle "$id" hard
    attempts=$((attempts + 1))
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$_ROTATE_OK" != 1 ]; then
      log "instance ${id}: probe fail on hard redraw ${r}/${REDRAW_MAX}"
      continue
    fi
    if _commit_seat "$id" "$_ROTATE_IP" "$ts" "rotate:hard"; then
      log "rotate summary id=${id} ok mode=hard ${baseline_ip:-none}→${_ROTATE_IP} attempts=${attempts}"
      mark_rotate_success "$id"
      rebuild_healthy_json || true
      return 0
    fi
    log "instance ${id}: still conflict ${_ROTATE_IP} (hard ${r}/${REDRAW_MAX})"
  done

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_meta "$id" false "${_ROTATE_IP:-}" 1 "$ts" "$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)" "" false
  log "rotate summary id=${id} fail mode=hard ${baseline_ip:-none}→${_ROTATE_IP:-none} attempts=${attempts}"
  mark_rotate_fail "$id"
  rebuild_healthy_json || true
  return 1
}

if [ "$TARGET" = "all" ]; then
  mapfile -t _ids < <(list_instance_ids)
  local_i=0
  local_n="${#_ids[@]}"
  for i in "${_ids[@]}"; do
    rotate_one "$i" || true
    local_i=$((local_i + 1))
    if [ "$local_i" -lt "$local_n" ]; then
      sleep "$GAP"
    fi
  done
else
  rotate_one "$TARGET"
fi
