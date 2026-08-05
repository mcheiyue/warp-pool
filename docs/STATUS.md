# Status

**Current primary path: v0.2 official (`warp-svc` proxy × N).**

| Track | State |
|-------|--------|
| v0.1 B1 (`wgcf` + `wireproxy`) | **Deprecated** — fast/tiny but exit IP does not rotate on tested VPS |
| v0.2 official | **Implementing / shipping** on branch `v0.2-official` → `main` |

## Evidence

- `docs/probe-official.md` — N=2 official multi ~265MiB, IP diversity, rotate works
- `docs/pivot-v0.2.md` — reshape notes
- ADR-013/014 in `docs/decisions.md`

## B1 script inventory (historical)

Former B1-only concerns (replaced in v0.2):

- `sanitize_wgconf` / wgcf register paths in old `lib.sh`
- `wireproxy.conf` generation
- `INSTANCE_PORT_BASE=11000` default

## Ops

- Default ports: aggregate `1080`, direct `40000+i`, control `127.0.0.1:9090`
- Memory: expect ~110MiB × N + aggregate (N=2 often ~220–270MiB)
- Smoke on VPS: use **19xxx** side ports; do not steal `warp-chen` `:1080`
