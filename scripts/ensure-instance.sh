#!/usr/bin/env bash
# Ensure instance id has account+profile+wireproxy.conf (register if missing)
set -euo pipefail
# shellcheck source=lib.sh
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

ID="${1:?usage: ensure-instance.sh <id>}"
ensure_dirs "$ID"
DIR="$(instance_dir "$ID")"
cd "$DIR"

ACCOUNT="${DIR}/wgcf-account.toml"
PROFILE="${DIR}/wgcf-profile.conf"

if [ ! -f "$PROFILE" ]; then
  log "instance ${ID}: registering new WARP device..."
  # wgcf uses cwd for account/profile names
  rm -f wgcf-account.toml wgcf-profile.conf
  wgcf register --accept-tos
  if [ -n "${LICENSE_KEY:-}" ]; then
    # first key only for this instance (comma-separated round-robin later)
    KEY="$(echo "$LICENSE_KEY" | cut -d, -f$((ID + 1)) | cut -d, -f1)"
    if [ -z "$KEY" ]; then
      KEY="$(echo "$LICENSE_KEY" | cut -d, -f1)"
    fi
    if [ -n "$KEY" ]; then
      log "instance ${ID}: binding license (best-effort)"
      wgcf update --license-key "$KEY" || log "instance ${ID}: license update failed (continuing)"
    fi
  fi
  wgcf generate
  # wgcf writes to cwd
  [ -f wgcf-account.toml ] && mv -f wgcf-account.toml "$ACCOUNT" || true
  [ -f wgcf-profile.conf ] && mv -f wgcf-profile.conf "$PROFILE"
  sanitize_wgconf "$PROFILE"
  write_meta "$ID" false "" 0 "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ""
  log "instance ${ID}: registered"
else
  log "instance ${ID}: using persisted profile"
  sanitize_wgconf "$PROFILE"
fi

write_wireproxy_conf "$ID"
