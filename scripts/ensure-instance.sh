#!/usr/bin/env bash
# ensure-instance.sh <id> — prepare dirs for official warp-svc instance
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

id="${1:?usage: ensure-instance.sh <id>}"
ensure_dirs "$id"
log "instance ${id}: dirs ready state=$(instance_state_dir "$id")"
