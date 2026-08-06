# STATUS — warp-pool

**Primary track: v0.3 (Warp + netns + WebUI)**  
Date: 2026-08-06

## Done

- [x] G0 netns×2 Warp probe — PASS (`docs/probe-warp-netns.md`)
- [x] Core scripts: netns/veth, start/stop/rotate(restart|hard), health, entrypoint
- [x] Dockerfile: root, cloudflare-warp, iproute2, iptables, gost, web; **privileged** required
- [x] warppool API: `/instances` `/rotate` `/health` `/healthcheck` `/ui` (rotate default=restart; file-log exec avoids pipe hang)
- [x] `web/index.html` single page
- [x] compose privileged + sysctls; `.env.example`; ADR-015 Accepted
- [x] `tests/smoke-v03.sh`
- [x] **VPS side-car smoke** `warp-pool:v0.3-local` as `warp-pool-v03`:
  - ports 19080 / 19100 / 19101 / 19090
  - boot N=2 healthy, v4 diverse, aggregate OK
  - `POST /rotate?id=0` returns `ok`, v4 changes, peer stable
  - RSS ~240MiB (N=2)

## Not done

- [ ] Push GHCR `latest` as v0.3 (needs git commit + Actions or manual push)
- [ ] Long soak / N>2
- [ ] Drop `privileged` to minimal caps if possible later

## Superseded

- v0.2 WarpProxy multi tunnel path
- v0.1 B1 wgcf+wireproxy

## Ops

- IPv4: `curl -4 --socks5-hostname … https://ipv4.icanhazip.com`
- Side-car 19xxx; do not steal warp-chen `:1080`
- `ROTATE_COOLDOWN` default 300; smoke used 0
