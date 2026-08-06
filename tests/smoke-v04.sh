#!/usr/bin/env bash
# Minimal v0.4 API contract checks (run against control URL with token).
# Usage: CONTROL_URL=http://127.0.0.1:19090 CONTROL_TOKEN=xxx ./tests/smoke-v04.sh
set -euo pipefail
BASE="${CONTROL_URL:-http://127.0.0.1:9090}"
TOK="${CONTROL_TOKEN:-}"
qs() { [ -n "$TOK" ] && echo "?token=${TOK}" || echo ""; }
aq() { [ -n "$TOK" ] && echo "&token=${TOK}" || echo ""; }

echo "== health =="
curl -fsS "${BASE}/health$(qs sp)" | tee /tmp/wp-health.json
echo
echo "== instances =="
curl -fsS "${BASE}/instances$(qs)" | tee /tmp/wp-inst.json
echo
echo "== config =="
curl -fsS "${BASE}/config$(qs)" | tee /tmp/wp-cfg.json
echo
n="$(jq 'length' /tmp/wp-inst.json)"
ok="$(jq '[.[]|select(.healthy==true)]|length' /tmp/wp-inst.json)"
echo "instances=$n healthy=$ok"
[ "$ok" -ge 1 ] || { echo "FAIL no healthy"; exit 1; }
v4s="$(jq -r '[.[]|select(.healthy==true)|.v4//empty]|join(" ")' /tmp/wp-inst.json)"
echo "v4s: $v4s"
# uniqueness among healthy
uniq="$(jq -r '[.[]|select(.healthy==true)|.v4//empty]|unique|length' /tmp/wp-inst.json)"
hcount="$(jq -r '[.[]|select(.healthy==true)|select(.v4!=null and .v4!="")]|length' /tmp/wp-inst.json)"
if [ "$hcount" -ge 2 ] && [ "$uniq" -lt "$hcount" ]; then
  echo "WARN healthy v4 not all unique (CF may collide; uniqueness retries on rotate)"
fi
echo "SMOKE_V04_API_OK"
