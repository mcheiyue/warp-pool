# warp-pool 规划书

> 单容器 · 多 WARP 独立出口 · 可切 IP · 端口直连 / 容器内调度  
> 路线：**B（wgcf 轻量多实例）**  
> 状态：规划定稿（Oracle 审查 revise 已回写），尚未编码  
> 日期：2026-08-05  
> 仓库路径：`D:\Github\warp-pool`

---

## 1. 产品目标

### 1.1 一句话

起 **一个 Docker 容器**，内部跑 **N 个独立 Cloudflare WARP 会话**（各自独立出口 IP），对外提供：

- **按端口**访问指定实例（`BASE+i`）
- **统一入口**由容器内调度（round-robin / 健康摘除）
- **切 IP**：重启单实例或重新注册该实例 profile（不动其它实例）

### 1.2 成功标准（验收）

| # | 标准 | 验证方式 |
|---|------|----------|
| 1 | 单 `docker compose up -d` 即可 | 无多服务编排依赖 |
| 2 | `WARP_INSTANCES=N`（N≥2）启动后，N 个直连口均可 `warp=on`；出口 IP **尽力互异**（允许 CF 池重复；重复时可 soft rotate 再测，**不因此 fail CI**） | 每端口 `curl --socks5 …/cdn-cgi/trace`；记录 `ip=` |
| 3 | 聚合口 `:1080` 连续请求落到 **不同 backend 实例 id/端口**（主验）；唯一出口 IP 数作次要统计 | 采样 ≥20 次；对照 `/instances` 或探测日志中的 backend |
| 4 | `POST /rotate?id=k` 只动第 k 个实例，其它实例进程与 conf 不变 | rotate 前后对比 id≠k 的 port/conf/ip |
| 5 | 坏实例自动摘除，恢复后重新加入 | 人为 kill 单实例后聚合口仍可用 |
| 6 | 1C2G 上 N=5 空闲总内存 **正式上限 ≤ 120MB**；**≤ 80MB 为 stretch**（Phase 1 单实例 RSS 实测外推后再 lock，禁止把未测 80MB 写进 CI 红线） | `docker stats`；§10 表标「估/已测」 |
| 7 | 文档/镜像/compose **不出现** grok、chen、mcheiyue 业务绑定 | 仓库全文检索 |
| 8 | 可推 GHCR，第三方只靠 README 能用 | 冷启动按文档复现 |

### 1.3 非目标（v1 明确不做）

- Clash / 订阅节点工厂（WARP-Clash-API 那类）
- 刷 WARP+ 流量、Web 大面板、Chrome 多开
- 与 grok2api / chen-fork 代码耦合
- 官方 `warp-svc` 多 daemon（路线 A，仅作对照与应急）
- 保证「每次 rotate 都是干净、永不降智的 IP」（CF 池无法保证）

---

## 2. 背景与决策依据

### 2.1 现网对照（美西 1C2G）

| 容器 | 镜像 | 内存 | 角色 |
|------|------|------|------|
| `warp-chen` | `caomingjun/warp` | ~96MB | 官方 client 单实例 |
| `warp-socks` | `mon-ius/docker-warp-socks` | ~26MB | 另一单实例 SOCKS |

问题：整容器 restart 换会话；账号 sticky 时易 502；socks 重启后「降智」未必缓解；无法一容器多 IP 池化。

### 2.2 路线选择（已定 B）

| 路线 | 技术 | 结论 |
|------|------|------|
| **A** 官方 client 多实例 | `ErcinDedeoglu/cloudflare-warp`：`STATE_DIRECTORY` 隔离多 `warp-svc` + GOST RR | 功能现成，**50–100MB/实例**，1C2G 仅 N≤2～3；License CC-BY-NC |
| **B** wgcf 轻量多实例 | `wgcf` 多 profile + 用户态/内核转发 + 轻量 SOCKS | **主路径**；N=5～10 仍适合 1C2G |

### 2.3 参考项目（只作积木，不整仓 fork 成产品）

| 项目 | 贡献点 | 不直接当基线的原因 |
|------|--------|-------------------|
| [ccbkkb/MicroWARP](https://github.com/ccbkkb/MicroWARP) (MIT, 1.3k★) | wgcf 注册、conf 清洗、MTU/Endpoint、microsocks、~1MB | **单实例**；内核 `wg0` 默认路由模型不利多隧道 |
| [ViRb3/wgcf](https://github.com/ViRb3/wgcf) | 注册 / generate / license | 工具，不是代理产品 |
| [kingcc/warproxy](https://github.com/kingcc/warproxy) | wgcf + **wireproxy** 单实例模式 | 单实例；可借鉴组合 |
| [ayush1920/WarpNet](https://github.com/ayush1920/WarpNet) | netns 多 profile + 端口 | **宿主机 systemd**，非单 Docker 产品；UI 过重 |
| [ErcinDedeoglu/cloudflare-warp](https://github.com/ErcinDedeoglu/cloudflare-warp) | 多实例产品形态：端口 `40000+N`、GOST 聚合、健康、错峰注册 | 路线 A；内存与协议栈不同；可抄 **API/端口约定** |
| `思路.md` | netns/多 wg 架构图、池化勿狂注册 | 仓库名有误（Clash-API≠出口池） |

### 2.4 隔离方案选型（B 内关键分叉）

多 WARP 在同一网络命名空间里不能抢同一个默认路由。候选：

| 方案 | 做法 | 优点 | 缺点 | v1 选择 |
|------|------|------|------|---------|
| **B1 wireproxy 用户态** | 每实例：一份 wgcf conf → 一个 `wireproxy` 听独立 SOCKS 口 | 实现简单；无 netns；实例互不抢默认路由；易单实例 rotate | 用户态转发，吞吐略低于纯内核 | **✅ v1 默认** |
| **B2 netns** | 每实例一个 netns + 内核 wg + microsocks | 隔离最干净；贴近 `思路.md` | 脚本复杂；权限/调试成本高 | v1.1 备选 |
| **B3 多 wg + 策略路由** | wg0..wgN + 多路由表 + 策略 | 内核性能 | 路由表易碎、难维护 | 不优先 |

**v1 锁定 B1（wgcf + wireproxy × N + 可选 gost 聚合）。**  
理由：最短路径达到「多独立 IP + 单容器 + 可 rotate」；性能仍远优于路线 A。

---

## 3. 目标架构

```
                    ┌────────────────────── warp-pool 容器 ──────────────────────┐
  客户端 ──:1080──► │  聚合层（gost 或自写极简 RR）                                  │
                    │       │ round-robin / skip unhealthy                         │
                    │       ├──────────────┬──────────────┬─────────────           │
                    │       ▼              ▼              ▼                        │
  客户端 ──:11000─► │  wireproxy#0    wireproxy#1    wireproxy#N-1                 │
  客户端 ──:11001─► │   (SOCKS)         (SOCKS)         (SOCKS)                    │
                    │       │              │              │                        │
                    │   profile-0      profile-1      profile-N-1  (wgcf conf)     │
                    │       │              │              │                        │
                    │       └──── Cloudflare WARP 出口 IP 各自独立 ────┘            │
                    │                                                              │
                    │  control :9090  /health  /instances  /rotate                 │
                    └──────────────────────────────────────────────────────────────┘
```

### 3.1 端口约定（v1）

| 端口 | 用途 |
|------|------|
| `1080` | 聚合 SOCKS5（WARP 池，默认 RR） |
| `8080` | 可选聚合 HTTP（v1 可后置） |
| `11000 + i` | 实例 i 直连 SOCKS5 |
| `9090` | 本机控制 API（默认只绑 127.0.0.1；compose 可改） |

### 3.2 数据卷

```
/data/
  instances/
    0/
      wgcf-account.toml      # v1 保留便于 status（非阅后即焚）
      wgcf-profile.conf      # wgcf generate 的 WireGuard 段
      wireproxy.conf         # 固定契约：WGConfig=.../wgcf-profile.conf + [Socks5] BindAddress
      meta.json              # 创建时间、上次 rotate、连续失败次数、最近出口 IP
    1/
      ...
  state/
    healthy.json             # 健康集合，供聚合层读取
```

持久化目的：**避免每次启动全量 re-register 触发 CF 限流**。

**wireproxy 配置契约（冻结）：** 不得 `wireproxy -c wgcf-profile.conf` 直接开。每实例生成 `wireproxy.conf`：

```
WGConfig = /data/instances/i/wgcf-profile.conf

[Socks5]
BindAddress = 0.0.0.0:11000+i
```

（若所选 wireproxy 版本语法为内联 `[Interface]/`/`[Peer]` 合并单文件，等价即可，但 **必须含 Socks5 绑定**；Phase 1 冒烟后把实际语法钉进 ADR-010。）

### 3.3 切 IP 语义

| 操作 | 行为 | 预期耗时 | 归属 |
|------|------|----------|------|
| `rotate id=i`（默认 soft） | 停 wireproxy#i → 删该实例 conf/account → `wgcf register` + `generate` → 写 wireproxy.conf → 起 wireproxy#i → 探测 → 标 healthy | 5–30s | Phase 4 API；脚本可 Phase 2 复用 |
| `rotate id=i mode=reconnect` | 仅重启 wireproxy（**不保证**换 IP） | 1–3s | Phase 4 |
| `rotate all` | **串行** + 每实例间隔 `ROTATE_ALL_GAP`（默认 ≥30s）+ jitter，禁止并行狂注册 | 分钟级 | Phase 4 |
| 健康失败达阈值 | **先摘除**（Phase 3）；达 `HEALTH_FAILURES` 且过 cooldown 后 **自动 soft rotate**（Phase 4 接上，Phase 3 可只摘除不重注册） | 同 soft | 见下 |

**原则：池内轮换优先于狂注册。** 维护 N 个会话，差的踢掉重注册，好的保留。

**健康语义（补全）：**

| 项 | v1 约定 |
|----|---------|
| 探测 | `curl --socks5` → `cdn-cgi/trace`，超时 `HEALTH_TIMEOUT`（默认 10s） |
| 失败 | 连续 `HEALTH_FAILURES`（默认 3）→ 标 unhealthy 并从聚合摘除 |
| 进程死亡 | **立即**摘除（不等满 3×interval）；由监督循环发现 PID 消失 |
| 恢复 | 连续 `HEALTH_RECOVERIES`（默认 2）成功 → 重新加入 |
| 自动 soft rotate | 摘除后若仍失败且过 `ROTATE_COOLDOWN` → soft rotate（Phase 4；未实现前仅摘除） |

### 3.4 进程监督（v1 冻结）

单容器多进程，**禁止**无监管的 `wireproxy &` 散养。

| 角色 | 约定 |
|------|------|
| PID 1 | `entrypoint`（或 tini + entrypoint）；收 SIGTERM 后：**先停聚合/控制面 → 再停全部 wireproxy → 退出** |
| wireproxy × N | 子进程；监督循环（entrypoint 内 `while` 或极简脚本）发现退出则：记日志、标 unhealthy、**按策略拉起**（已有 conf 则 reconnect；无 conf 则 register 路径） |
| health-loop | 后台循环；不替代进程监督 |
| 聚合 / 控制面 | 各一进程；挂了由监督拉起或导致 degraded |
| Phase 1 特例 | **唯一** wireproxy 退出 → 容器 **exit ≠ 0**（便于 compose `restart` 与冒烟失败可见） |
| Phase 2+ | 单实例挂了 **不** 整容器退出；降级跑剩余 healthy；`/health=degraded` |

---

## 4. 组件与依赖

| 组件 | 选型 | 说明 |
|------|------|------|
| 基础镜像 | `alpine:3.20`（或 distroless 后期） | 小 |
| 注册 | `wgcf` 静态二进制 | **Phase 1 钉 tag/commit**；支持 `GH_PROXY` |
| 隧道+SOCKS | `wireproxy` | 每实例一进程；**只读 `wireproxy.conf` 契约**（§3.2），不直接吞 wgcf conf |
| 聚合 | **v1 默认：极简自写 RR**（读 `healthy.json`，失败跳过后端） | gost v3 为备选；**禁止**「gost 或自写」拖到实现时再选（ADR-009）。若改 gost：必须写清 rewrite YAML + reload 协议与连接抖动窗口 |
| 控制面 | **v1 锁定：busybox httpd + shell CGI/脚本**（或等价 `nc` 路由） | 与 health-loop 同壳；Phase 5 前不引入独立 Go 服务，除非 shell 证明不够（ADR-011） |
| 健康探测 | `curl --socks5 127.0.0.1:PORT https://cloudflare.com/cdn-cgi/trace` | 断言 `warp=on\|plus`，记录 `ip=` |
| 权限 | **默认：不挂 `/dev/net/tun`，不加 `NET_ADMIN`** | wireproxy 用户态 netstack 通常不需要。Phase 1 冒烟：先无 cap 跑通；**仅失败时**再最小加 cap，并回写 ADR-010 |
| 进程监督 | entrypoint 前台 + 子进程巡检（§3.4） | 不用 s6 除非 shell 监督明显不够 |

> Phase 1 冒烟只回答三问：**(1) 通不通 (2) 要不要 cap/tun (3) 单实例 RSS 多少**。答完再 lock §1.2 #6 与 §10。

---

## 5. 环境变量（v1 草案）

| 变量 | 默认 | 说明 |
|------|------|------|
| `WARP_INSTANCES` | `2` | 实例数 |
| `INSTANCE_PORT_BASE` | `11000` | 直连 SOCKS 起始端口 |
| `AGG_SOCKS_PORT` | `1080` | 聚合 SOCKS |
| `CONTROL_PORT` | `9090` | 控制 API |
| `CONTROL_BIND` | `127.0.0.1` | 控制面绑定 |
| `CONTROL_TOKEN` | 空 | 非空则 Bearer 校验。**若 `CONTROL_BIND` 非 loopback 且 token 空 → 拒绝启动**（exit ≠ 0 + 明确日志） |
| `HEALTH_INTERVAL` | `60` | 探测周期秒 |
| `HEALTH_TIMEOUT` | `10` | 单次探测超时秒 |
| `HEALTH_FAILURES` | `3` | 连续失败 → 摘除；再触发自动 soft rotate（Phase 4） |
| `HEALTH_RECOVERIES` | `2` | 连续成功 → 重新加入 |
| `ROTATE_COOLDOWN` | `300` | 同实例 soft rotate 冷却秒 |
| `ROTATE_ALL_GAP` | `30` | `rotate all` 相邻实例最小间隔秒 |
| `REGISTER_JITTER_MAX` | `8` | **单实例**随机抖动上限秒；实际延迟 = `i * REGISTER_STAGGER + rand(0..JITTER)` |
| `REGISTER_STAGGER` | `5` | 多实例启动按 index 错峰基数秒（防同出口撞 CF 限流） |
| `PARTIAL_REGISTER_POLICY` | `degraded` | `degraded`：至少 1 个成功则继续，`/health=degraded`；`fail`：任一必要实例失败则容器 exit ≠ 0 |
| `ENDPOINT_IP` | 空 | 覆盖 WG Endpoint（机房优选） |
| `MTU` | `1280` | WG MTU |
| `WGCF_VERSION` | 钉死版本号 | 可复现构建（Phase 1 写入，禁止「发布前再 lock」） |
| `WIREPROXY_VERSION` | 钉死版本号 | 同上 |
| `GH_PROXY` | 空 | GitHub 下载代理 |
| `LICENSE_KEY` | 空 | 可选 WARP+（多 key 逗号分隔，轮转绑定） |
| `PROXY_USER` / `PROXY_PASS` | 空 | 聚合/直连认证 |

---

## 6. 控制 API（v1）

全部 JSON；默认本机。

| 方法 | 路径 | 行为 |
|------|------|------|
| `GET` | `/health` | 整体：`ok` / `degraded` / `down` + healthy 数量 |
| `GET` | `/instances` | 列表：id、port、healthy、exit_ip、last_rotate、failures |
| `POST` | `/rotate?id={i}` | soft 重注册该实例 |
| `POST` | `/rotate?id={i}&mode=reconnect` | 仅重启进程 |
| `POST` | `/rotate?all=1` | 限速全量 soft rotate |
| `POST` | `/healthcheck` | 立即跑一轮探测 |

错误：未知 id → 404；冷却中 → 429 + `retry_after`。

---

## 7. 分期交付

### Phase 0 — 规划与骨架 ✅

- [x] 目录 `D:\Github\warp-pool`
- [x] 本规划书（含 2026-08-05 Oracle 审查修订）
- [x] README 入口
- [x] `docs/decisions.md`（ADR）
- [x] `refs/NOTES.md`（上游链接与结论）

### Phase 1 — 单实例跑通（B1 积木）

- Dockerfile：alpine + **钉版本** wgcf + wireproxy + curl
- 生成 `wireproxy.conf` 契约（§3.2）；无 conf 则 register/generate
- entrypoint 前台；**唯一子进程退出 → 容器 exit ≠ 0**（§3.4）
- compose：**默认无 tun / 无 NET_ADMIN**；volume `/data`；端口 11000
- 验收三问：`warp=on`；卷保留后重启不换号；**记录 RSS 与是否需 cap** → 回写 §10 / ADR-010
- **不**在本阶段引入 gost 配置生成作为唯一路径

### Phase 2 — 多实例 + 直连端口

- 循环 0..N-1 独立 data dir + wireproxy + 监督拉起
- 启动：`i * REGISTER_STAGGER + jitter`；注册失败指数退避
- `PARTIAL_REGISTER_POLICY`：默认 degraded（≥1 成功则继续）
- 验收：N 口均可 `warp=on`；IP 尽力互异（§1.2 #2）；单实例挂不整容器死

### Phase 3 — 聚合 + 健康

- **默认自写 RR** 读 `healthy.json`（ADR-009）；失败跳过
- health loop：超时 / 失败计数 / 进程死亡立即摘除 / 恢复阈值（§3.3）
- 本阶段 **只摘除、不自动 soft rotate**（rotate 属 Phase 4）
- 验收：kill 一 wireproxy 后 `:1080` 仍通；backend 集合少 1（§1.2 #3/#5）

### Phase 4 — rotate API + 冷却

- control：busybox httpd + shell（ADR-011）；非 loopback 强制 token
- soft rotate / reconnect / all（`ROTATE_ALL_GAP`）
- 健康失败过阈值 + cooldown → 自动 soft rotate
- 验收：§1.2 #4；#5 在自动 rotate 接通后回归

### Phase 5 — 发布级打磨

- 多 arch 构建（amd64/arm64）
- GHCR workflow
- 中英 README、安全说明（控制面勿暴露公网）
- 资源建议：1C2G → N=3～5；≥2C4G → N=8～10
- **可选**：现网并行验证（另文档，不进主 README 业务名）

### Phase 6 — 可选增强（v1 后）

- B2 netns 后端（若 wireproxy 性能不足）
- sticky（按源 IP 或 header）
- metrics（Prometheus text）
- WARP+ license 多 key 均分
- **简单单页 WebUI**（P4 API 稳定后才做；不进 P1–P5）
  - 一个 `static/index.html`（原生 JS / 可选 htmx），零前端构建
  - 只调 control API：`/health`、`/instances`、`/rotate`、`/healthcheck`
  - 列表：id / port / healthy / exit_ip / failures；按钮：reconnect、soft rotate
  - 同进程由 httpd 挂静态目录；与 API 同 `CONTROL_BIND` + Bearer；默认本机
  - 不做：登录系统、WebSocket、图表、订阅工厂、业务名绑定
  - 若需「停/起进程不删号」再加 `POST /instances/{id}/stop|start`（YAGNI，有 UI 需求再开）

---

## 8. 目录结构（目标）

```
D:\Github\warp-pool\
  PLAN.md                 # 本规划书
  README.md               # 用户入口（通用，无业务绑定）
  LICENSE                 # MIT（自有代码）；第三方二进制遵循其许可
  Dockerfile
  docker-compose.yml
  .env.example
  entrypoint.sh           # 或拆 scripts/
  scripts/
    register-instance.sh
    start-instance.sh
    health-loop.sh
    rotate-instance.sh
    supervise.sh          # 子进程巡检/拉起
    gen-aggregate.sh      # 自写 RR 或（备选）gost 配置；名称不绑 gost
  control/                # Phase 4：shell/httpd 脚本可放此
  docs/
    decisions.md          # ADR
    architecture.md       # 架构图展开
  refs/
    NOTES.md              # 上游调研摘要
  tests/
    smoke.sh              # 本地/CI 冒烟
```

Phase 0 只强制：`PLAN.md`、`README.md`、`docs/decisions.md`、`refs/NOTES.md`。

---

## 9. 风险与缓解

| 风险 | 影响 | 缓解 |
|------|------|------|
| CF 注册 rate limit | 启动/rotate 失败 | 持久化；`REGISTER_STAGGER`+jitter；cooldown；`ROTATE_ALL_GAP`；池化优于狂注册 |
| 多实例 IP 偶尔重复 | 不能当硬成功标准 | §1.2 #2/#3 已改为尽力 + 主验 backend；重复则 soft rotate 再测 |
| wireproxy 行为/权限差异 | Phase 1 卡壳 | 默认无 cap 冒烟；失败再加；48h dual-track B2 仅作应急 |
| 内存目标虚高 | CI/宣传打脸 | 正式上限 120MB；80MB stretch；§10 未测前标「估」 |
| 多进程散养 | 半死/僵尸/杀不干净 | §3.4 监督模型；Phase 1 单进程失败即非 0 |
| 聚合与健康不同步 | #5 验收失败 | v1 自写 RR 读 healthy；不用静态 gost 假装热更新 |
| 免费 WARP 出口质量差 | 「降智」仍在 | 产品只保证可切换；质量由上游策略决定 |
| 控制面暴露 | 被扫 rotate | 默认 127.0.0.1；非 loopback 强制 token，否则拒启 |
| 部分注册失败 | 行为随机 | `PARTIAL_REGISTER_POLICY=degraded\|fail` |
| 许可证 | 混用二进制 | 自有 MIT；README 声明 wgcf/wireproxy/（可选）gost 许可 |

---

## 10. 性能预期（1C2G）

> MicroWARP ~1MB 是内核 wg+microsocks，**不能**外推 wireproxy。下列含 2026-08-05 美西 VPS smoke 实测。

| 配置 | 空闲内存 | 状态 | 说明 |
|------|----------|------|------|
| N=1 | **~10MB** | 已测 (VPS, no caps) | `docker stats`；重启后 profile 复用、IP 稳定 |
| N=2 | **~12MB** | 已测 | 串行 healthy 启动；两口 `warp=on`；聚合 :1080 通 |
| N=5 | **上限 120MB**；stretch 80MB | 外推 ~25–40MB | 按 N=2 线性粗估，远低于上限 |
| N=10 | 外推 ~40–70MB | 估 | 仍观察 FD/注册限流 |
| 对照 A N=3 | ~200–300MB | 对照 | 不采用为默认 |

**VPS smoke 要点（2026-08-05）：**
- 默认 **无 NET_ADMIN / 无 tun** 可通过（wireproxy 用户态）
- 多实例必须 **等前一实例 healthy 再启下一实例**（已写入 entrypoint）
- Endpoint 主机名解析为 IP 写入 conf，减少半开隧道 DNS 干扰
- 两实例出口 IP 可相同（CF 池）；验收主看 backend 口通
- `POST /rotate` 为同步长操作，客户端超时建议 ≥60s

延迟：本机 SOCKS 可忽略；出口受 CF 与 Endpoint 影响。  
吞吐：API 代理场景通常足够；瓶颈多在上游业务而非 wireproxy。

---

## 11. 与现网迁移（附录，非仓库主线）

1. 并行起 `warp-pool`（N=3）  
2. 业务 egress 增加节点指向 `1080` 或直连口  
3. 质量守卫改为调 `/rotate` 而非 `docker restart warp-chen`  
4. 稳定后停 `warp-chen` / `warp-socks`  

细节不进本仓库 README，可另写运维笔记。

---

## 12. 许可与归属

- 仓库自有代码：**MIT**（建议）
- 不整仓 fork Ercin（CC-BY-NC）以免传染；**只借鉴行为与端口习惯**
- MicroWARP / wgcf：MIT 或项目自带许可，引用声明

---

## 13. 审查修订记录

| 日期 | 来源 | 结论 |
|------|------|------|
| 2026-08-05 | Oracle 对抗审查 | **revise**（不 block）。阻塞 B1–B5 已写入本文与 ADR-007..011 |

## 14. Phase 1 开工前清单（猜错返工）

| # | 必须先定/先测 | 猜错后果 |
|---|---------------|----------|
| 1 | conf：`WGConfig` wrapper + `[Socks5]`（§3.2） | 数据布局/entrypoint 全改 |
| 2 | 权限：无 tun、无 `NET_ADMIN` 能否通 | compose/安全基线重写 |
| 3 | 单实例 RSS → 外推 N=5 是否 ≤120MB | 内存目标/是否砍组件 |
| 4 | 子进程：Phase 1 挂了容器非 0；Phase 2+ 降级 | 多实例全面返工 |
| 5 | 钉死 `wgcf` / `wireproxy` 版本 | 不可复现构建 |
| 6 | 聚合：自写 RR 为默认（不在 Phase 1 写死 gost 唯一路径） | Phase 3 推倒生成脚本 |
| 7 | `PARTIAL_REGISTER_POLICY` 默认 degraded | Phase 2 运维语义 |

## 15. 下一步（等你一句「开始 Phase 1」）

1. Phase 1：最小 Dockerfile + 单 `wireproxy` 冒烟（三问：通？cap？RSS？）  
2. 冒烟结果回写 §10、ADR-010、钉死版本  
3. 再进 Phase 2  

**当前冻结决策：** 路线 B1（wgcf + wireproxy × N + **自写 RR 聚合** + rotate API）；监督模型 §3.4；内存正式上限 120MB；IP 互异为尽力；单容器通用产品。目标见 §1.2。
