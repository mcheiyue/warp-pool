#!/usr/bin/env bash
# rotate-instance.sh <id|all> [reconnect|soft|hard]
# reconnect|soft = disconnect+connect (default; often changes egress)
# hard = registration delete + new + proxy + connect
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TARGET="${1:?usage: rotate-instance.sh <id|all> [reconnect|soft|hard]}"
MODE="${2:-${ROTATE_MODE:-reconnect}}"
COOLDOWN="${ROTATE_COOLDOWN:-300}"
GAP="${ROTATE_ALL_GAP:-30}"

# API compat: soft == reconnect
case "$MODE" in
  soft|reconnect|"") MODE=reconnect ;;
  hard) MODE=hard ;;
  *) err "unknown mode: $MODE (use reconnect|soft|hard)"; exit 2 ;;
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

  local port
  port="$(instance_port "$id")"

  if [ "$MODE" = "hard" ]; then
    log "instance ${id}: hard re-register"
    wcli "$id" registration delete 2>/dev/null || true
    sleep 1
    # clear local reg if still present
    sudo rm -f "$(instance_state_dir "$id")/reg.json" 2>/dev/null || true
    wcli "$id" registration new
    if [ -n "${WARP_LICENSE_KEY:-${LICENSE_KEY:-}}" ]; then
      wcli "$id" registration license "${WARP_LICENSE_KEY:-$LICENSE_KEY}" 2>/dev/null || true
    fi
    wcli "$id" mode proxy
    wcli "$id" proxy port "$port"
    wcli "$id" connect
  else
    log "instance ${id}: reconnect"
    wcli "$id" disconnect 2>/dev/null || true
    sleep 2
    wcli "$id" mode proxy 2>/dev/null || true
    wcli "$id" proxy port "$port" 2>/dev/null || true
    wcli "$id" connect
  fi

  sleep 5
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ip="$(probe_instance "$id")"; then
    write_meta "$id" true "$ip" 0 "$ts" "$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)"
    log "instance ${id}: rotate ok mode=${MODE} ip=${ip}"
  else
    write_meta "$id" false "" 1 "$ts" "$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)"
    err "instance ${id}: probe failed after rotate"
    return 1
  fi
  bash "${SCRIPTS_DIR}/health-once.sh" || true
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
