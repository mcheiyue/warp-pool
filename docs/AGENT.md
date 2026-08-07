# warp-pool · Agent 使用手册

面向编码 Agent / 自动化运维。**通用**，不绑定任何具体主机、域名或现网端口。

人类快速上手见仓库根目录 [README.md](../README.md)。

---

## 1. 产品是什么

- **名称**：warp-pool  
- **镜像**：`ghcr.io/mcheiyue/warp-pool:latest`  
- **形态**：单容器多实例 Cloudflare WARP（**Warp 模式** + **每实例一个 netns**）  
- **调度**：控制 HTTP API + 单页 WebUI  
- **代理入口**：
  - 聚合 SOCKS：`AGG_SOCKS_PORT`（默认 **1080**）
  - 直连 SOCKS：`EXPOSE_PORT_BASE + id`（默认 **11000 + id**）
- **管理入口**：`CONTROL_BIND:CONTROL_PORT`（默认 **127.0.0.1:9090**）

### 1.1 不要假设

| 错误假设 | 正确理解 |
|----------|----------|
| 无权限可跑 | 需要 `privileged` 或等价 caps + `/dev/net/tun` |
| 热加实例会自动多一个宿主机端口 | Docker **不能**在运行后新增 `-p`；直连口必须启动时预映射 |
| `cdn-cgi/trace` 一定返回 IPv4 | 测 v4 用 `curl -4` + `https://ipv4.icanhazip.com` |
| 可对整容器 `pkill warp-svc` | **禁止**；会误杀其它 netns 内进程 |
| 控制面默认可公网裸奔 | 非 loopback 绑定 **必须** `CONTROL_TOKEN` |

---

## 2. 部署清单（按序执行）

### 2.1 前置条件

- Docker 20+（或兼容 runtime）
- 能拉取 `ghcr.io/mcheiyue/warp-pool:latest`（或本地 `docker build`）
- 主机内核支持 netns、TUN
- 容器需出网（注册 / 连接 Cloudflare）

### 2.2 推荐 `docker run` 模板

将 `TOKEN`、实例数、端口按目标环境替换。**不要**写死某台机器的 IP 或域名。

```bash
export WP_TOKEN='生成一个足够长的随机串'
export WP_N=2

docker rm -f warp-pool 2>/dev/null || true

docker run -d --name warp-pool --restart unless-stopped \
  --privileged \
  --device /dev/net/tun \
  --sysctl net.ipv4.ip_forward=1 \
  --sysctl net.ipv4.conf.all.src_valid_mark=1 \
  -e WARP_INSTANCES="$WP_N" \
  -e CONTROL_BIND=0.0.0.0 \
  -e CONTROL_TOKEN="$WP_TOKEN" \
  -e ROTATE_MODE=restart \
  -e V4_UNIQUE=1 \
  -v warp-pool-data:/data \
  -p 127.0.0.1:1080:1080 \
  -p 127.0.0.1:11000-11009:11000-11009 \
  -p 127.0.0.1:9090:9090 \
  ghcr.io/mcheiyue/warp-pool:latest
```

### 2.3 Compose

```bash
cp .env.example .env
# 写入 CONTROL_TOKEN；若要从宿主机访问 UI：CONTROL_BIND=0.0.0.0
# 在 compose 中发布 9090（示例见 README）
docker compose pull
docker compose up -d
```

### 2.4 等待就绪

```bash
# 最多约 BOOT_HEALTH_WAIT（默认 120s）× N + 注册抖动
for i in $(seq 1 60); do
  h=$(curl -sS -H "Authorization: Bearer $WP_TOKEN" http://127.0.0.1:9090/health || true)
  echo "$i $h"
  echo "$h" | grep -q '"status":"ok"' && break
  sleep 5
done
```

`status` 为 `ok` 且 `healthy == total` 即就绪。`degraded` 表示部分实例可用，可继续排障但不必整池判死。

---

## 3. 端口与流量模型

```
[Client]
   |  SOCKS5
   +-- host:1080  --> warppool aggregate --> healthy backends (RR)
   +-- host:11000 --> expose --> ns wp0 SOCKS --> WARP egress
   +-- host:11001 --> expose --> ns wp1 SOCKS --> WARP egress

[Admin]
   +-- host:9090  --> warppool control (JSON API + /ui/)
```

| 端口角色 | 默认容器端口 | 是否必须映射到宿主机 |
|----------|--------------|----------------------|
| 聚合 SOCKS | 1080 | 要用统一入口则是 |
| 直连 SOCKS | 11000+i | 仅当需要按实例直连 / 热加后仍要直连时预留范围 |
| 控制面 | 9090 | 要用 API/UI 从宿主机访问则是；默认可仅容器内 loopback |

**热加规则（Agent 必读）：**

1. `POST /instances` 增加的是 **逻辑实例**（netns + warp + 入池）。  
2. 新实例 **默认进入聚合池**（健康且 unique）。  
3. 直连 `11000+i` 仅当该端口在 **docker run/compose 时已 publish**。  
4. 未预留端口 ≠ 热加失败；只是 **没有宿主机直连口**。

---

## 4. 鉴权

- 环境变量：`CONTROL_TOKEN`  
- 若 `CONTROL_BIND` 不是 `127.0.0.1` / `::1` / `localhost`，token **为空则进程拒绝启动**。  
- API 请求：

```http
Authorization: Bearer <CONTROL_TOKEN>
```

兼容查询参数 `?token=`（易进日志/历史，**自动化优先用 Header**）。

- WebUI：打开 `/ui/`，在页面输入 token；存 **localStorage**，请求带 Bearer。  
- `/ui/` 静态页本身可不鉴权；**所有 JSON API 在 token 非空时要鉴权**。

---

## 5. HTTP API 契约

Base URL 示例：`http://127.0.0.1:9090`（按实际映射替换）。  
除特别说明外，响应 `Content-Type: application/json`。

### 5.1 `GET /health`

```json
{
  "status": "ok|degraded|down",
  "healthy": 2,
  "total": 2,
  "ts": "2026-08-07T00:00:00Z"
}
```

### 5.2 `GET /instances`

返回数组。字段以实际为准，常见：

| 字段 | 含义 |
|------|------|
| `id` | 实例编号，从 0 起 |
| `healthy` | 是否健康 |
| `v4` / `ip` | 出口 IPv4 |
| `v6` | 出口 IPv6（可能空） |
| `expose` | 直连端口号（如 11000） |
| `mode` | 通常 `warp` |
| `netns` | 如 `wp0` |
| `unique` | IPv4 是否与池内冲突（false=冲突） |
| `last_rotate` | 上次换 IP 时间 RFC3339 或空 |
| `failures` | 连续失败计数 |

### 5.3 `POST /rotate`

Query：

| 参数 | 说明 |
|------|------|
| `id` | 实例 id（与 `all` 二选一） |
| `all=1` | 依次处理全部 |
| `mode` | `restart`（默认）或 `hard` |

成功示例：

```json
{ "ok": true, "output": "...", "unique": true, "v4": "x.x.x.x", "attempts": 1 }
```

失败：

| HTTP | 含义 |
|------|------|
| 400 | 缺 `id` |
| 404 | 实例不存在 |
| 429 | 冷却中（文案含 cooldown） |
| 409 | IPv4 冲突耗尽重试（`reason=v4_collision`） |
| 500 | 脚本/进程错误 |

**语义：**

- `restart`：停该实例 warp/socks，保留 STATE，再启动 —— 用于 **换出口 IP**。  
- `hard`：清 STATE 再注册 —— 更重，冲突重试链路里会用到。

### 5.4 `POST /instances`

- 无 query：目标实例数 **+1**  
- `?want=N`：目标实例数设为 N  

响应常见：`{ "ok": true, "desired": N }`  
实际增减由 entrypoint 监督循环异步执行，Agent 应 **轮询 `GET /instances` / `/health`** 直到对齐。

### 5.5 `DELETE /instances?id=`

停止并移除指定实例；更新 desired。预映射的 Docker 端口 **不会** 从宿主机消失。

### 5.6 `GET /config` · `PUT /config`

`PUT` body 为 JSON，**白名单字段**（蛇形命名），例如：

- `rotate_cooldown`
- `rotate_mode`
- `v4_unique`
- `v4_unique_retries`
- `v4_unique_hard_retries`
- `v4_unique_backoff`
- `health_auto_rotate`
- （以及实现里允许的其它键；以 `GET /config` 返回为准）

写入 `/data` 下 runtime 配置并 `os.Setenv`，对后续脚本生效。

### 5.7 `POST /healthcheck`

立即执行一轮 `health-once`。

### 5.8 `GET /ui/` · `GET /`

静态 WebUI。

---

## 6. 调用示例（复制即用）

```bash
BASE=http://127.0.0.1:9090
AUTH="Authorization: Bearer ${WP_TOKEN}"

# 健康
curl -sS -H "$AUTH" "$BASE/health"

# 列表
curl -sS -H "$AUTH" "$BASE/instances"

# 换 IP
curl -sS -X POST -H "$AUTH" "$BASE/rotate?id=0&mode=restart"

# 全部换 IP
curl -sS -X POST -H "$AUTH" "$BASE/rotate?all=1&mode=restart"

# 热加 1 个
curl -sS -X POST -H "$AUTH" "$BASE/instances"

# 目标 N=3
curl -sS -X POST -H "$AUTH" "$BASE/instances?want=3"

# 删除 id=2
curl -sS -X DELETE -H "$AUTH" "$BASE/instances?id=2"

# 改冷却
curl -sS -X PUT -H "$AUTH" -H 'Content-Type: application/json' \
  -d '{"rotate_cooldown":60,"v4_unique":1}' "$BASE/config"

# 代理测 IPv4
curl -4 -sS --max-time 20 --socks5-hostname 127.0.0.1:1080 https://ipv4.icanhazip.com
curl -4 -sS --max-time 20 --socks5-hostname 127.0.0.1:11000 https://ipv4.icanhazip.com
```

---

## 7. 验收标准（Definition of Done）

部署或变更完成后，Agent **至少**确认：

1. `GET /health` → `status` 为 `ok` 或可接受的 `degraded`，且 `healthy >= 1`。  
2. N≥2 时：两个直连口（若已映射）`curl -4 ... icanhazip` **经常互异**（允许偶发相同，开启 `V4_UNIQUE` 后冲突应重试）。  
3. `POST /rotate?id=0` → `ok: true`，随后该实例 `v4` **变化**（或 409 且 attempts 有值）。  
4. 聚合口 `:1080` 能出网。  
5. 未映射的业务端口不要误伤；**不要**占用用户未指定的主机端口。

自动化脚本参考：`tests/smoke-v04.sh`（通过环境变量注入 `AGG`/`EXPOSE0`/`CTR`/`TOKEN` 等）。

---

## 8. 配置与数据路径（容器内）

| 路径 | 用途 |
|------|------|
| `/data/instances/<id>/` | 每实例 meta、state |
| `/data/state/healthy.json` | 聚合后端列表 |
| `/data/state/` 或 runtime config | 热配置（实现以代码为准） |
| `/data/logs/` | 若启用的滚动日志 |
| `/opt/warp-pool/scripts/` | start/stop/rotate/health |
| `/opt/warp-pool/web/index.html` | WebUI |

卷建议：命名卷或绑定挂载到 `/data`，以便重建容器不丢注册。

---

## 9. 环境变量（Agent 决策用）

完整见 `.env.example`。高频：

| 变量 | 默认 | Agent 注意 |
|------|------|------------|
| `WARP_INSTANCES` | 2 | 启动时 N |
| `CONTROL_BIND` | 127.0.0.1 | 宿主机访问 UI 时常改 `0.0.0.0` + token |
| `CONTROL_TOKEN` | 空 | 生产必填 |
| `EXPOSE_PORT_BASE` | 11000 | 与 `-p` 范围一致 |
| `ENABLE_EXPOSE` | 1 | 0 则无直连转发 |
| `ROTATE_MODE` | restart | 换 IP 默认路径 |
| `ROTATE_COOLDOWN` | 300 | 防刷 |
| `V4_UNIQUE` | 1 | 池内互异 |
| `BOOT_HEALTH_WAIT` | 120 | 启动等待秒数 |
| `DEREGISTER_ON_SHUTDOWN` | 0 | 1 则退出时删注册 |
| `WARP_LICENSE_KEY` | 空 | 可选 |
| `SOCKS_BIN` | microsocks | 可 fallback gost |

---

## 10. 故障与安全禁区

### 10.1 排障命令

```bash
docker logs warp-pool --tail 100
docker exec warp-pool cat /data/state/healthy.json
docker exec warp-pool ls -la /data/instances/
docker exec warp-pool ip netns list
```

### 10.2 禁止事项

1. **禁止**在未确认用户意图时，把 `1080`/`11000+` 绑到 `0.0.0.0` 公网。  
2. **禁止**无 token 将 `CONTROL_BIND=0.0.0.0` 暴露公网。  
3. **禁止** `pkill warp-svc` / 模糊杀进程。  
4. **禁止**用默认 IPv6 结果宣称「换 IP 失败」（先强制 IPv4 测量）。  
5. **禁止**把用户现有其它容器的端口（未声明的）抢掉；部署前 `ss`/`docker ps` 检查冲突。  
6. **不要**把本手册里的示例 token 当生产密钥。

### 10.3 常见失败

| 现象 | 处理 |
|------|------|
| 401 unauthorized | 补 Bearer token |
| 429 | 等冷却或临时调低 `rotate_cooldown` |
| 409 v4_collision | 查 peer v4；可 `mode=hard` 或稍后再试 |
| netns RTNETLINK 错误 | 优先 `docker rm` 再 `run`（保留 volume）；勿只 `restart` 死循环 |
| 热加无直连口 | 预期行为：检查是否预映射 `11000-1100N` |

---

## 11. 给 Agent 的最短决策树

```
需要代理出口？
  └─ 部署镜像 → 等 /health ok → 把业务指到 :1080（或直连 :11000+i）

需要换某个出口 IP？
  └─ POST /rotate?id=&mode=restart → 再 GET /instances 看 v4

需要更多出口？
  └─ 确认 11000 范围是否预留
  └─ POST /instances 或 ?want=N → 轮询直到实例数与健康数符合预期
  └─ 无预留端口：仍可用聚合口

需要改冷却/互异/自动换 IP？
  └─ PUT /config（白名单字段）

需要网页？
  └─ 映射 9090 + CONTROL_TOKEN → /ui/
```

---

## 12. 版本与文档索引

| 文件 | 用途 |
|------|------|
| `README.md` | 人类安装说明 |
| `docs/AGENT.md` | 本文件 |
| `docs/STATUS.md` | 主线状态 |
| `docs/pivot-v0.4.md` | 设计细节 |
| `docs/decisions.md` | ADR |
| `tests/smoke-v04.sh` | 冒烟 |

实现以仓库代码与 `GET /config`、`GET /instances` 现场响应为准；文档滞后时以 **运行中的 API** 为准。
