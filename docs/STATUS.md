# STATUS — warp-pool

**Primary track: v0.4 (hardening + hot config + v4 uniqueness)** — [pivot-v0.4.md](./pivot-v0.4.md)  
**Baseline: v0.3** shipped (Warp + netns + WebUI)  
Date: 2026-08-07

## v0.4 implemented (code)

- [x] WP-E：v4 池内互异（`v4_conflicts` / lock / rotate 重试 / healthy 门禁 / API 409）
- [x] WP-D：`GET/PUT /config`、`POST/DELETE /instances`、entrypoint 热加/热删 desired_n
- [x] WP-B：netns boot 清理；microsocks 优先 + gost fallback；caps compose 文件
- [x] WP-C：WebUI v0.4（v6/last_rotate/cooldown/批量 rotate/冲突提示）；`/data/logs/`
- [x] WP-A：文档 STATUS/pivot/ADR-016；push 路径已通（`gh auth`）
- [ ] GHCR `latest` 重建（本提交触发 Actions）
- [ ] VPS 旁路 smoke v0.4（重建镜像后）
- [ ] caps-only 实机验证（可选）

## v0.3 baseline (shipped)

- G0 PASS；N=2 v4 互异；rotate 换 v4；aggregate + WebUI；privileged

## Ops

```bash
# IPv4
curl -4 --socks5-hostname 127.0.0.1:11000 https://ipv4.icanhazip.com

# API
curl -s 'http://127.0.0.1:9090/instances?token=TOKEN'
curl -sX POST 'http://127.0.0.1:9090/rotate?id=0&mode=restart&token=TOKEN'
curl -s 'http://127.0.0.1:9090/config?token=TOKEN'
curl -sX PUT 'http://127.0.0.1:9090/config?token=TOKEN' -d '{"rotate_cooldown":60}'

# WebUI tunnel
ssh -L 9090:127.0.0.1:19090 root@VPS
# http://localhost:9090/ui/?token=TOKEN

# caps try
docker compose -f docker-compose.yml -f docker-compose.caps.yml up -d
```

- Side-car 19xxx；勿占 warp-chen `:1080`
- hot-add：compose 预 publish `11000-1100N`
- expose 不合并（收益小）
- env：`V4_UNIQUE`、`SOCKS_BIN=microsocks`

## Superseded

v0.2 WarpProxy multi；v0.1 B1 wgcf+wireproxy
