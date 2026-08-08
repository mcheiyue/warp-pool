#!/usr/bin/env bash
# smoke-pool.sh — P0/P1 acceptance for aggregate pool (v0.5)
# Usage:
#   CONTROL_URL=http://127.0.0.1:9090 CONTROL_TOKEN=xxx ./tests/smoke-pool.sh
#   SKIP_SOCKS=1              → API-only (no live socks curls)
#   AGG_SOCKS=127.0.0.1:1080  → socks endpoint for optional live checks
set -euo pipefail

BASE="${CONTROL_URL:-http://127.0.0.1:9090}"
TOK="${CONTROL_TOKEN:-}"
AGG_SOCKS="${AGG_SOCKS:-127.0.0.1:1080}"
SKIP_SOCKS="${SKIP_SOCKS:-0}"

qs() { [ -n "$TOK" ] && echo "?token=${TOK}" || echo ""; }

api() {
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -fsS -X "$method" "${BASE}${path}$(qs)" \
      -H "Content-Type: application/json" -d "$body"
  else
    curl -fsS -X "$method" "${BASE}${path}$(qs)"
  fi
}

# normalize pool.members → bare id array (handles number[] or {id}[])
member_ids() {
  jq -c '(.members // []) | map(if type=="number" then . else .id end)' "$1"
}

socks_sample() {
  [ "$SKIP_SOCKS" = "1" ] && return 0
  local i
  for i in 1 2 3; do
    curl -4 --max-time 8 --socks5-hostname "$AGG_SOCKS" \
      https://1.1.1.1/cdn-cgi/trace 2>/dev/null | grep '^ip=' | head -1 || true
  done
}

echo "== health =="
api GET /health | tee /tmp/wp-health.json
echo
echo "== instances =="
api GET /instances | tee /tmp/wp-inst.json
echo
echo "== pool =="
api GET /pool | tee /tmp/wp-pool.json
echo

n="$(jq 'length' /tmp/wp-inst.json)"
ok="$(jq '[.[]|select(.healthy==true)]|length' /tmp/wp-inst.json)"
members0="$(member_ids /tmp/wp-pool.json | jq 'length')"
echo "instances=$n healthy=$ok pool_members=$members0"
[ "$ok" -ge 1 ] || { echo "FAIL no healthy instance"; exit 1; }
[ "$members0" -ge 1 ] || { echo "FAIL pool has no members"; exit 1; }

# --- unpool / pool (needs ≥2 instances) ---
if [ "$n" -ge 2 ]; then
  uid="$(jq -r 'map(.id) | max' /tmp/wp-inst.json)"
  echo "== unpool id=${uid} =="
  api POST /pool/membership "{\"id\":${uid},\"pooled\":false}" | tee /tmp/wp-unpool.json
  sleep 3
  api GET /pool | tee /tmp/wp-pool-after-unpool.json
  api GET /instances | tee /tmp/wp-inst-after-unpool.json
  echo "members after unpool: $(member_ids /tmp/wp-pool-after-unpool.json)"
  member_ids /tmp/wp-pool-after-unpool.json | jq -e --argjson id "$uid" 'index($id) == null' >/dev/null \
    || { echo "FAIL unpooled id=${uid} still in members"; exit 1; }
  jq -e --argjson id "$uid" '.[] | select(.id==$id) | .pooled==false' /tmp/wp-inst-after-unpool.json >/dev/null \
    || { echo "FAIL instance ${uid} pooled!=false"; exit 1; }
  socks_sample

  echo "== pool back id=${uid} =="
  api POST /pool/membership "{\"id\":${uid},\"pooled\":true}" | tee /tmp/wp-pool-back.json
  sleep 3
  api GET /pool | tee /tmp/wp-pool-restored.json
  members1="$(member_ids /tmp/wp-pool-restored.json | jq 'length')"
  echo "pool_members restored=$members1 (was $members0)"
  [ "$members1" -ge "$members0" ] || { echo "FAIL members not restored"; exit 1; }
  member_ids /tmp/wp-pool-restored.json | jq -e --argjson id "$uid" 'index($id) != null' >/dev/null \
    || { echo "FAIL id=${uid} missing after pool-back"; exit 1; }
  socks_sample
else
  echo "SKIP unpool/pool (need ≥2 instances, have $n)"
fi

# --- sticky ---
pool_src=/tmp/wp-pool.json
[ -f /tmp/wp-pool-restored.json ] && pool_src=/tmp/wp-pool-restored.json
sid="$(member_ids "$pool_src" | jq -r '.[0] // 0')"
echo "== sticky id=${sid} =="
api POST /pool/sticky "{\"id\":${sid}}" | tee /tmp/wp-sticky.json
sleep 1
api GET /pool | tee /tmp/wp-pool-sticky.json
# accept sticky as bare id, object, or sticky_id field
jq -e --argjson id "$sid" '
  .sticky == $id
  or .sticky_id == $id
  or (.sticky | type=="object" and .id==$id)
  or (.sticky != null and .sticky != "")
' /tmp/wp-pool-sticky.json >/dev/null \
  || { echo "FAIL sticky not set"; cat /tmp/wp-pool-sticky.json; exit 1; }
socks_sample

echo "== clear sticky =="
api DELETE /pool/sticky | tee /tmp/wp-sticky-del.json
sleep 1
api GET /pool | tee /tmp/wp-pool-nosticky.json
st="$(jq -r 'if has("sticky") then (.sticky|tostring) elif has("sticky_id") then (.sticky_id|tostring) else "null" end' /tmp/wp-pool-nosticky.json)"
case "$st" in
  null|""|"{}") ;;
  *) echo "FAIL sticky still set: $st"; exit 1 ;;
esac

echo "SMOKE_POOL_OK"
