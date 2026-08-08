#!/usr/bin/env bash
# rotate-instance.sh <id|all> [restart|hard]
# restart (default) = kill warp-svc+gost exact PIDs, start again, keep STATE — changes v4
# hard = wipe STATE + re-register + restart
# soft|reconnect accepted as aliases of restart (v0.2 compat)
# After probe: v4 must be unique vs other healthy instances (V4_UNIQUE=1)
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TARGET="${1:?usage: rotate-instance.sh <id|all> [restart|hard]}"
MODE="${2:-${ROTATE_MODE:-restart}}"
COOLDOWN="${ROTATE_COOLDOWN:-300}"
GAP="${ROTATE_ALL_GAP:-30}"

case "$MODE" in
  soft|reconnect|restart|"") MODE=restart ;;
  hard) MODE=hard ;;
  *) err "unknown mode: $MODE (use restart|hard)"; exit 2 ;;
esac

# restore pooled after temporary rotate drain (RETURN trap)
_restore_rotate_drain() {
  local id="$1"
  local prev="$2"
  local meta tmp
  meta="$(instance_dir "$id")/meta.json"
  [ -f "$meta" ] || return 0
  tmp="${meta}.tmp.$$"
  if [ "$prev" = "true" ]; then
    jq '.pooled=true | .exclude_reason=""' "$meta" >"$tmp" && mv "$tmp" "$meta" || true
  else
    # keep unpooled; only clear our drain marker
    jq '.pooled=false | if .exclude_reason=="drain" then .exclude_reason="" else . end' "$meta" >"$tmp" && mv "$tmp" "$meta" || true
  fi
  SUPERVISE_RESTART=0 bash "${SCRIPTS_DIR}/health-once.sh" || true
}

# stop + optional wipe + ensure + start; sets ok/ip for caller via namerefs-ish globals
_rotate_cycle() {
  local id="$1"
  local cycle_mode="$2"
  if [ "$cycle_mode" = "hard" ]; then
    log "instance ${id}: hard — wipe STATE + restart"
    bash "${SCRIPTS_DIR}/stop-instance.sh" "$id" || true
    rm -rf "$(instance_state_dir "$id")"
    mkdir -p "$(instance_state_dir "$id")"
  else
    log "instance ${id}: restart warp-svc (keep STATE) — v0.3 rotate"
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
  echo $$ > "$lock"

  # temporary unpool (drain) so rotate leaves healthy.json backends mid-work
  prev_pooled="$(jq -r 'if has("pooled") then (if .pooled then "true" else "false" end) else "true" end' "$meta" 2>/dev/null || echo true)"
  # shellcheck disable=SC2064
  trap "rm -f '$lock'; release_unique_lock 2>/dev/null || true; _restore_rotate_drain '$id' '$prev_pooled'" RETURN

  export SUPERVISE_RESTART=0

  write_meta "$id" false "" "$(jq -r '.failures // 0' "$meta" 2>/dev/null || echo 0)" \
    "$(jq -r '.last_rotate // empty' "$meta" 2>/dev/null || true)" "" "" false
  # write_meta merges pooled; force drain after so mid-rotate stays out of pool
  jq '.pooled=false | .exclude_reason="drain"' "$meta" >"${meta}.tmp.$$" && mv "${meta}.tmp.$$" "$meta"
  SUPERVISE_RESTART=0 bash "${SCRIPTS_DIR}/health-once.sh" || true

  local old_ip
  old_ip="$(jq -r '.v4 // .ip // empty' "$meta" 2>/dev/null || true)"

  _rotate_cycle "$id" "$MODE"
  attempts=1
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [ "$_ROTATE_OK" != 1 ]; then
    write_meta "$id" false "" 1 "$ts" "$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)" "" false
    err "instance ${id}: probe failed after rotate"
    SUPERVISE_RESTART=0 bash "${SCRIPTS_DIR}/health-once.sh" || true
    return 1
  fi

  if commit_if_unique "$id" "$_ROTATE_IP" 0 "$ts" "$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)"; then
    append_ip_history "$id" "$old_ip" "$_ROTATE_IP" "rotate:${MODE}"
    old_ip="$_ROTATE_IP"
    log "instance ${id}: rotate ok mode=${MODE} v4=${_ROTATE_IP} unique=true attempts=${attempts}"
    SUPERVISE_RESTART=0 bash "${SCRIPTS_DIR}/health-once.sh" || true
    return 0
  fi

  if [ "${V4_UNIQUE}" = "0" ]; then
    write_meta "$id" true "$_ROTATE_IP" 0 "$ts" "$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)" "" true
    append_ip_history "$id" "$old_ip" "$_ROTATE_IP" "rotate:${MODE}"
    log "instance ${id}: rotate ok mode=${MODE} v4=${_ROTATE_IP} (V4_UNIQUE=0)"
    SUPERVISE_RESTART=0 bash "${SCRIPTS_DIR}/health-once.sh" || true
    return 0
  fi

  log "instance ${id}: v4 collision ${_ROTATE_IP} — uniqueness retries"

  local r
  for r in $(seq 1 "${V4_UNIQUE_RETRIES}"); do
    sleep "${V4_UNIQUE_BACKOFF}"
    _rotate_cycle "$id" restart
    attempts=$((attempts + 1))
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$_ROTATE_OK" != 1 ]; then
      log "instance ${id}: probe fail on unique restart ${r}/${V4_UNIQUE_RETRIES}"
      continue
    fi
    if commit_if_unique "$id" "$_ROTATE_IP" 0 "$ts" "$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)"; then
      append_ip_history "$id" "$old_ip" "$_ROTATE_IP" "rotate:restart"
      log "instance ${id}: rotate ok mode=restart v4=${_ROTATE_IP} unique=true attempts=${attempts}"
      SUPERVISE_RESTART=0 bash "${SCRIPTS_DIR}/health-once.sh" || true
      return 0
    fi
    log "instance ${id}: v4 collision ${_ROTATE_IP} (restart ${r}/${V4_UNIQUE_RETRIES})"
  done

  for r in $(seq 1 "${V4_UNIQUE_HARD_RETRIES}"); do
    sleep "${V4_UNIQUE_BACKOFF}"
    _rotate_cycle "$id" hard
    attempts=$((attempts + 1))
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ "$_ROTATE_OK" != 1 ]; then
      log "instance ${id}: probe fail on unique hard ${r}/${V4_UNIQUE_HARD_RETRIES}"
      continue
    fi
    if commit_if_unique "$id" "$_ROTATE_IP" 0 "$ts" "$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)"; then
      append_ip_history "$id" "$old_ip" "$_ROTATE_IP" "rotate:hard"
      log "instance ${id}: rotate ok mode=hard v4=${_ROTATE_IP} unique=true attempts=${attempts}"
      SUPERVISE_RESTART=0 bash "${SCRIPTS_DIR}/health-once.sh" || true
      return 0
    fi
    log "instance ${id}: v4 collision ${_ROTATE_IP} (hard ${r}/${V4_UNIQUE_HARD_RETRIES})"
  done

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_meta "$id" false "${_ROTATE_IP:-}" 1 "$ts" "$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)" "" false
  err "instance ${id}: v4_collision exhausted v4=${_ROTATE_IP:-} attempts=${attempts}"
  SUPERVISE_RESTART=0 bash "${SCRIPTS_DIR}/health-once.sh" || true
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
