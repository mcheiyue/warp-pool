#!/usr/bin/env bash
# shared helpers for warp-pool v0.3 (Warp mode × netns)
set -euo pipefail

DATA_DIR="${DATA_DIR:-/data}"
INSTANCE_PORT_BASE="${INSTANCE_PORT_BASE:-40000}"
EXPOSE_PORT_BASE="${EXPOSE_PORT_BASE:-11000}"
ENABLE_EXPOSE="${ENABLE_EXPOSE:-1}"
SCRIPTS_DIR="${SCRIPTS_DIR:-/opt/warp-pool/scripts}"
PID_DIR="${PID_DIR:-/run/warp-pool}"
WARP_CONNECT_TIMEOUT="${WARP_CONNECT_TIMEOUT:-45}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-15}"
NETNS_PREFIX="${NETNS_PREFIX:-wp}"
VETH_SUBNET_BASE="${VETH_SUBNET_BASE:-10.200}"
# SOCKS_BIN=microsocks preferred (Dockerfile); gost fallback if binary missing
SOCKS_BIN="${SOCKS_BIN:-gost}"
GOST_BIN="${GOST_BIN:-gost}"
V4_UNIQUE="${V4_UNIQUE:-1}"
V4_UNIQUE_RETRIES="${V4_UNIQUE_RETRIES:-3}"
V4_UNIQUE_HARD_RETRIES="${V4_UNIQUE_HARD_RETRIES:-2}"
V4_UNIQUE_BACKOFF="${V4_UNIQUE_BACKOFF:-5}"
V4_UNIQUE_LOCK_TIMEOUT="${V4_UNIQUE_LOCK_TIMEOUT:-60}"

log() { echo "==> [warp-pool] $*"; }
err() { echo "==> [warp-pool][ERROR] $*" >&2; }

# append timestamped line to ${DATA_DIR}/logs/warp-pool.log
log_file() {
  local f="${DATA_DIR}/logs/warp-pool.log"
  mkdir -p "${DATA_DIR}/logs"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$f"
}
log_event() {
  log "$*"
  log_file "$*" || true
}

instance_dir() { echo "${DATA_DIR}/instances/$1"; }
instance_state_dir() { echo "$(instance_dir "$1")/state"; }
instance_run_dir() { echo "/run/warp-$1"; }
instance_dbus_dir() { echo "/run/dbus-$1"; }
instance_dbus_addr() { echo "unix:path=$(instance_dbus_dir "$1")/system_bus_socket"; }
instance_port() { echo $((INSTANCE_PORT_BASE + $1)); }
expose_port() { echo $((EXPOSE_PORT_BASE + $1)); }

ns_name() { echo "${NETNS_PREFIX}$1"; }
# host side of veth
veth_host() { echo "v${NETNS_PREFIX}$1"; }
veth_peer() { echo "p${NETNS_PREFIX}$1"; }
# 10.200.<id>.1 host, .2 in ns
ns_host_ip() { echo "${VETH_SUBNET_BASE}.$1.1"; }
ns_peer_ip() { echo "${VETH_SUBNET_BASE}.$1.2"; }
# SOCKS inside ns (reachable from main ns via peer IP)
socks_addr() { echo "$(ns_peer_ip "$1"):$(instance_port "$1")"; }

pidfile_svc() { echo "${PID_DIR}/warp-svc-${1}.pid"; }
pidfile_dbus() { echo "${PID_DIR}/dbus-${1}.pid"; }
pidfile_expose() { echo "${PID_DIR}/expose-${1}.pid"; }
pidfile_gost() { echo "${PID_DIR}/gost-${1}.pid"; }

ensure_dirs() {
  local id="$1"
  mkdir -p "$(instance_dir "$id")" "$(instance_state_dir "$id")" "${DATA_DIR}/state" "${PID_DIR}"
  mkdir -p "$(instance_run_dir "$id")" "$(instance_dbus_dir "$id")"
  mkdir -p /root/.local/share/warp
  echo -n yes > /root/.local/share/warp/accepted-tos.txt
}

# one-shot host NAT for all instance subnets
ensure_host_forward() {
  # ip_forward often read-only in container; prefer docker --sysctl net.ipv4.ip_forward=1
  if [ -w /proc/sys/net/ipv4/ip_forward ]; then
    echo 1 > /proc/sys/net/ipv4/ip_forward || true
  fi
  mkdir -p /dev/net
  [ -e /dev/net/tun ] || mknod /dev/net/tun c 10 200
  chmod 600 /dev/net/tun 2>/dev/null || true
  if command -v iptables >/dev/null 2>&1; then
    iptables -t nat -C POSTROUTING -s "${VETH_SUBNET_BASE}.0.0/16" -j MASQUERADE 2>/dev/null \
      || iptables -t nat -A POSTROUTING -s "${VETH_SUBNET_BASE}.0.0/16" -j MASQUERADE || true
    iptables -C FORWARD -s "${VETH_SUBNET_BASE}.0.0/16" -j ACCEPT 2>/dev/null \
      || iptables -A FORWARD -s "${VETH_SUBNET_BASE}.0.0/16" -j ACCEPT || true
    iptables -C FORWARD -d "${VETH_SUBNET_BASE}.0.0/16" -j ACCEPT 2>/dev/null \
      || iptables -A FORWARD -d "${VETH_SUBNET_BASE}.0.0/16" -j ACCEPT || true
  fi
}

ensure_netns() {
  local id="$1"
  local name host_ip peer_ip veth peer
  name="$(ns_name "$id")"
  host_ip="$(ns_host_ip "$id")"
  peer_ip="$(ns_peer_ip "$id")"
  veth="$(veth_host "$id")"
  peer="$(veth_peer "$id")"

  if ! ip netns list 2>/dev/null | grep -qw "$name"; then
    ip netns add "$name"
  fi
  # recreate veth if missing
  if ! ip link show "$veth" >/dev/null 2>&1; then
    ip link del "$veth" 2>/dev/null || true
    ip link add "$veth" type veth peer name "$peer"
    ip link set "$peer" netns "$name"
    ip addr flush dev "$veth" 2>/dev/null || true
    ip addr add "${host_ip}/24" dev "$veth"
    ip link set "$veth" up
    ip netns exec "$name" ip addr add "${peer_ip}/24" dev "$peer" 2>/dev/null || true
    ip netns exec "$name" ip link set "$peer" up
    ip netns exec "$name" ip link set lo up
    ip netns exec "$name" ip route replace default via "$host_ip"
  fi
  ip netns exec "$name" bash -c 'mkdir -p /dev/net; [ -e /dev/net/tun ] || mknod /dev/net/tun c 10 200; chmod 600 /dev/net/tun'
  mkdir -p "/etc/netns/${name}"
  if [ -f /etc/resolv.conf ]; then
    cp -L /etc/resolv.conf "/etc/netns/${name}/resolv.conf" 2>/dev/null || true
  fi
}

ns_exec() {
  local id="$1"
  shift
  ip netns exec "$(ns_name "$id")" "$@"
}

# warp-cli inside instance netns
wcli() {
  local id="$1"
  shift
  ns_exec "$id" env \
    STATE_DIRECTORY="$(instance_state_dir "$id")" \
    RUNTIME_DIRECTORY="$(instance_run_dir "$id")" \
    DBUS_SYSTEM_BUS_ADDRESS="$(instance_dbus_addr "$id")" \
    warp-cli --accept-tos "$@"
}

# write_meta id healthy v4 [failures] [last_rotate] [pid] [v6] [unique] [pooled] [exclude_reason]
# Runtime fields always overwrite. Ops fields pooled/exclude_reason:
#   - if arg 9/10 provided → set explicitly
#   - else merge from existing meta (missing pooled → true)
write_meta() {
  local id="$1"
  local healthy="${2:-false}"
  local v4="${3:-}"
  local failures="${4:-0}"
  local last_rotate="${5:-}"
  local pid="${6:-}"
  local v6="${7:-}"
  local unique="${8:-}"
  local dir meta
  local pooled="true"
  local exclude_reason=""
  local set_pooled=0 set_exclude=0
  dir="$(instance_dir "$id")"
  mkdir -p "$dir"
  meta="${dir}/meta.json"
  if [ "$#" -ge 9 ]; then
    set_pooled=1
  fi
  if [ "$#" -ge 10 ]; then
    set_exclude=1
  fi
  if [ -f "$meta" ]; then
    pooled="$(jq -r 'if has("pooled") then (if .pooled then "true" else "false" end) else "true" end' "$meta" 2>/dev/null || echo true)"
    exclude_reason="$(jq -r '.exclude_reason // empty' "$meta" 2>/dev/null || true)"
  fi
  if [ "$set_pooled" -eq 1 ]; then
    case "${9}" in
      true|TRUE|1|yes|YES) pooled="true" ;;
      *) pooled="false" ;;
    esac
  fi
  if [ "$set_exclude" -eq 1 ]; then
    exclude_reason="${10}"
  fi
  if [ -z "$unique" ]; then
    if [ "$healthy" = "true" ] && [ -n "$v4" ]; then
      unique="true"
    else
      unique="false"
    fi
  fi
  local pooled_json="true"
  [ "$pooled" = "true" ] || pooled_json="false"
  jq -n \
    --argjson id "$id" \
    --argjson healthy "$healthy" \
    --arg v4 "$v4" \
    --arg v6 "$v6" \
    --arg ip "$v4" \
    --argjson failures "$failures" \
    --arg last_rotate "$last_rotate" \
    --arg pid "$pid" \
    --argjson unique "$unique" \
    --argjson pooled "$pooled_json" \
    --arg exclude_reason "$exclude_reason" \
    --argjson port "$(instance_port "$id")" \
    --argjson expose "$(expose_port "$id")" \
    --arg mode "warp" \
    --arg netns "$(ns_name "$id")" \
    --arg socks "$(socks_addr "$id")" \
    '{
      id:$id, healthy:$healthy, unique:$unique, pooled:$pooled, exclude_reason:$exclude_reason,
      v4:$v4, v6:$v6, ip:$ip,
      failures:$failures, last_rotate:$last_rotate, pid:$pid,
      port:$port, expose:$expose, mode:$mode, netns:$netns, socks:$socks,
      updated:(now|todate)
    }' > "${meta}.tmp"
  mv "${meta}.tmp" "$meta"
}

# return 0 = may enter healthy.json backends; 1 = skip backends
# pooled missing → true; rotate lock → not eligible
is_pool_eligible() {
  local id="$1"
  local meta pooled
  if [ -f "${PID_DIR}/rotate-${id}.lock" ]; then
    return 1
  fi
  meta="$(instance_dir "$id")/meta.json"
  if [ ! -f "$meta" ]; then
    return 0
  fi
  pooled="$(jq -r 'if has("pooled") then (if .pooled then "true" else "false" end) else "true" end' "$meta" 2>/dev/null || echo true)"
  [ "$pooled" = "true" ]
}

# Append one IP change line (rotate success). Keeps last ~200 lines.
append_ip_history() {
  local id="$1" old_ip="$2" new_ip="$3" reason="${4:-rotate}"
  local f tmp dir
  dir="$(instance_dir "$id")"
  mkdir -p "$dir"
  f="${dir}/ip-history.jsonl"
  printf '{"ts":"%s","old":"%s","new":"%s","reason":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${old_ip}" "${new_ip}" "${reason}" >>"$f" || true
  # trim tail
  if [ -f "$f" ]; then
    tmp="${f}.tmp.$$"
    tail -n 200 "$f" >"$tmp" 2>/dev/null && mv "$tmp" "$f" || rm -f "$tmp"
  fi
}

# Numeric instance ids under DATA_DIR/instances (source of truth after hot-add).
# Fallback: 0..WARP_INSTANCES-1 when no dirs yet (boot).
list_instance_ids() {
  local ids=() d base n id
  if [ -d "${DATA_DIR}/instances" ]; then
    for d in "${DATA_DIR}/instances"/*; do
      [ -d "$d" ] || continue
      base="$(basename "$d")"
      [[ "$base" =~ ^[0-9]+$ ]] || continue
      ids+=("$base")
    done
  fi
  if [ "${#ids[@]}" -eq 0 ]; then
    n="${WARP_INSTANCES:-2}"
    for ((id = 0; id < n; id++)); do
      ids+=("$id")
    done
  fi
  if [ "${#ids[@]}" -eq 0 ]; then
    return 0
  fi
  printf '%s\n' "${ids[@]}" | sort -n
}

# return 0 = conflict with another healthy instance; 1 = unique or disabled
v4_conflicts() {
  local id="$1"
  local v4="$2"
  local other_dir other_id other_meta other_healthy other_v4
  if [ "${V4_UNIQUE}" = "0" ]; then
    return 1
  fi
  if [ -z "$v4" ]; then
    return 1
  fi
  for other_dir in "${DATA_DIR}/instances"/*; do
    [ -d "$other_dir" ] || continue
    other_id="$(basename "$other_dir")"
    case "$other_id" in
      ''|*[!0-9]*) continue ;;
    esac
    [ "$other_id" = "$id" ] && continue
    other_meta="${other_dir}/meta.json"
    [ -f "$other_meta" ] || continue
    other_healthy="$(jq -r '.healthy // false' "$other_meta" 2>/dev/null || echo false)"
    [ "$other_healthy" = "true" ] || continue
    other_v4="$(jq -r '.v4 // empty' "$other_meta" 2>/dev/null || true)"
    if [ -n "$other_v4" ] && [ "$other_v4" = "$v4" ]; then
      return 0
    fi
  done
  return 1
}

acquire_unique_lock() {
  local lock="${PID_DIR}/v4-unique.lock"
  local timeout="${1:-$V4_UNIQUE_LOCK_TIMEOUT}"
  local elapsed=0
  mkdir -p "${PID_DIR}"
  while ! mkdir "$lock" 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [ "$elapsed" -ge "$timeout" ]; then
      err "v4 unique lock timeout (${timeout}s)"
      return 1
    fi
  done
  echo $$ > "${lock}/pid" 2>/dev/null || true
  return 0
}

release_unique_lock() {
  rm -rf "${PID_DIR}/v4-unique.lock"
}

# commit healthy only if v4 unique among healthy peers (holds global lock)
# usage: commit_if_unique id v4 [failures] [last_rotate] [pid] [v6]
# return 0 committed; 1 conflict or lock fail
commit_if_unique() {
  local id="$1"
  local v4="$2"
  local failures="${3:-0}"
  local last_rotate="${4:-}"
  local pid="${5:-}"
  local v6="${6:-}"
  if ! acquire_unique_lock; then
    return 1
  fi
  if v4_conflicts "$id" "$v4"; then
    release_unique_lock
    return 1
  fi
  write_meta "$id" true "$v4" "$failures" "$last_rotate" "$pid" "$v6" true
  release_unique_lock
  return 0
}

# boot/ready helper: probe then ensure unique via restart then hard (COOLDOWN=0)
# return 0 if unique healthy; 1 otherwise. echoes v4 on success.
ensure_instance_unique() {
  local id="$1"
  local ip="" ok=0 attempt=0
  local max_restart="${V4_UNIQUE_RETRIES}"
  local max_hard="${V4_UNIQUE_HARD_RETRIES}"
  local backoff="${V4_UNIQUE_BACKOFF}"
  local ts pid

  if [ "${V4_UNIQUE}" = "0" ]; then
    if ip="$(probe_instance "$id")"; then
      write_meta "$id" true "$ip" 0 "" "$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)" "" true
      echo "$ip"
      return 0
    fi
    return 1
  fi

  if ip="$(probe_instance "$id")"; then
    pid="$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)"
    if commit_if_unique "$id" "$ip" 0 "" "$pid"; then
      echo "$ip"
      return 0
    fi
    log "instance ${id}: v4 collision ${ip} at boot — retry uniqueness"
  else
    return 1
  fi

  export SUPERVISE_RESTART=0
  attempt=0
  while [ "$attempt" -lt "$max_restart" ]; do
    attempt=$((attempt + 1))
    log "instance ${id}: unique restart attempt ${attempt}/${max_restart} after v4=${ip}"
    sleep "$backoff"
    bash "${SCRIPTS_DIR}/stop-instance.sh" "$id" || true
    bash "${SCRIPTS_DIR}/ensure-instance.sh" "$id"
    bash "${SCRIPTS_DIR}/start-instance.sh" "$id"
    sleep 5
    ok=0
    ip=""
    for _ in 1 2 3 4 5 6 7 8; do
      if ip="$(probe_instance "$id")"; then
        ok=1
        break
      fi
      sleep 3
    done
    [ "$ok" = 1 ] || continue
    pid="$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)"
    if commit_if_unique "$id" "$ip" 0 "" "$pid"; then
      echo "$ip"
      return 0
    fi
    log "instance ${id}: v4 collision ${ip} (restart attempt ${attempt})"
  done

  attempt=0
  while [ "$attempt" -lt "$max_hard" ]; do
    attempt=$((attempt + 1))
    log "instance ${id}: unique hard attempt ${attempt}/${max_hard}"
    sleep "$backoff"
    bash "${SCRIPTS_DIR}/stop-instance.sh" "$id" || true
    rm -rf "$(instance_state_dir "$id")"
    mkdir -p "$(instance_state_dir "$id")"
    bash "${SCRIPTS_DIR}/ensure-instance.sh" "$id"
    bash "${SCRIPTS_DIR}/start-instance.sh" "$id"
    sleep 5
    ok=0
    ip=""
    for _ in 1 2 3 4 5 6 7 8; do
      if ip="$(probe_instance "$id")"; then
        ok=1
        break
      fi
      sleep 3
    done
    [ "$ok" = 1 ] || continue
    pid="$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)"
    if commit_if_unique "$id" "$ip" 0 "" "$pid"; then
      echo "$ip"
      return 0
    fi
    log "instance ${id}: v4 collision ${ip} (hard attempt ${attempt})"
  done

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_meta "$id" false "${ip:-}" 1 "$ts" "$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)" "" false
  err "instance ${id}: v4_collision exhausted at boot v4=${ip:-}"
  return 1
}

# Probe via in-ns SOCKS (microsocks|gost); force IPv4 for pool health
probe_instance() {
  local id="$1"
  local addr out warp ip
  addr="$(socks_addr "$id")"
  out="$(curl -4 -sS --max-time "${HEALTH_TIMEOUT}" \
    --socks5-hostname "${addr}" \
    "https://1.1.1.1/cdn-cgi/trace" 2>/dev/null || true)"
  warp="$(echo "$out" | awk -F= '/^warp=/{print $2}')"
  ip="$(echo "$out" | awk -F= '/^ip=/{print $2}')"
  if echo "${warp:-}" | grep -qE '^(on|plus)$'; then
    if echo "${ip:-}" | grep -qE '^[0-9.]+$'; then
      echo "$ip"
      return 0
    fi
    # fallback plain v4 endpoint through socks
    ip="$(curl -4 -sS --max-time "${HEALTH_TIMEOUT}" \
      --socks5-hostname "${addr}" \
      "https://ipv4.icanhazip.com" 2>/dev/null || true)"
    ip="$(echo "$ip" | tr -d '\r\n ')"
    if echo "${ip:-}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
      echo "$ip"
      return 0
    fi
  fi
  return 1
}

probe_instance_v4() {
  probe_instance "$@"
}

wait_daemon_ready() {
  local id="$1"
  local timeout="${2:-$WARP_CONNECT_TIMEOUT}"
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    if wcli "$id" status 2>/dev/null | grep -qi 'Connected'; then
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  return 1
}
