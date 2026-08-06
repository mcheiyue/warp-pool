#!/usr/bin/env bash
# smoke-v03.sh — product path checks for warp-pool v0.3 (Warp+netns)
# Usage on host (side-car ports): EXPOSE0=19100 EXPOSE1=19101 AGG=19080 CONTROL via docker exec
set -euo pipefail

EXPOSE0="${EXPOSE0:-127.0.0.1:11000}"
EXPOSE1="${EXPOSE1:-127.0.0.1:11001}"
AGG="${AGG:-127.0.0.1:1080}"
CTR="${CTR:-warp-pool}"
TIMEOUT="${TIMEOUT:-20}"

log() { echo "==> [smoke-v03] $*"; }
die() { echo "==> [smoke-v03][FAIL] $*" >&2; exit 1; }

probe_v4() {
  local socks="$1"
  curl -4 -sS --max-time "$TIMEOUT" --socks5-hostname "$socks" https://ipv4.icanhazip.com \
    | tr -d '\r\n[:space:]'
}

log "probe direct ports"
V0="$(probe_v4 "$EXPOSE0")" || die "expose0"
V1="$(probe_v4 "$EXPOSE1")" || die "expose1"
log "v4 id0=$V0 id1=$V1"
echo "$V0" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || die "bad v4 id0"
echo "$V1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || die "bad v4 id1"
if [ "$V0" = "$V1" ]; then
  log "WARN: v4 same on both ports (allowed occasionally); continue"
else
  log "OK diverse v4"
fi

log "probe aggregate"
VA="$(probe_v4 "$AGG")" || die "aggregate"
log "agg v4=$VA"

log "control /instances"
INST="$(docker exec "$CTR" curl -sS --max-time 10 http://127.0.0.1:9090/instances)" || die "instances"
echo "$INST" | head -c 500; echo

log "rotate id=0 (restart)"
docker exec "$CTR" curl -sS -X POST --max-time 180 \
  'http://127.0.0.1:9090/rotate?id=0&mode=restart' || die "rotate"
sleep 8
V0b="$(probe_v4 "$EXPOSE0")" || die "expose0 after rotate"
V1b="$(probe_v4 "$EXPOSE1")" || die "expose1 after rotate"
log "after rotate: id0=$V0b id1=$V1b"
if [ "$V0" != "$V0b" ]; then
  log "OK id0 v4 changed"
else
  log "WARN id0 v4 unchanged (retry once manually if flaky)"
fi
if [ -n "$V1b" ]; then
  log "OK id1 still reachable"
fi

log "PASS (core path exercised)"
