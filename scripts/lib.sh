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
GOST_BIN="${GOST_BIN:-gost}"

log() { echo "==> [warp-pool] $*"; }
err() { echo "==> [warp-pool][ERROR] $*" >&2; }

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

write_meta() {
  local id="$1"
  local healthy="${2:-false}"
  local v4="${3:-}"
  local failures="${4:-0}"
  local last_rotate="${5:-}"
  local pid="${6:-}"
  local v6="${7:-}"
  local dir meta
  dir="$(instance_dir "$id")"
  mkdir -p "$dir"
  meta="${dir}/meta.json"
  jq -n \
    --argjson id "$id" \
    --argjson healthy "$healthy" \
    --arg v4 "$v4" \
    --arg v6 "$v6" \
    --arg ip "$v4" \
    --argjson failures "$failures" \
    --arg last_rotate "$last_rotate" \
    --arg pid "$pid" \
    --argjson port "$(instance_port "$id")" \
    --argjson expose "$(expose_port "$id")" \
    --arg mode "warp" \
    --arg netns "$(ns_name "$id")" \
    --arg socks "$(socks_addr "$id")" \
    '{
      id:$id, healthy:$healthy, v4:$v4, v6:$v6, ip:$ip,
      failures:$failures, last_rotate:$last_rotate, pid:$pid,
      port:$port, expose:$expose, mode:$mode, netns:$netns, socks:$socks,
      updated:(now|todate)
    }' > "${meta}.tmp"
  mv "${meta}.tmp" "$meta"
}

# Probe via in-ns SOCKS (gost); force IPv4 for pool health
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
