# warp-pool

Single Docker container. Multiple independent **official** Cloudflare WARP exits (`warp-svc` proxy mode). Port-direct or in-container SOCKS RR. Rotate one instance without killing the pool.

**v0.2 (primary):** official client × N + `warppool` aggregate/control.  
**v0.1 B1:** wgcf+wireproxy — deprecated (does not rotate egress IP on tested hosts).

Image: **`ghcr.io/mcheiyue/warp-pool:latest`** (GitHub Actions → GHCR).

## Quick start

```bash
docker pull ghcr.io/mcheiyue/warp-pool:latest

docker run -d --name warp-pool --restart unless-stopped \
  -e WARP_INSTANCES=2 \
  -v warp-pool-data:/data \
  -p 127.0.0.1:1080:1080 \
  -p 127.0.0.1:40000-40001:40000-40001 \
  ghcr.io/mcheiyue/warp-pool:latest
```

Or: copy `.env.example` → `.env`, `docker compose up -d`.

### Smoke

```bash
curl --socks5-hostname 127.0.0.1:40000 https://cloudflare.com/cdn-cgi/trace
curl --socks5-hostname 127.0.0.1:1080  https://cloudflare.com/cdn-cgi/trace
docker exec warp-pool curl -s http://127.0.0.1:9090/instances
# reconnect rotate (default):
docker exec warp-pool curl -s -X POST 'http://127.0.0.1:9090/rotate?id=0'
# hard re-register:
docker exec warp-pool curl -s -X POST 'http://127.0.0.1:9090/rotate?id=0&mode=hard'
```

### Notes

- **No `NET_ADMIN` / tun by default** (WARP **proxy** mode). UDP not available in proxy mode.
- Control API defaults to `127.0.0.1:9090` inside the container.
- Memory: roughly **~110MiB × N** + small aggregate; N=2 often **~220–270MiB**. Not a tiny wgcf pool.
- Egress may be **IPv6**; rotate does not guarantee a “clean” or smarter IP — only a different/session refresh attempt.
- `DEREGISTER_ON_SHUTDOWN=1` (default) deletes registrations on stop to limit device-slot leak.

## Stack

`cloudflare-warp` (`warp-svc` × N, isolated `STATE_DIRECTORY` / `RUNTIME_DIRECTORY` / dbus)  
+ `warppool aggregate` (SOCKS RR) + health loop + control API.

## Docs

- [docs/STATUS.md](./docs/STATUS.md) — current track  
- [docs/probe-official.md](./docs/probe-official.md) — VPS probe numbers  
- [docs/pivot-v0.2.md](./docs/pivot-v0.2.md) — reshape  
- [docs/decisions.md](./docs/decisions.md) — ADRs  
- [PLAN.md](./PLAN.md) — original B1 plan (historical)  
- [.omo/plans/v0.2-official-pivot.md](./.omo/plans/v0.2-official-pivot.md) — v0.2 execution plan  

## Not in scope

Clash subscription factories, WARP+ traffic bots, heavy Web UI, coupling to any single downstream app.  
No vendoring of CC-BY-NC third-party multi-WARP scripts.

## License

MIT for original code. `cloudflare-warp` package is subject to Cloudflare’s terms.
