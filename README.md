# warp-pool

One Docker container. Multiple independent Cloudflare WARP exits (**Warp mode**, one **netns** each). Port-direct or in-container SOCKS RR. Rotate one instance (restart) without killing the pool. Single-page WebUI on the control port.

**v0.4 (primary track):** hardening + hot config + v4 uniqueness — plan [docs/pivot-v0.4.md](./docs/pivot-v0.4.md).  
**v0.3 (shipped baseline):** Warp × netns + gost SOCKS + warppool + `/ui/` — IPv4 diversity + rotate-by-restart (G0 proven).  
**v0.2:** proxy multi — superseded (pool OK, IPv4 rotate weak).  
**v0.1 B1:** wgcf+wireproxy — deprecated.

Image: **`ghcr.io/mcheiyue/warp-pool:latest`** (publish via CI/manual after commit; local tags e.g. `v0.3-local` used for smoke).

## Quick start

```bash
docker run -d --name warp-pool --restart unless-stopped \
  --privileged \
  --device /dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  -e WARP_INSTANCES=2 \
  -v warp-pool-data:/data \
  -p 127.0.0.1:1080:1080 \
  -p 127.0.0.1:11000-11001:11000-11001 \
  ghcr.io/mcheiyue/warp-pool:latest
```

Or: `.env.example` → `.env`, `docker compose up -d`.

### Smoke

```bash
# force IPv4
curl -4 --socks5-hostname 127.0.0.1:11000 https://ipv4.icanhazip.com
curl -4 --socks5-hostname 127.0.0.1:11001 https://ipv4.icanhazip.com
curl -4 --socks5-hostname 127.0.0.1:1080  https://ipv4.icanhazip.com

docker exec warp-pool curl -s http://127.0.0.1:9090/instances
docker exec warp-pool curl -s -X POST 'http://127.0.0.1:9090/rotate?id=0&mode=restart'
# UI (from inside / published control): http://127.0.0.1:9090/ui/
```

`tests/smoke-v03.sh` automates the above (set `EXPOSE0`/`EXPOSE1`/`AGG`/`CTR`).

### Notes

- **Needs** `NET_ADMIN`, `SYS_ADMIN`, `/dev/net/tun` (not the old “no cap” proxy story).
- Control API default `127.0.0.1:9090`; non-loopback bind requires `CONTROL_TOKEN`.
- Memory ~**80–110MiB × N** + small aggregate.
- rotate default = **restart** instance (changes v4 in G0); `mode=hard` wipes registration.
- Never `pkill warp-svc` (kills sibling netns processes).

### Hot-add port ceiling

Docker cannot create new host port mappings after start. For hot-add (v0.4 WP-D), compose must **pre-publish** `11000-1100N` (or rely on aggregate `:1080` only). Runtime add instance reuses an already-published expose port in that range.

## Docs

- [docs/STATUS.md](./docs/STATUS.md) — primary track **v0.4**
- [docs/pivot-v0.4.md](./docs/pivot-v0.4.md) — v0.4 plan
- [docs/pivot-v0.3.md](./docs/pivot-v0.3.md) — v0.3 baseline notes
- [docs/probe-warp-netns.md](./docs/probe-warp-netns.md) — G0
- [docs/decisions.md](./docs/decisions.md) — ADR-015
- [tests/smoke-v03.sh](./tests/smoke-v03.sh)

## License

MIT for original code. `cloudflare-warp` / Cloudflare terms apply to the client package.
