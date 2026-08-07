#!/usr/bin/env bash
# remove-instance.sh <id> — stop, drop netns, delete instance dir (no residue)
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

id="${1:?usage: remove-instance.sh <id>}"

export SUPERVISE_RESTART=0
bash "${SCRIPTS_DIR}/stop-instance.sh" "$id" drop-netns || true

# pidfiles (belt)
rm -f \
  "$(pidfile_svc "$id")" \
  "$(pidfile_dbus "$id")" \
  "$(pidfile_gost "$id")" \
  "$(pidfile_expose "$id")" \
  "${PID_DIR}/rotate-${id}.lock" 2>/dev/null || true

dir="$(instance_dir "$id")"
if [ -d "$dir" ]; then
  rm -rf "$dir"
  log "instance ${id}: data dir removed"
fi

log "instance ${id}: removed (no residue)"
