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
# auto-rotate fuse (P0.2)
ROTATE_FAIL_STREAK_MAX="${ROTATE_FAIL_STREAK_MAX:-2}"
ROTATE_COOLDOWN_SEC="${ROTATE_COOLDOWN_SEC:-1800}"
COLLISION_ROTATE_THR="${COLLISION_ROTATE_THR:-3}"
# v0.6 seat + redraw
REDRAW_MAX="${REDRAW_MAX:-2}"
# seat push: sequentially hard not_unique candidates (protect seated)
SEAT_PUSH="${SEAT_PUSH:-1}"
SEAT_PUSH_PER_PASS="${SEAT_PUSH_PER_PASS:-1}"
# legacy alias — if set, treated as SEAT_PUSH
AUTO_REDRAW_ON_COLLISION="${AUTO_REDRAW_ON_COLLISION:-}"
# entrypoint: do not suicide whole container on transient all-dead
SUPERVISE_EXIT_ON_ALL_DEAD="${SUPERVISE_EXIT_ON_ALL_DEAD:-0}"
# default rotate mode (chen redraw)
ROTATE_MODE="${ROTATE_MODE:-hard}"

# MUST go to stderr — many callers capture stdout (ip="$(ensure_instance_unique)")
log() { echo "==> [warp-pool] $*" >&2; }
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
  local drain_restore=""
  local collision_streak=0
  local rotate_fail_streak=0
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
    # preserve rotate-only marker across runtime meta rewrites
    drain_restore="$(jq -r 'if has("drain_restore_pooled") then (if .drain_restore_pooled then "true" else "false" end) else empty end' "$meta" 2>/dev/null || true)"
    collision_streak="$(jq -r '.collision_streak // 0' "$meta" 2>/dev/null || echo 0)"
    rotate_fail_streak="$(jq -r '.rotate_fail_streak // 0' "$meta" 2>/dev/null || echo 0)"
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
  # drop drain_restore when exclude is no longer drain
  if [ "$exclude_reason" != "drain" ]; then
    drain_restore=""
  fi
  # healthy unique probe success → reset collision streak (caller may override via meta_set)
  if [ "$healthy" = "true" ] && [ "$unique" = "true" ]; then
    collision_streak=0
  fi
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
    --arg drain_restore "$drain_restore" \
    --argjson collision_streak "$collision_streak" \
    --argjson rotate_fail_streak "$rotate_fail_streak" \
    --argjson port "$(instance_port "$id")" \
    --argjson expose "$(expose_port "$id")" \
    --arg mode "warp" \
    --arg netns "$(ns_name "$id")" \
    --arg socks "$(socks_addr "$id")" \
    '{
      id:$id, healthy:$healthy, unique:$unique, pooled:$pooled, exclude_reason:$exclude_reason,
      v4:$v4, v6:$v6, ip:$ip,
      failures:$failures, last_rotate:$last_rotate, pid:$pid,
      collision_streak:$collision_streak, rotate_fail_streak:$rotate_fail_streak,
      port:$port, expose:$expose, mode:$mode, netns:$netns, socks:$socks,
      updated:(now|todate)
    } + (if $drain_restore == "true" then {drain_restore_pooled:true}
         elif $drain_restore == "false" then {drain_restore_pooled:false}
         else {} end)' > "${meta}.tmp"
  mv "${meta}.tmp" "$meta"
}

# Clear rotate lock if older than LOCK_STALE_SEC. No-op if fresh or missing.
clear_stale_rotate_lock() {
  local id="$1"
  local lock="${PID_DIR}/rotate-${id}.lock"
  local now=0 lock_ts=0
  [ -f "$lock" ] || return 0
  if [ "${LOCK_STALE_SEC}" -gt 0 ] 2>/dev/null; then
    now="$(date +%s 2>/dev/null || echo 0)"
    lock_ts="$(cat "${lock}.ts" 2>/dev/null || echo 0)"
    if [ "$now" -gt 0 ] && [ "$lock_ts" -gt 0 ] && \
       [ "$((now - lock_ts))" -ge "${LOCK_STALE_SEC}" ]; then
      err "rotate lock stale id=${id} (age=$((now - lock_ts))s) — cleaning"
      rm -f "$lock" "${lock}.ts" 2>/dev/null || true
    fi
  fi
}

# return 0 = fresh rotate lock present (skip probe/supervise); 1 = free
has_active_rotate_lock() {
  local id="$1"
  clear_stale_rotate_lock "$id"
  [ -f "${PID_DIR}/rotate-${id}.lock" ]
}

# Heal rotate debris only: exclude_reason=="drain" and no active rotate lock.
# Never touches manual / guard-l1 / guard-probe / other reasons.
# Uses drain_restore_pooled written by rotate-instance (default true if missing).
# return 0 if meta was healed; 1 if nothing to do.
heal_stale_rotate_drain() {
  local id="$1"
  local meta reason restore tmp
  meta="$(instance_dir "$id")/meta.json"
  [ -f "$meta" ] || return 1
  if has_active_rotate_lock "$id"; then
    return 1
  fi
  reason="$(jq -r '.exclude_reason // empty' "$meta" 2>/dev/null || true)"
  [ "$reason" = "drain" ] || return 1
  restore="$(jq -r 'if has("drain_restore_pooled") then (if .drain_restore_pooled then "true" else "false" end) else "true" end' "$meta" 2>/dev/null || echo true)"
  tmp="${meta}.tmp.$$"
  if [ "$restore" = "true" ]; then
    jq '.pooled=true | .exclude_reason="" | del(.drain_restore_pooled)' "$meta" >"$tmp" && mv "$tmp" "$meta" || {
      rm -f "$tmp"
      return 1
    }
    log "instance ${id}: heal stale drain → pooled=true (rotate debris)"
  else
    jq '.pooled=false | .exclude_reason="" | del(.drain_restore_pooled)' "$meta" >"$tmp" && mv "$tmp" "$meta" || {
      rm -f "$tmp"
      return 1
    }
    log "instance ${id}: heal stale drain → keep unpooled (prev not pooled)"
  fi
  return 0
}

# log at most once per interval seconds for a key (default 300s)
log_throttled() {
  local key="$1"
  local interval="${2:-${LOG_THROTTLE_SEC:-300}}"
  shift 2
  local f now=0 last=0
  mkdir -p "${PID_DIR}"
  f="${PID_DIR}/log-throttle-${key}.ts"
  now="$(date +%s 2>/dev/null || echo 0)"
  last="$(cat "$f" 2>/dev/null || echo 0)"
  if [ "$now" -gt 0 ] && [ "$last" -gt 0 ] && \
     [ "$((now - last))" -lt "$interval" ] 2>/dev/null; then
    return 0
  fi
  echo "$now" >"$f" 2>/dev/null || true
  log "$@"
}

# return 0 = may enter healthy.json backends; 1 = skip backends
# pooled missing → true; active rotate lock → not eligible
is_pool_eligible() {
  local id="$1"
  local meta pooled
  if has_active_rotate_lock "$id"; then
    return 1
  fi
  meta="$(instance_dir "$id")/meta.json"
  if [ ! -f "$meta" ]; then
    return 0
  fi
  pooled="$(jq -r 'if has("pooled") then (if .pooled then "true" else "false" end) else "true" end' "$meta" 2>/dev/null || echo true)"
  [ "$pooled" = "true" ]
}

meta_set_field() {
  local id="$1" key="$2" val="$3"
  local meta tmp
  meta="$(instance_dir "$id")/meta.json"
  [ -f "$meta" ] || return 1
  tmp="${meta}.tmp.$$"
  jq --arg k "$key" --argjson v "$val" '.[$k]=$v' "$meta" >"$tmp" && mv "$tmp" "$meta" || rm -f "$tmp"
}

# return 0 = auto-rotate allowed; 1 = suppressed (cooldown)
auto_rotate_allowed() {
  local id="$1"
  local f now=0 until=0
  f="${PID_DIR}/rotate-cooldown-${id}.ts"
  [ -f "$f" ] || return 0
  now="$(date +%s 2>/dev/null || echo 0)"
  until="$(cat "$f" 2>/dev/null || echo 0)"
  if [ "$now" -gt 0 ] && [ "$until" -gt 0 ] && [ "$now" -lt "$until" ]; then
    log_throttled "rot-cd-${id}" 300 \
      "instance ${id}: auto-rotate suppressed (cooldown $((until - now))s left)"
    return 1
  fi
  rm -f "$f" 2>/dev/null || true
  return 0
}

mark_rotate_success() {
  local id="$1"
  rm -f "${PID_DIR}/rotate-cooldown-${id}.ts" 2>/dev/null || true
  meta_set_field "$id" rotate_fail_streak 0 2>/dev/null || true
  meta_set_field "$id" collision_streak 0 2>/dev/null || true
}

mark_rotate_fail() {
  local id="$1"
  local meta streak=0 max until
  meta="$(instance_dir "$id")/meta.json"
  if [ -f "$meta" ]; then
    streak="$(jq -r '.rotate_fail_streak // 0' "$meta" 2>/dev/null || echo 0)"
  fi
  streak=$((streak + 1))
  meta_set_field "$id" rotate_fail_streak "$streak" 2>/dev/null || true
  max="${ROTATE_FAIL_STREAK_MAX:-2}"
  if [ "$streak" -ge "$max" ] 2>/dev/null; then
    until=$(( $(date +%s) + ${ROTATE_COOLDOWN_SEC:-1800} ))
    echo "$until" >"${PID_DIR}/rotate-cooldown-${id}.ts" 2>/dev/null || true
    log "instance ${id}: rotate fail streak=${streak} → cooldown ${ROTATE_COOLDOWN_SEC:-1800}s"
  fi
}

# Rebuild healthy.json from meta (alive + healthy + unique + eligible).
# Does not start processes. Clears sticky if target not in backends.
rebuild_healthy_json() {
  local backends_json="[]" id meta healthy unique pooled v4 pidfile pid alive
  local sticky_f sticky_id tmp
  while read -r id; do
    [ -n "$id" ] || continue
    meta="$(instance_dir "$id")/meta.json"
    [ -f "$meta" ] || continue
    if has_active_rotate_lock "$id"; then
      continue
    fi
    healthy="$(jq -r 'if .healthy==true then "true" else "false" end' "$meta" 2>/dev/null || echo false)"
    unique="$(jq -r 'if .unique==true then "true" else "false" end' "$meta" 2>/dev/null || echo false)"
    pooled="$(jq -r 'if has("pooled") then (if .pooled then "true" else "false" end) else "true" end' "$meta" 2>/dev/null || echo true)"
    [ "$healthy" = "true" ] && [ "$unique" = "true" ] && [ "$pooled" = "true" ] || continue
    pidfile="$(pidfile_svc "$id")"
    alive=0
    if [ -f "$pidfile" ]; then
      pid="$(cat "$pidfile" 2>/dev/null || true)"
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        alive=1
      fi
    fi
    [ "$alive" -eq 1 ] || continue
    backends_json="$(echo "$backends_json" | jq -c \
      --argjson id "$id" \
      --arg addr "$(socks_addr "$id")" \
      '. + [{id:$id, addr:$addr}]')"
  done < <(list_instance_ids)

  mkdir -p "${DATA_DIR}/state"
  tmp="${DATA_DIR}/state/healthy.json.tmp.$$"
  if printf '{"backends": %s}\n' "$backends_json" | jq -c . >"$tmp"; then
    mv -f "$tmp" "${DATA_DIR}/state/healthy.json"
  else
    rm -f "$tmp"
    return 1
  fi

  # sticky: drop if target not in backends
  sticky_f="${DATA_DIR}/state/sticky.json"
  if [ -f "$sticky_f" ]; then
    sticky_id="$(jq -r '.id // empty' "$sticky_f" 2>/dev/null || true)"
    if [ -n "$sticky_id" ]; then
      if ! echo "$backends_json" | jq -e --argjson sid "$sticky_id" 'map(.id)|index($sid)!=null' >/dev/null 2>&1; then
        rm -f "$sticky_f"
        log "sticky cleared id=${sticky_id} reason=not-member"
      fi
    fi
  fi
  return 0
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

# return 0 = conflict; 1 = free to claim
# Only peers that ALREADY hold a seat claim block us:
#   healthy==true OR unique==true (and not drain).
# Alive-but-not-seated with same v4 must NOT block — otherwise 3 colliders
# deadlock and nobody sits (first-writer-wins under unique lock).
v4_conflicts() {
  local id="$1"
  local v4="$2"
  local other_dir other_id other_meta other_healthy other_unique other_v4 other_ex
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
    other_v4="$(jq -r '.v4 // .ip // empty' "$other_meta" 2>/dev/null || true)"
    [ -n "$other_v4" ] && [ "$other_v4" = "$v4" ] || continue
    other_ex="$(jq -r '.exclude_reason // empty' "$other_meta" 2>/dev/null || true)"
    [ "$other_ex" = "drain" ] && continue
    other_healthy="$(jq -r '.healthy // false' "$other_meta" 2>/dev/null || echo false)"
    other_unique="$(jq -r '.unique // false' "$other_meta" 2>/dev/null || echo false)"
    if [ "$other_healthy" = "true" ] || [ "$other_unique" = "true" ]; then
      return 0
    fi
  done
  return 1
}

LOCK_STALE_SEC="${LOCK_STALE_SEC:-300}"

acquire_unique_lock() {
  local lock="${PID_DIR}/v4-unique.lock"
  local timeout="${1:-$V4_UNIQUE_LOCK_TIMEOUT}"
  local elapsed=0 now=0
  mkdir -p "${PID_DIR}"
  # 兜底：检查是否残留锁（ts 超过 LOCK_STALE_SEC 自动清理）
  if [ -d "$lock" ] && [ "${LOCK_STALE_SEC}" -gt 0 ] 2>/dev/null; then
    local lock_ts=0
    now="$(date +%s 2>/dev/null || echo 0)"
    lock_ts="$(cat "${lock}/ts" 2>/dev/null || echo 0)"
    if [ "$now" -gt 0 ] && [ "$lock_ts" -gt 0 ] && \
       [ "$((now - lock_ts))" -ge "${LOCK_STALE_SEC}" ]; then
      err "v4 unique lock stale (${lock_ts} ts, ${now} now) — cleaning"
      rm -rf "$lock"
    fi
  fi
  while ! mkdir "$lock" 2>/dev/null; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [ "$elapsed" -ge "$timeout" ]; then
      err "v4 unique lock timeout (${timeout}s)"
      return 1
    fi
    # 等待期间也检查锁是否变 stale（防止死锁期间另一进程挂掉）
    if [ -d "$lock" ] && [ "${LOCK_STALE_SEC}" -gt 0 ] 2>/dev/null; then
      local wait_ts=0
      wait_ts="$(cat "${lock}/ts" 2>/dev/null || echo 0)"
      if [ "$now" -gt 0 ] && [ "$wait_ts" -gt 0 ] && \
         [ "$((now - wait_ts))" -ge "${LOCK_STALE_SEC}" ]; then
        err "v4 unique lock stale during wait (${wait_ts}) — cleaning"
        rm -rf "$lock"
      fi
    fi
  done
  echo $$ > "${lock}/pid" 2>/dev/null || true
  date +%s > "${lock}/ts" 2>/dev/null || true
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

# v0.6: one-shot seat try — NO restart/hard thrash (boot/health must not互踢)
# return 0 if seated; 1 otherwise. echoes v4 on success.
ensure_instance_unique() {
  local id="$1"
  local ip="" pid
  if [ "${V4_UNIQUE}" = "0" ]; then
    if ip="$(probe_instance "$id")"; then
      write_meta "$id" true "$ip" 0 "" "$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)" "" true
      printf '%s\n' "$ip"
      return 0
    fi
    return 1
  fi
  if ! ip="$(probe_instance "$id")"; then
    return 1
  fi
  pid="$(cat "$(pidfile_svc "$id")" 2>/dev/null || true)"
  if commit_if_unique "$id" "$ip" 0 "" "$pid"; then
    log "seat grant id=${id} ip=${ip}"
    # stdout: IP only (for capture); message already on stderr via log
    printf '%s\n' "$ip"
    return 0
  fi
  write_meta "$id" false "$ip" 0 "" "$pid" "" false
  meta_set_field "$id" collision_streak 1 2>/dev/null || true
  log "seat deny id=${id} ip=${ip} reason=v4_collision"
  return 1
}

# return 0 if id is currently a seat (in backends or meta healthy+unique+alive)
is_seated() {
  local id="$1"
  local meta pidfile pid hf
  hf="${DATA_DIR}/state/healthy.json"
  if [ -f "$hf" ] && jq -e --argjson sid "$id" '.backends|map(.id)|index($sid)!=null' "$hf" >/dev/null 2>&1; then
    return 0
  fi
  meta="$(instance_dir "$id")/meta.json"
  [ -f "$meta" ] || return 1
  jq -e '.healthy==true and .unique==true' "$meta" >/dev/null 2>&1 || return 1
  pidfile="$(pidfile_svc "$id")"
  [ -f "$pidfile" ] || return 1
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
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
