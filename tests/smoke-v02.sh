#!/usr/bin/env bash
# VPS side-car smoke for v0.2 (does NOT bind host :1080).
# Usage on host with docker: bash tests/smoke-v02.sh [image]
set -euo pipefail

IMG="${1:-ghcr.io/mcheiyue/warp-pool:v0.2-official}"
NAME=warp-pool-smoke
AGG=19080
P0=19400
P1=19401

log() { echo "[smoke-v02] $*"; }

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker volume rm "${NAME}-data" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
log "pull/run $IMG"
docker pull "$IMG" || true

docker run -d --name "$NAME" --restart=no \
  -e WARP_INSTANCES=2 \
  -e INSTANCE_PORT_BASE=40000 \
  -e BOOT_HEALTH_WAIT=120 \
  -e ROTATE_COOLDOWN=5 \
  -p 127.0.0.1:${AGG}:1080 \
  -p 127.0.0.1:${P0}:40000 \
  -p 127.0.0.1:${P1}:40001 \
  -v "${NAME}-data:/data" \
  "$IMG"

log "wait ready (max 240s)"
ok=0
for i in $(seq 1 80); do
  if curl -sS --max-time 8 --socks5-hostname 127.0.0.1:${P0} https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -qE 'warp=(on|plus)'; then
    if curl -sS --max-time 8 --socks5-hostname 127.0.0.1:${P1} https://cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -qE 'warp=(on|plus)'; then
      ok=1
      log "both directs up after ~$((i*3))s"
      break
    fi
  fi
  sleep 3
done
if [ "$ok" != 1 ]; then
  log "FAIL: directs not ready"
  docker logs "$NAME" 2>&1 | tail -80
  exit 1
fi

trace() {
  curl -sS --max-time 20 --socks5-hostname "$1" https://cloudflare.com/cdn-cgi/trace 2>/dev/null || true
}

ip_of() { echo "$1" | awk -F= '/^ip=/{print $2}'; }

T0=$(trace 127.0.0.1:${P0})
T1=$(trace 127.0.0.1:${P1})
IP0=$(ip_of "$T0")
IP1=$(ip_of "$T1")
log "direct0 ip=${IP0:-?} warp=$(echo "$T0" | awk -F= '/^warp=/{print $2}')"
log "direct1 ip=${IP1:-?} warp=$(echo "$T1" | awk -F= '/^warp=/{print $2}')"
if [ -n "$IP0" ] && [ -n "$IP1" ] && [ "$IP0" != "$IP1" ]; then
  log "IP_DIVERSITY=yes"
else
  log "IP_DIVERSITY=no_or_unknown (soft)"
fi

AG_OK=0
for n in 1 2 3 4; do
  if trace 127.0.0.1:${AGG} | grep -qE 'warp=(on|plus)'; then
    AG_OK=1
    break
  fi
  sleep 2
done
[ "$AG_OK" = 1 ] || { log "FAIL: aggregate"; exit 1; }
log "aggregate ok"

MEM=$(docker stats --no-stream --format '{{.MemUsage}}' "$NAME" | awk '{print $1}')
log "mem=$MEM"
# rough parse MiB
MEM_NUM=$(echo "$MEM" | sed 's/MiB//' | sed 's/GiB/*1024/' | bc 2>/dev/null || echo 0)
# if bc missing, skip hard fail on mem
docker stats --no-stream "$NAME"

BEFORE=$IP0
docker exec "$NAME" curl -sS -X POST 'http://127.0.0.1:9090/rotate?id=0&mode=reconnect' || true
sleep 8
AFTER=$(ip_of "$(trace 127.0.0.1:${P0})")
log "rotate reconnect before=${BEFORE:-?} after=${AFTER:-?}"
if [ -n "$BEFORE" ] && [ -n "$AFTER" ] && [ "$BEFORE" != "$AFTER" ]; then
  log "ROTATE_IP_CHANGED=yes"
else
  log "ROTATE_IP_CHANGED=no_try_hard"
  docker exec "$NAME" curl -sS -X POST 'http://127.0.0.1:9090/rotate?id=0&mode=hard' || true
  sleep 10
  AFTER2=$(ip_of "$(trace 127.0.0.1:${P0})")
  log "rotate hard after=${AFTER2:-?}"
fi

# still warp on
trace 127.0.0.1:${P0} | grep -qE 'warp=(on|plus)'
trace 127.0.0.1:${AGG} | grep -qE 'warp=(on|plus)'

log "PASS"
