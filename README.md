# warp-pool

**一个 Docker 容器，多个独立 Cloudflare WARP 出口。**

每个实例跑在独立 network namespace 里（Warp 模式），可按端口直连，也可走容器内 SOCKS 轮询。支持 API / 单页 WebUI 调度：换 IP、加减实例、热改配置。

镜像：`ghcr.io/mcheiyue/warp-pool:latest`  
许可：原代码 MIT；Cloudflare WARP 客户端遵循其自身条款。

---

## 它解决什么问题

| 你想要的 | warp-pool 怎么做 |
|----------|------------------|
| 多个 WARP 出口 | 一容器 N 实例，各占一个 netns |
| IPv4 尽量互异 | 健康检查 + 冲突时自动重试换 IP |
| 换某个出口的 IP | `POST /rotate?id=`（默认重启该实例进程） |
| 统一入口 | 聚合 SOCKS `:1080` 轮询健康实例 |
| 指定实例入口 | 直连 `:11000+i`（需启动时映射端口） |
| 网页管理 | 控制面 `/ui/` |

---

## 快速开始

### 1. 一条命令（本机环回）

```bash
docker run -d --name warp-pool --restart unless-stopped \
  --privileged \
  --device /dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  -e WARP_INSTANCES=2 \
  -e CONTROL_BIND=0.0.0.0 \
  -e CONTROL_TOKEN=change-me \
  -v warp-pool-data:/data \
  -p 127.0.0.1:1080:1080 \
  -p 127.0.0.1:11000-11009:11000-11009 \
  -p 127.0.0.1:9090:9090 \
  ghcr.io/mcheiyue/warp-pool:latest
```

首次启动要注册 WARP，N=2 大约 1–3 分钟。日志：

```bash
docker logs -f warp-pool
```

### 2. Docker Compose

```bash
cp .env.example .env
# 编辑 .env：至少设 CONTROL_TOKEN；需要 WebUI 外访时 CONTROL_BIND=0.0.0.0
docker compose up -d
```

默认映射：

| 宿主机 | 容器内 | 用途 |
|--------|--------|------|
| `127.0.0.1:1080` | `1080` | 聚合 SOCKS（轮询） |
| `127.0.0.1:11000–11009` | 同左 | 实例直连（预留热加） |
| （可选）`127.0.0.1:9090` | `9090` | 控制 API + WebUI |

compose 默认不发布 `9090`；需要管理面时在 `docker-compose.yml` 取消注释或自行 `-p`。

### 3. 验证

```bash
# 出口 IPv4（务必 -4）
curl -4 --socks5-hostname 127.0.0.1:11000 https://ipv4.icanhazip.com
curl -4 --socks5-hostname 127.0.0.1:11001 https://ipv4.icanhazip.com
curl -4 --socks5-hostname 127.0.0.1:1080  https://ipv4.icanhazip.com

# API（令牌按你设置的 CONTROL_TOKEN）
curl -s -H "Authorization: Bearer change-me" http://127.0.0.1:9090/health
curl -s -H "Authorization: Bearer change-me" http://127.0.0.1:9090/instances

# 换 0 号实例 IP
curl -s -X POST -H "Authorization: Bearer change-me" \
  'http://127.0.0.1:9090/rotate?id=0&mode=restart'
```

WebUI：浏览器打开 `http://127.0.0.1:9090/ui/`，输入与 `CONTROL_TOKEN` 相同的令牌。

---

## 端口怎么理解

```
客户端
  ├─ :1080     → 聚合（健康实例轮询）     ← 日常主入口
  ├─ :11000    → 实例 0 直连
  ├─ :11001    → 实例 1 直连
  └─ :9090     → API + WebUI（管理面）
```

**热加实例与端口：**

- Docker **启动后不能再新增** 宿主机 `-p` 映射。
- 热加实例 **一定能进聚合 `:1080`**（若健康且 IPv4 互异通过）。
- 独立直连口只占用 **启动时已映射** 的 `11000+i`。compose 默认预留到 `11009`，便于 N≤10 热加仍有直连。
- 若只关心聚合口，可以不映射 `11000+`，热加仍可用。

---

## 权限与资源

| 项 | 说明 |
|----|------|
| 权限 | 默认 `privileged` + `/dev/net/tun`（netns / TUN） |
| 降权尝试 | `docker compose -f docker-compose.yml -f docker-compose.caps.yml up -d` |
| 内存 | 大约 **80–110 MiB × N** + 少量控制面 |
| 数据 | 卷 `/data`（注册状态、配置、日志） |

---

## 常用环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `WARP_INSTANCES` | `2` | 启动实例数 |
| `CONTROL_BIND` | `127.0.0.1` | 控制面监听；非环回必须设 token |
| `CONTROL_TOKEN` | 空 | 管理令牌；空则控制面无认证（仅可信环境） |
| `ROTATE_MODE` | `restart` | `restart` 保留注册；`hard` 清注册 |
| `ROTATE_COOLDOWN` | `300` | 同一实例换 IP 冷却秒数 |
| `V4_UNIQUE` | `1` | 池内 IPv4 互异门禁 |
| `HEALTH_AUTO_ROTATE` | `0` | 健康失败自动换 IP |
| `ENABLE_EXPOSE` | `1` | 是否启动 11000+ 直连转发 |
| `WARP_LICENSE_KEY` | 空 | 可选 WARP+ 许可证 |

完整列表见 [`.env.example`](./.env.example)。运行中可用 `PUT /config` 热改部分项（见下）。

---

## 控制 API 速查

鉴权：请求头 `Authorization: Bearer <CONTROL_TOKEN>`，或（不推荐）`?token=`。

| 方法 | 路径 | 说明 |
|------|------|------|
| `GET` | `/health` | 池状态：`ok` / `degraded` / `down` |
| `GET` | `/instances` | 实例列表（v4、健康、expose…） |
| `POST` | `/rotate?id=0&mode=restart` | 换指定实例 IP |
| `POST` | `/rotate?all=1` | 依次换全部 |
| `POST` | `/instances` | 目标 N+1（热加） |
| `POST` | `/instances?want=3` | 设目标实例数 |
| `DELETE` | `/instances?id=2` | 停并移除实例 |
| `GET`/`PUT` | `/config` | 读/写可热改配置 |
| `POST` | `/healthcheck` | 立刻跑一轮健康检查 |
| `GET` | `/ui/` | WebUI（静态页，API 仍要令牌） |

换 IP 若与池内其它实例 IPv4 冲突，可能返回 **409** 并带 `reason=v4_collision`。

给自动化 / Agent 的完整约定见 **[docs/AGENT.md](./docs/AGENT.md)**。

---

## 文档

| 文档 | 给谁看 |
|------|--------|
| 本文 README | 人：安装、端口、常用命令 |
| [docs/AGENT.md](./docs/AGENT.md) | Agent：部署清单、API、验收、禁区 |
| [docs/STATUS.md](./docs/STATUS.md) | 当前主线与完成度 |
| [docs/pivot-v0.4.md](./docs/pivot-v0.4.md) | v0.4 设计说明 |
| [docs/probe-warp-netns.md](./docs/probe-warp-netns.md) | netns 可行性探针记录 |
| [tests/smoke-v04.sh](./tests/smoke-v04.sh) | 自动化冒烟 |

---

## 故障排查（最短）

```bash
docker logs warp-pool 2>&1 | tail -80
docker exec warp-pool cat /data/state/healthy.json
docker exec warp-pool ls /data/instances/
```

- **一直不健康**：等注册完成；确认出网与 DNS；看 `/tmp/warp-svc-*.log`（容器内）。
- **两口同一 IPv4**：偶发于 Cloudflare；开启 `V4_UNIQUE=1` 后应自动重试；测 IP 必须用 `curl -4` + `ipv4.icanhazip.com`。
- **WebUI 空白 / 401**：未带令牌。浏览器登录页输入 `CONTROL_TOKEN`，或 API 加 `Authorization` 头。
- **`docker restart` 后 netns 异常**：当前入口会清理 `/run/netns`；仍失败则 `docker rm` 后重新 `run`（数据在 volume 里）。

---

## 版本线

- **v0.4（当前）**：硬化、热配置、IPv4 互异、microsocks、WebUI
- **v0.3**：Warp × netns 基线
- **v0.2 / v0.1**：已替代，勿用于新部署
