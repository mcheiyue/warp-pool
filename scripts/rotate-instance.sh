#!/usr/bin/env bash
# rotate-instance.sh <id|all> [soft|reconnect]
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

TARGET="${1:?usage: rotate-instance.sh <id|all> [soft|reconnect]}"
MODE="${2:-soft}"
COOLDOWN="${ROTATE_COOLDOWN:-300}"
GAP="${ROTATE_ALL_GAP:-30}"

rotate_one() {
  local id="$1"
  local dir meta last now delta
  dir="$(instance_dir "$id")"
  if [ ! -d "$dir" ]; then
    err "instance ${id}: not found"
    return 1
  fi
  meta="${dir}/meta.json"
  if [ "$MODE" = "soft" ] && [ -f "$meta" ]; then
    last="$(jq -r '.last_rotate // empty' "$meta" 2>/dev/null || true)"
    if [ -n "$last" ]; then
      now="$(date -u +%s)"
      # busybox date may not parse ISO; store epoch in side file if needed
      if last_epoch="$(date -u -d "$last" +%s 2>/dev/null || true)" && [ -n "$last_epoch" ]; then
        delta=$((now - last_epoch))
        if [ "$delta" -lt "$COOLDOWN" ]; then
          err "instance ${id}: cooldown (${delta}s < ${COOLDOWN}s)"
          return 1
        fi
      fi
    fi
  fi

  bash "${SCRIPTS_DIR}/stop-instance.sh" "$id"

  if [ "$MODE" = "soft" ]; then
    log "instance ${id}: soft re-register"
    rm -f "${dir}/wgcf-account.toml" "${dir}/wgcf-profile.conf" "${dir}/wireproxy.conf"
    bash "${SCRIPTS_DIR}/ensure-instance.sh" "$id"
    write_meta "$id" false "" 0 "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ""
  else
    log "instance ${id}: reconnect only"
    write_wireproxy_conf "$id"
  fi

  bash "${SCRIPTS_DIR}/start-instance.sh" "$id"
  sleep 2
  if ip="$(probe_instance "$id")"; then
    write_meta "$id" true "$ip" 0 "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(cat "${PID_DIR}/wireproxy-${id}.pid" 2>/dev/null || true)"
    log "instance ${id}: rotate ok ip=${ip}"
  else
    write_meta "$id" false "" 1 "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(cat "${PID_DIR}/wireproxy-${id}.pid" 2>/dev/null || true)"
    err "instance ${id}: probe failed after rotate"
    return 1
  fi
  # refresh healthy set
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
