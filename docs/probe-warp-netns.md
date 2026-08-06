# G0 Probe: Warp mode × netns × 2 (in one container)

Date: 2026-08-06  
Host: VPS side-car (did not touch `warp-chen` :1080)  
Image: `caomingjun/warp:latest` (throwaway privileged container)  
Script: `scripts/probe-netns-warp.sh` (host wrapper; inner logic validated as G0 v2)

## Result: **PASS**

| Check | Result |
|-------|--------|
| Dual netns boot (wp0, wp1) + veth/NAT | OK |
| Warp mode Connected + CloudflareWARP iface in each ns | OK |
| IPv4 diversity (`curl -4` → ipv4.icanhazip.com) | **PASS** |
| Restart **wp0 only** (exact `warp-svc` PID; no pkill) | **PASS** — wp0 v4 changed; wp1 unchanged |

### Measured IPs

```
G0_V4_WP0_BEFORE=104.28.164.111
G0_V4_WP1_BEFORE=104.28.165.57
G0_DIVERSE=1
G0_V4_WP0_AFTER=104.28.152.116
G0_V4_WP1_AFTER=104.28.165.57
G0_WP0_CHANGED=1
G0_PEER_SAME=1
G0_PEER_ALIVE=1
G0_RESULT=PASS
```

## Method (minimal)

1. One privileged container: `NET` + `/dev/net/tun`, root.
2. `ip netns add wp0 wp1`; veth pair per ns; host `10.200.{0,1}.1`, ns `.2`; MASQUERADE `10.200.0.0/16`.
3. Per ns: isolated dbus socket + `warp-svc` with `STATE_DIRECTORY=/var/lib/cloudflare-warp-$ns` + `warp-cli mode warp` + `connect`.
4. Probe: `ip netns exec $ns curl -4 https://ipv4.icanhazip.com` (not cdn-cgi/trace alone — prefer forced v4).
5. Rotate simulation: `kill` **only** that instance’s `warp-svc` PID → start again → `mode warp` → `connect`. **Never `pkill warp-svc`** (hits sibling ns).

## Failures observed (fixed in v2)

- v1 used `pkill` inside ns and killed wp1’s `warp-svc` → peer probe failed after “restart”.
- Status may lag; Connected + CloudflareWARP + curl v4 is the source of truth.

## Implications for v0.3

- Single-container **Warp + netns** path is unblocked.
- rotate default = restart instance (exact PID / per-ns stop).
- Expose path: SOCKS (e.g. gost) **inside** each ns; host reaches via veth IP `10.200.X.2:port` or nsenter relay; warppool aggregate/control stay in main ns.
- Caps: `NET_ADMIN` / privileged-class + tun required (v0.2 “no cap” narrative obsolete).
- resolve1/systemd dbus helpers warn harmlessly without full systemd.

## Out of scope for G0

- warppool API/UI, GHCR image, production compose hardening, multi-N>2 soak.
