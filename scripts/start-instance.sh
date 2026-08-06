#!/usr/bin/env bash
# start-instance.sh <id> — Warp mode inside netns + gost SOCKS + optional expose
set -euo pipefail
source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

id="${1:?usage: start-instance.sh <id>}"
port="$(instance_port "$id")"
state="$(instance_state_dir "$id")"
run="$(instance_run_dir "$id")"
dbus_dir="$(instance_dbus_dir "$id")"
dbus_sock="${dbus_dir}/system_bus_socket"
pf_svc="$(pidfile_svc "$id")"
pf_dbus="$(pidfile_dbus "$id")"
pf_gost="$(pidfile_gost "$id")"
pf_exp="$(pidfile_expose "$id")"

ensure_host_forward
ensure_dirs "$id"
ensure_netns "$id"

if [ -f "$pf_svc" ]; then
  old="$(cat "$pf_svc" || true)"
  if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
    log "instance ${id}: warp-svc already running pid=${old}"
  else
    rm -f "$pf_svc"
  fi
fi

# dbus in netns
if [ ! -S "$dbus_sock" ]; then
  rm -f "${dbus_dir}/pid" 2>/dev/null || true
  ns_exec "$id" bash -c "
    dbus-daemon --address='unix:path=${dbus_sock}' \
      --config-file=/usr/share/dbus-1/system.conf --nopidfile --nofork &
    echo \$! > '$pf_dbus'
  "
  sleep 1
fi

if [ ! -f "$pf_svc" ] || ! kill -0 "$(cat "$pf_svc" 2>/dev/null || echo 0)" 2>/dev/null; then
  log "instance ${id}: starting warp-svc in netns $(ns_name "$id")"
  # write REAL warp-svc pid from inside ns (not ip-netns-exec wrapper)
  ns_exec "$id" bash -c "
    env STATE_DIRECTORY='$state' RUNTIME_DIRECTORY='$run' \
      DBUS_SYSTEM_BUS_ADDRESS='unix:path=${dbus_sock}' \
      warp-svc --accept-tos >/tmp/warp-svc-${id}.log 2>&1 &
    echo \$! > '$pf_svc'
  "
  sleep 3
fi

if ! wait_daemon_ready "$id" "$WARP_CONNECT_TIMEOUT"; then
  log "instance ${id}: daemon not Connected yet (continue register/connect)"
fi

if [ ! -f "${state}/reg.json" ] && ! find "$state" -name 'reg.json' 2>/dev/null | grep -q .; then
  log "instance ${id}: registration new"
  reg_ok=0
  for attempt in 1 2 3 4 5 6; do
    if wcli "$id" registration new 2>/dev/null; then
      reg_ok=1
      break
    fi
    sleep $((attempt * 2 + RANDOM % 2))
  done
  if [ "$reg_ok" -ne 1 ]; then
    err "instance ${id}: registration failed"
    tail -30 /tmp/warp-svc-"${id}".log 2>/dev/null || true
    exit 1
  fi
  if [ -n "${WARP_LICENSE_KEY:-${LICENSE_KEY:-}}" ]; then
    wcli "$id" registration license "${WARP_LICENSE_KEY:-$LICENSE_KEY}" 2>/dev/null || true
  fi
fi

wcli "$id" mode warp
wcli "$id" connect
wcli "$id" debug qlog disable 2>/dev/null || true
wait_daemon_ready "$id" 90 || log "instance ${id}: still not Connected (probe will decide)"

# gost SOCKS inside ns — traffic follows CloudflareWARP default route
if [ -f "$pf_gost" ]; then
  gpid="$(cat "$pf_gost" || true)"
  if [ -n "$gpid" ] && kill -0 "$gpid" 2>/dev/null; then
    kill "$gpid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$pf_gost"
fi
log "instance ${id}: gost socks5 0.0.0.0:${port} in ns (reach via $(socks_addr "$id"))"
ns_exec "$id" bash -c "
  '$GOST_BIN' -L 'socks5://0.0.0.0:${port}' >/tmp/gost-${id}.log 2>&1 &
  echo \$! > '$pf_gost'
"
sleep 1

# expose host 0.0.0.0:11000+id -> ns peer socks
if [ "${ENABLE_EXPOSE:-1}" = "1" ]; then
  exp="$(expose_port "$id")"
  if [ -f "$pf_exp" ]; then
    old_exp="$(cat "$pf_exp" || true)"
    if [ -n "$old_exp" ] && kill -0 "$old_exp" 2>/dev/null; then
      kill "$old_exp" 2>/dev/null || true
      sleep 1
    fi
    rm -f "$pf_exp"
  fi
  log "instance ${id}: expose 0.0.0.0:${exp} -> $(socks_addr "$id")"
  # must redirect stdio — otherwise parent CombinedOutput (control /rotate) hangs
  warppool expose --listen "0.0.0.0:${exp}" --backend "$(socks_addr "$id")" \
    </dev/null >/tmp/expose-"${id}".log 2>&1 &
  echo $! > "$pf_exp"
  disown $! 2>/dev/null || true
fi

log "instance ${id}: warp+gost up pid=$(cat "$pf_svc") socks=$(socks_addr "$id")"
