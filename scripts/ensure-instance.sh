#!/usr/bin/env bash
# ensure-instance.sh <id> — dirs + netns + veth
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

id="${1:?usage: ensure-instance.sh <id>}"
ensure_host_forward
ensure_dirs "$id"
ensure_netns "$id"
log "instance ${id}: ready netns=$(ns_name "$id") state=$(instance_state_dir "$id") socks=$(socks_addr "$id")"
