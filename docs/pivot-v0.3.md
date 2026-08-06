# warp-pool v0.3：Warp 模式 + netns 隔离 + 单页 WebUI

日期：2026-08-06  
依据：双容器 Warp 探针（v4 互异 + 单边 restart 换 v4）、v0.2 Proxy multi 证伪（v4 粘）、产品目标「单容器调度优先」。

## 1. 产品目标（不变 + 钉死）

| 优先级 | 目标 | v0.3 做法 |
|--------|------|-----------|
| P0 | 多独立出口（**IPv4** 可测） | 每实例 **Warp 模式** + **独立 netns** |
| P0 | 可切 IP（**IPv4**） | rotate = **重启该实例**（对齐 chen / 双容器探针） |
| P0 | **一个容器内**完成调度 | 单镜像；control API + **单页 WebUI** |
| P0 | 按端口直连或池内 RR | expose `11000+i` + aggregate `:1080` |
| P1 | 通用、MIT、不绑业务 | 保持 |
| P2 | 内存尽量低 | 接受 ~80–110MiB×N；不牺牲 v4 换 IP |

### 验收（必须可复制）

1. N=2：直连两口 `ipv4.icanhazip.com` **互异**（允许偶发相同，主验「常互异」）。  
2. `POST /rotate?id=0`（或 WebUI 点旋转）：口 0 的 **v4 变化**；口 1 尽量不变且仍健康。  
3. 聚合 `:1080` RR 仍通；摘除不健康实例后池不整死。  
4. WebUI：列表实例 / 健康 / v4·v6 / 一键 rotate / 看聚合状态（只读+写操作带 token）。  
5. 默认 N=2，1C2G 旁路可跑；权限文档写清（NET_ADMIN / tun / netns）。

## 2. 为什么必须离开 v0.2 Proxy

| | v0.2 WarpProxy | 双容器 Warp 探针 | v0.3 目标 |
|--|----------------|------------------|-----------|
| v4 互异 | 常撞车 | **稳** | 对齐探针 |
| restart 换 v4 | 否 | **是** | rotate=实例重启 |
| 单容器 | 是 | 否（两容器） | **netns 模拟多容器** |
| 调度 API | 有 | 无 | 保留 warppool + UI |

同 netns 多 `mode warp` 会抢 TUN/路由 → **必须每实例一个 netns**（逻辑 = 每实例一个 mini-chen）。

## 3. 目标架构

```
[docker run 一个容器]
entrypoint (PID1)
  ├─ netns wp0
  │    dbus + warp-svc (Mode: Warp, STATE=instance-0)
  │    + 出口 SOCKS 127.0.0.1:40000   (gost 或等价，仅本 ns)
  ├─ netns wp1
  │    … 同理 :40001
  ├─ 主 netns
  │    warppool expose  :11000 → 进入 ns0 的 40000（nsenter/socat/自写）
  │    warppool expose  :11001 → ns1
  │    warppool aggregate :1080  ← healthy.json
  │    warppool control   :9090  ← JSON API
  │    warppool webui     :9080  ← 单页（或 control 同端口 /ui/）
  │    health-loop
  └─ SIGTERM：逐 ns 停 warp；可选 deregister
```

### rotate 语义（v0.3 默认）

```
rotate(id):
  1. 从 healthy 摘除 id
  2. 停 netns-id 内 warp-svc（+ socks）
  3. 再 start（同 STATE 优先；--hard 可清 reg 再注册）
  4. probe v4 + warp=on 通过 → 回池
  5. cooldown 不变
```

**不再**把 disconnect/re-register 当 v4 换 IP 主路径（Proxy 时代遗留）。

### 权限（预期）

- `NET_ADMIN`、`/dev/net/tun`（或 device cgroup rule）  
- 创建 netns：常需 `SYS_ADMIN` 或 `CAP_SYS_ADMIN`（文档写死；能降权再降）  
- **对比 v0.2「无 cap」叙事作废**

## 4. 代码调整规划（按模块）

### 4.1 保留（壳）

| 路径 | 动作 |
|------|------|
| `cmd/warppool` aggregate / control | 保留；扩展 API 字段（mode=warp、v4、v6、netns） |
| healthy.json 契约 | 保留；backends 增加 `v4`/`v6`/`status` |
| cooldown / token / DEREGISTER 开关 | 保留 |
| GHCR workflow | 保留；改 cap 文档与 compose |

### 4.2 重写（芯）

| 路径 | 动作 |
|------|------|
| `scripts/lib.sh` | netns 创建/删除、`ip netns exec`、`wcli` 进 ns、`probe_v4` |
| `scripts/start-instance.sh` | **在 ns 内**起 dbus+warp-svc；`mode warp`；connect；ns 内 SOCKS |
| `scripts/stop-instance.sh` | 停 ns 内进程；不默认删 ns（rotate 复用） |
| `scripts/rotate-instance.sh` | **默认 restart 实例**；`--hard` 清 STATE 再注册 |
| `scripts/ensure-instance.sh` | 准备 STATE 目录 + 确保 netns 存在 |
| `scripts/health-once.sh` | 经 expose 口测 v4 + warp=on；写 v4/v6 进 meta |
| `entrypoint.sh` | 串行建 ns→start→healthy；监督按 ns；权限自检 |
| `Dockerfile` | 保留 cloudflare-warp；加 `iproute2`；gost 或静态 socks；**web 静态资源** |
| `docker-compose.yml` | cap_add / devices / sysctls 对齐 chen；端口 1080/11000+/9090/**9080** |

### 4.3 新增

| 路径 | 用途 |
|------|------|
| `scripts/netns-*.sh` 或并入 lib | ns 生命周期 |
| `web/` 或 `cmd/warppool/ui/` | 单页 WebUI 静态文件 |
| `docs/probe-warp-netns.md` | P1 门禁记录 |
| `tests/smoke-v03.sh` | 19xxx 旁路；**强制 -4 测 v4** |
| `deploy/compose-multi-warp/`（可选保底） | P1 失败时的多容器对照 |

### 4.4 废弃 / 降级

| 项 | 处理 |
|----|------|
| 默认 `mode proxy` | 删除或 `WARP_MODE=proxy` 遗留开关（默认 off） |
| 「无 NET_ADMIN」默认 | 文档与 compose 改为 **需要 cap** |
| rotate=reconnect 换 v4 承诺 | 改为 restart；reconnect 仅作可选实验 |
| v0.2 内存「无 cap 轻量」叙事 | STATUS 标明 superseded by v0.3 |

## 5. 单页 WebUI 规划

### 5.1 原则（ponytail）

- **一个 HTML 页**（可内联 CSS/JS），无 React/Vue 构建链  
- 只调本机 control API（同域或相对路径）  
- 无后端模板引擎；由 warppool 提供 `GET /` 或 `GET /ui/` 静态  

### 5.2 功能（v0.3 最小）

| 区块 | 内容 |
|------|------|
| 顶栏 | 池状态、聚合口、N、内存提示（若 API 有） |
| 实例表 | id / healthy / v4 / v6 / warp / last_rotate / 操作 |
| 操作 | Rotate（默认）/ Hard rotate（确认框） |
| 聚合 | 最近 healthy 列表；一键复制 socks 地址 |
| 设置 | 只读显示 cooldown、token 是否启用（不显示 secret） |
| 鉴权 | 若 `CONTROL_TOKEN` 设置：页顶输入 token，写入 `Authorization` 或 query（与 API 一致） |

### 5.3 API 扩展（供 UI）

现有大致保留，建议补：

```
GET  /instances          → [{id, healthy, addr, v4, v6, warp, last_rotate, mode}]
GET  /health             → {ok, backends: [...]}
POST /rotate?id=&mode=   → mode=restart|hard（默认 restart）
GET  /meta               → {version, instances_n, aggregate, ui: true}
```

UI **不**直连 Docker socket；一切经 control。

### 5.4 实现落点

- `cmd/warppool`：`control` 子命令增加 `embed` 静态（`//go:embed ui/*`）或读 `/opt/warp-pool/web`  
- 默认 `WEBUI_BIND=127.0.0.1:9080` 或挂在 `9090/ui/`（二选一，实现时锁一个）  
- **推荐**：同 9090 下 `/ui/` + API 仍在 `/instances` 等，少开端口  

### 5.5 非目标（WebUI v0.3）

- 用户体系 / HTTPS 终结（反代交给宿主机 Nginx）  
- 实时 websocket 大盘（轮询 3–5s 足够）  
- 多语言（先中文或中英简单切换，可只中文）  

## 6. 分期交付（代码顺序）

### Phase G0 — 门禁（阻塞产品编码）

**单容器 netns×2 最小探针**（可临时脚本，不必完整 UI）：

- 建 2 netns → 各 Warp → 测 v4 互异  
- 重启 ns0 进程 → v4 变、ns1 不变  

**通过 → G1；失败 → 启用保底多容器 compose，UI/API 仍做，芯改外挂容器。**

### Phase G1 — 芯替换

- lib/start/stop/rotate/health/entrypoint 全面 Warp+netns  
- Dockerfile/compose 权限  
- smoke-v03：v4 强制  

### Phase G2 — API 对齐

- instances 带 v4/v6  
- rotate 默认 restart  
- 文档 ADR-015  

### Phase G3 — WebUI

- 单页 + embed  
- token 输入  
- smoke：curl API + 可选浏览器看一眼  

### Phase G4 — 发布

- README/STATUS/PLAN banner  
- GHCR  
- VPS 19xxx 完整旁路（不碰 chen:1080）  
- 清理旧 proxy 默认路径  

## 7. 风险与回退

| 风险 | 回退 |
|------|------|
| 容器内 netns 权限不够 / 不稳定 | `deploy/compose-multi-warp`：N×caomingjun + warppool 控制+UI |
| CF 偶发 v4 相同 | 验收「常互异」；UI 标黄「出口可能重复」 |
| warp-svc 泄漏 | MemoryMax + 周期 rotate 文档 |
| UI 误触 hard rotate | 确认框 + cooldown + token |

## 8. 明确不做（v0.3）

- 继续优化 Proxy multi 换 v4  
- Fork Ercin 源码  
- 重型前端框架  
- 默认 N=5 常驻 1C2G  
- 与 grok/业务配置耦合  

## 9. 成功样子（给自己看的）

```text
docker run … --cap-add=NET_ADMIN … ghcr.io/mcheiyue/warp-pool:v0.3
→ 浏览器打开 http://127.0.0.1:9090/ui/
→ 两行实例，两个不同 v4
→ 点 Rotate #0 → 数秒后 #0 的 v4 变了，#1 不变
→ socks5://127.0.0.1:1080 仍在 RR
```
