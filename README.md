# warp-pool

Single Docker container. Multiple independent Cloudflare WARP exits. Port-direct or in-container scheduling. Rotate one instance without killing the pool.

**Status:** implementing (see [PLAN.md](./PLAN.md)). Image via **GHCR** (GitHub Actions) — do not build on small VPS.

## Quick start

```bash
# after CI publishes
docker pull ghcr.io/mcheiyue/warp-pool:latest

docker run -d --name warp-pool --restart unless-stopped \
  -e WARP_INSTANCES=2 \
  -v warp-pool-data:/data \
  -p 127.0.0.1:1080:1080 \
  -p 127.0.0.1:11000-11001:11000-11001 \
  ghcr.io/mcheiyue/warp-pool:latest
```

Or: copy `.env.example` → `.env`, then `docker compose up -d` (compose builds locally only if you insist; prefer prebuilt image).

```yaml
# override image in compose:
# image: ghcr.io/mcheiyue/warp-pool:latest
```

### Smoke

```bash
curl -x socks5h://127.0.0.1:11000 https://cloudflare.com/cdn-cgi/trace
curl -x socks5h://127.0.0.1:1080  https://cloudflare.com/cdn-cgi/trace
docker exec warp-pool curl -s http://127.0.0.1:9090/instances
docker exec warp-pool curl -s -X POST 'http://127.0.0.1:9090/rotate?id=0'
```

### Notes

- **No `NET_ADMIN` / tun by default** (wireproxy userspace). Add only if smoke fails.
- Control API defaults to `127.0.0.1:9090` inside the container. Non-loopback bind requires `CONTROL_TOKEN`.
- Memory target: N=5 formal cap ≤120MB (stretch 80MB); measure after run.
- Soft rotate re-registers one instance; not a guarantee of a “clean” CF exit IP.

## Stack

`wgcf` + `wireproxy` × N + `warppool aggregate` (SOCKS RR) + health loop + control API.

Pinned: wgcf **2.2.32**, wireproxy **1.1.3**.

## Docs

- [PLAN.md](./PLAN.md) — full plan, phases, acceptance
- [docs/decisions.md](./docs/decisions.md) — ADRs
- [refs/NOTES.md](./refs/NOTES.md) — upstream survey

## Not in scope (v1)

Clash subscription factories, WARP+ traffic bots, heavy Web UI, coupling to any single downstream app.

## License

MIT for original code. Third-party binaries (wgcf, wireproxy) keep their own licenses.
