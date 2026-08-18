# STATUS — warp-pool

**Next/ship: v0.5.7 自愈逻辑纠偏** — [pivot-v0.5.7-selfheal.md](./pivot-v0.5.7-selfheal.md) · [plan](../.omo/plans/v0.5.7-selfheal-logic.md)  
**Code**: P0–P2 已合 main（同 IP unique 接受、rotate 冷却、短 start 锁、不 all-dead exit、health 单飞、rebuild_healthy、sticky 跟随）  
**Primary (code): v0.5 可控聚合池** — [pivot-v0.5-aggregate-pool.md](./pivot-v0.5-aggregate-pool.md) · [plan](../.omo/plans/v0.5-aggregate-pool.md)  
**Shipped baseline: v0.4** — [pivot-v0.4.md](./pivot-v0.4.md) · ADR-016  
**Baseline: v0.3** shipped  
Date: 2026-08-18

## v0.5 — code done（待 GHCR 发布 / 现网旁路 smoke）

| 项 | 状态 |
|----|------|
| write_meta merge + is_pool_eligible | ✅ lib.sh |
| health-once backends 门禁 | ✅ |
| GET/POST /pool* + sticky 选路 + agg_enabled 文件 | ✅ main.go（`go build`/`go vet` 本地 PASS） |
| WebUI 入池/粘性/聚合面板 | ✅ |
| rotate 临时 drain | ✅ |
| tests/smoke-pool.sh | ✅（需对运行中控制面执行） |
| GHCR 镜像 | ⏳ push/tag 等用户确认；**不在 VPS build**，走 `.github/workflows/docker-publish.yml` |

## v0.4 — done

| WP | 项 | 状态 |
|----|----|------|
| E | v4 池内互异 + 409 | ✅ 代码 + VPS smoke |
| D | 热配置 / 热加删实例 | ✅ API + supervisor；D4 smoke PASS |
| B | netns 清理、microsocks、caps compose | ✅ |
| C | WebUI v0.4、logs、AUTO_ROTATE、ROTATE_SCHEDULE_SEC | ✅ |
| A | 文档/ADR；git push 通 | ✅ |
| A3 | GHCR CI | ⚠️ Actions hosted runner 多次 “not acquired”；**VPS 本地镜像 `warp-pool:v0.4-local` smoke PASS**；workflow 已 amd64-only，可 workflow_dispatch 重试 |

### VPS smoke (`warp-pool-v04`, 2026-08-06)

```
BEFORE V0=104.28.152.117 V1=104.28.165.52  DIVERSE=1
rotate id=0 → V0=104.28.165.55  CHANGED=1 PEER=1 UNIQUE=1
microsocks in-ns; mem ~132MiB
hot-add want=3 → n=3; DELETE id=2 stopped; agg OK
HEALTH_AUTO_ROTATE config PUT + healthcheck OK
FINAL=PASS / D4_C2=PASS
```

Ports: 19080/19100/19101/19090 · token `smoke-v04` · 未动 warp-chen :1080

## Ops

```bash
curl -4 --socks5-hostname 127.0.0.1:11000 https://ipv4.icanhazip.com
curl -s 'http://127.0.0.1:9090/instances?token=T'
curl -sX POST 'http://127.0.0.1:9090/rotate?id=0&mode=restart&token=T'
curl -sX POST 'http://127.0.0.1:9090/instances?want=3&token=T'
curl -sX PUT 'http://127.0.0.1:9090/config?token=T' -d '{"health_auto_rotate":"1"}'
# UI: ssh -L 9090:127.0.0.1:19090 … → http://localhost:9090/ui/?token=T
# caps: docker compose -f docker-compose.yml -f docker-compose.caps.yml up -d
```

Env: `V4_UNIQUE`, `SOCKS_BIN=microsocks`, `ROTATE_SCHEDULE_SEC`, `HEALTH_AUTO_ROTATE`

## Superseded

v0.2 WarpProxy multi · v0.1 B1 wgcf+wireproxy
