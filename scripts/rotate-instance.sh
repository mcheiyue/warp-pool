#!/usr/bin/env bash
# rotate-instance.sh <id|all> [restart|hard]
# restart (default) = kill warp-svc+gost exact PIDs, start again, keep STATE — changes v4
# hard = wipe STATE + re-register + restart
# soft|reconnect accepted as aliases of restart (v0.2 compat)
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

rotate_one() {
  local id="$1"
  local dir meta last now last_epoch delta
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
  mkdir -p "${PID_DIR}"
  echo $$ > "$lock"
  # always clear lock (API hang / set -e path)
  # shellcheck disable=SC2064
  trap "rm -f '$lock'" RETURN

  export SUPERVISE_RESTART=0

  write_meta "$id" false "" "$(jq -r '.failures // 0' "$meta" 2>/dev/null || echo 0)" \
    "$(jq -r '.last_rotate // empty' "$meta" 2>/dev/null || true)" ""
  SUPERVISE_RESTART=0 bash "${SCRIPTS_DIR}/health-once.sh" || true

  if [ "$MODE" = "hard" ]; then
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
  local ts ok=0 ip=""
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    if ip="$(probe_instance "$id")"; then
      ok=1
      break
    fi
    sleep 3
  done
  if [ "$ok" = 1 ]; then
    write_meta "$id" true "$ip" 0 "$ts" "$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)"
    log "instance ${id}: rotate ok mode=${MODE} v4=${ip}"
  else
    write_meta "$id" false "" 1 "$ts" "$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)"
    err "instance ${id}: probe failed after rotate"
    SUPERVISE_RESTART=0 bash "${SCRIPTS_DIR}/health-once.sh" || true
    return 1
  fi
  SUPERVISE_RESTART=0 bash "${SCRIPTS_DIR}/health-once.sh" || true
}

if [ "$TARGET" = "all" ]; then
  n="${WARP_INSTANCES:-2}"
  for ((i = 0; i < n; i++)); do
    rotate_one "$i" || true
    if [ "$i" -lt $((n - 1)) ]; then
      sleep "$GAP"
    fi
  done
else
  rotate_one "$TARGET"
fi
