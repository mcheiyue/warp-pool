#!/usr/bin/env bash
# Ensure instance id has account+profile+wireproxy.conf (register if missing)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ID="${1:?usage: ensure-instance.sh <id>}"
ensure_dirs "$ID"
DIR="$(instance_dir "$ID")"
ACCOUNT="${DIR}/wgcf-account.toml"
PROFILE="${DIR}/wgcf-profile.conf"

if [ ! -f "$PROFILE" ]; then
  log "instance ${ID}: registering new WARP device..."
  # work in a temp dir so wgcf output is unambiguous
  work="$(mktemp -d)"
  cleanup_work() { rm -rf "$work"; }
  trap cleanup_work EXIT

  (
    cd "$work"
    wgcf register --accept-tos
    if [ -n "${LICENSE_KEY:-}" ]; then
      KEY="$(echo "$LICENSE_KEY" | awk -F, -v i="$((ID + 1))" '{print $i}')"
      if [ -z "$KEY" ]; then
        KEY="$(echo "$LICENSE_KEY" | cut -d, -f1)"
      fi
      if [ -n "$KEY" ]; then
        log "instance ${ID}: binding license (best-effort)"
        wgcf update --license-key "$KEY" || log "instance ${ID}: license update failed (continuing)"
      fi
    fi
    wgcf generate
  )

  cp -f "${work}/wgcf-account.toml" "$ACCOUNT"
  cp -f "${work}/wgcf-profile.conf" "$PROFILE"
  trap - EXIT
  rm -rf "$work"

  sanitize_wgconf "$PROFILE"
  write_meta "$ID" false "" 0 "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ""
  log "instance ${ID}: registered"
else
  log "instance ${ID}: using persisted profile"
  # only sanitize if missing our markers (avoid rewriting live keys every boot unnecessarily)
  if ! grep -q 'PersistentKeepalive = 15' "$PROFILE" 2>/dev/null; then
    sanitize_wgconf "$PROFILE"
  fi
fi

write_wireproxy_conf "$ID"
