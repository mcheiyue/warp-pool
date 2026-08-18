#!/usr/bin/env bash
# start-instance.sh <id> — Warp mode inside netns + SOCKS (microsocks|gost) + optional expose
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

_warp_svc_alive() {
  local p
  p="$(cat "$pf_svc" 2>/dev/null || true)"
  [ -n "$p" ] && kill -0 "$p" 2>/dev/null
}

# 清残留 IPC，避免 "Unix socket already bound" 秒退
_clean_warp_runtime() {
  rm -f "${run}/warp_service" 2>/dev/null || true
  if [ -d "$run" ]; then
    find "$run" -maxdepth 1 -type s -delete 2>/dev/null || true
  fi
}

if _warp_svc_alive; then
  log "instance ${id}: warp-svc already running pid=$(cat "$pf_svc")"
else
  rm -f "$pf_svc"
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

_start_warp_svc_once() {
  log "instance ${id}: starting warp-svc in netns $(ns_name "$id")"
  _clean_warp_runtime
  # write REAL warp-svc pid from inside ns (not ip-netns-exec wrapper)
  ns_exec "$id" bash -c "
    env STATE_DIRECTORY='$state' RUNTIME_DIRECTORY='$run' \
      DBUS_SYSTEM_BUS_ADDRESS='unix:path=${dbus_sock}' \
      warp-svc --accept-tos >/tmp/warp-svc-${id}.log 2>&1 &
    echo \$! > '$pf_svc'
  "
  sleep 3
}

if ! _warp_svc_alive; then
  _start_warp_svc_once
  # 秒退（socket 占坑等）：再 stop 清一次后重试
  if ! _warp_svc_alive; then
    log "instance ${id}: warp-svc died after start — clean runtime and retry"
    tail -20 /tmp/warp-svc-"${id}".log 2>/dev/null || true
    tail -20 "${state}/cfwarp_service_log.txt" 2>/dev/null || true
    bash "${SCRIPTS_DIR}/stop-instance.sh" "$id" || true
    # stop 可能拆 dbus；重建
    if [ ! -S "$dbus_sock" ]; then
      ns_exec "$id" bash -c "
        dbus-daemon --address='unix:path=${dbus_sock}' \
          --config-file=/usr/share/dbus-1/system.conf --nopidfile --nofork &
        echo \$! > '$pf_dbus'
      "
      sleep 1
    fi
    _start_warp_svc_once
  fi
  if ! _warp_svc_alive; then
    err "instance ${id}: warp-svc failed to stay up"
    tail -40 /tmp/warp-svc-"${id}".log 2>/dev/null || true
    tail -40 "${state}/cfwarp_service_log.txt" 2>/dev/null || true
    exit 1
  fi
fi

if ! wait_daemon_ready "$id" "$WARP_CONNECT_TIMEOUT"; then
  log "instance ${id}: daemon not Connected yet (continue register/connect)"
fi

# Official client stores registration in warp.db / daemon — not necessarily reg.json.
# "registration new" while already registered returns "Old registration is still around".
has_warp_registration() {
  wcli "$id" registration show 2>/dev/null | grep -qi "Account type"
}

if has_warp_registration; then
  log "instance ${id}: registration already present — reuse"
else
  log "instance ${id}: registration new"
  reg_ok=0
  for attempt in 1 2 3 4 5 6; do
    if wcli "$id" registration new 2>/dev/null; then
      reg_ok=1
      break
    fi
    # new failed: either still registered, or transient — prefer reuse over hard fail
    if has_warp_registration; then
      log "instance ${id}: registration present after new failure — reuse"
      reg_ok=1
      break
    fi
    wcli "$id" registration delete 2>/dev/null || true
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

# SOCKS inside ns — traffic follows CloudflareWARP default route
# Prefer microsocks if present (SOCKS_BIN=microsocks); else gost
if [ -f "$pf_gost" ]; then
  gpid="$(cat "$pf_gost" || true)"
  if [ -n "$gpid" ] && kill -0 "$gpid" 2>/dev/null; then
    kill "$gpid" 2>/dev/null || true
    sleep 1
  fi
  rm -f "$pf_gost"
fi
if command -v microsocks >/dev/null 2>&1; then
  log "instance ${id}: microsocks 0.0.0.0:${port} in ns (reach via $(socks_addr "$id"))"
  ns_exec "$id" bash -c "
    microsocks -i 0.0.0.0 -p ${port} >/tmp/microsocks-${id}.log 2>&1 &
    echo \$! > '$pf_gost'
  "
else
  log "instance ${id}: gost socks5 0.0.0.0:${port} in ns (reach via $(socks_addr "$id"))"
  ns_exec "$id" bash -c "
    '${GOST_BIN}' -L 'socks5://0.0.0.0:${port}' >/tmp/gost-${id}.log 2>&1 &
    echo \$! > '$pf_gost'
  "
fi
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

if ! _warp_svc_alive; then
  err "instance ${id}: warp-svc died before ready (socks up aborted)"
  tail -40 /tmp/warp-svc-"${id}".log 2>/dev/null || true
  tail -40 "${state}/cfwarp_service_log.txt" 2>/dev/null || true
  exit 1
fi
log "instance ${id}: warp+socks up pid=$(cat "$pf_svc") socks=$(socks_addr "$id")"
