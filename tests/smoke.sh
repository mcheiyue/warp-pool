#!/usr/bin/env bash
# Host-side smoke against a running warp-pool (ports on localhost)
set -euo pipefail

BASE_PORT="${INSTANCE_PORT_BASE:-11000}"
N="${WARP_INSTANCES:-1}"
AGG="${AGG_SOCKS_PORT:-1080}"

echo "== smoke direct ports =="
for ((i = 0; i < N; i++)); do
  p=$((BASE_PORT + i))
  echo "-- port $p"
  out="$(curl -fsS --max-time 20 --socks5-hostname "127.0.0.1:${p}" https://cloudflare.com/cdn-cgi/trace || true)"
  echo "$out" | grep -E '^(ip|warp|colo)=' || true
  echo "$out" | grep -qE 'warp=(on|plus)' || { echo "FAIL port $p"; exit 1; }
done

if [ "${SKIP_AGG:-0}" != "1" ]; then
  echo "== smoke aggregate :${AGG} =="
  declare -A seen=()
  for k in $(seq 1 12); do
    ip="$(curl -fsS --max-time 15 --socks5-hostname "127.0.0.1:${AGG}" https://cloudflare.com/cdn-cgi/trace | grep '^ip=' | cut -d= -f2 || true)"
    echo "sample $k ip=$ip"
    [ -n "$ip" ] && seen["$ip"]=1
  done
  echo "unique exit ips: ${#seen[@]}"
fi

echo "OK"
