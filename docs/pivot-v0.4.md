# warp-pool v0.4 规划

日期：2026-08-06  
基线：v0.3（Warp + netns + WebUI，G0/smoke 已 PASS）  
原则：单容器调度优先；IPv4 可测可切；不绑业务；MIT。

## 1. 目标一句话

在 v0.3 可用基础上，把 **交付链路、权限、内存、运维体验、配置热加载、rotate 后 v4 互异保证** 做到可日常使用。

## 2. 范围（纳入 / 剔除）

### 纳入

| 来源 | 项 | 说明 |
|------|----|------|
| P0 | 多架构镜像 | 解决 gost arm64 404；优先 microsocks 或自编译 |
| P0 | git/CI 交付修复 | VPS 或 token 可 push；补丁进 GHCR |
| P0 | STATUS/文档同步 | 与真实状态一致 |
| P1 | 降权 | 尽量去掉 `privileged`，最小 caps + tun |
| P1 | 内存优化 | microsocks 替 gost；expose 合并；可选 N=1 |
| P1 | netns 清理稳健 | 启动/重启兜底，消除 RTNETLINK 复发 |
| P2 | WebUI 增强 | v6、last_rotate、cooldown、批量 rotate、聚合状态 |
| P2 | rotate 策略 | schedule / on-fail；与互异保证联动 |
| P2 | 日志 | `/data/logs/` 结构化、保留策略 |
| P3→v0.4 | **配置热加载** | 不整容器重启即可改 N / 启停实例 |

### 明确剔除（本版不做）

- N>2 验证 / soak
- Prometheus/Komari 监控接入
- 健康检查精度扩展（v6 探测、延迟写入 meta 等）

## 3. 工作包

### WP-A 交付与文档（原 P0）

1. 打通 push：VPS git remote + token 或本地网络修复。  
2. 多架构：Dockerfile 去掉「仅 amd64 gost」死路；microsocks 静态多 arch 或 go 编译 gost。  
3. CI：matrix amd64（+arm64 若依赖就绪）；`latest` 与 `v0.4` tag。  
4. 更新 `STATUS.md`、README、ADR（降权/互异/热加载）。

### WP-B 运行时硬化（原 P1）

1. **降权探针**：`cap_add: [NET_ADMIN, SYS_ADMIN]` + `/dev/net/tun` + 必要 sysctl，对比 `privileged`。  
2. **内存**：gost → microsocks（或等价轻量 SOCKS）；评估多 expose 合并为单 warppool 多路。  
3. **netns 生命周期**：entrypoint 启动时 `umount -l /run/netns`、清空、`mount --make-shared`；失败重试；stop 时可选保留 ns 仅杀进程。

### WP-C 体验与策略（原 P2）

1. WebUI：暗色保留；展示 v4/v6、last_rotate、cooldown 倒计时；批量 rotate；聚合 healthy 数。  
2. rotate：`mode=restart|hard`；`HEALTH_AUTO_ROTATE` 实测；可选 `ROTATE_SCHEDULE`（cron 式或 interval）。  
3. 日志：rotate/start/health 写入 `/data/logs/*.log`，按天或体积滚动。

### WP-D 配置热加载（原 P3，升入 v0.4）

目标：**不 `docker restart` 整容器**，即可：

| 操作 | 行为 |
|------|------|
| 增加实例 | 建 netns + start + 健康后入池 + 动态 expose 端口（若已 publish 范围） |
| 减少实例 | 摘池 → stop → 可选 drop-netns；端口空出 |
| 改 `WARP_INSTANCES` | 通过 control API 或 `/data/config.json` 热读 |
| 改 token/cooldown 等 | 热读配置文件或 API PATCH |

约束：

- Docker **未映射**的宿主机端口无法热加 publish → 文档要求 compose 预留 `11000-1100N` 或只用聚合口。  
- 热减实例默认 **不** deregister（与 `DEREGISTER_ON_SHUTDOWN` 对齐可配）。  
- API 草案：`POST /instances`（add）、`DELETE /instances?id=`、`GET /config`、`PUT /config`（字段白名单）。

#### 热配置：端口 publish 上限（D3）

容器启动后 **无法** 再向宿主机新增 `-p` 映射。热增实例只能占用 compose 已预 publish 的 `EXPOSE_PORT_BASE`…`+N`（默认 `11000-1100N`）。未预留端口时：可热建 netns/WARP 并入聚合 `:1080`，但直连 expose 口不可用。运维：按最大预期 N 写死端口范围，或只用聚合口。

#### expose-merge 决策（B4）

v0.4 **不做**「多个 warppool expose 进程合并为单进程多路」。每路 expose 仅数 MB，合并省内存有限，却要改 warppool 监听模型与故障隔离，风险高于收益。除非日后实现 trivial 到可单文件落地，否则保持一实例一 expose。

### WP-E v4 互异保证（见 §4，核心新需求）

## 4. 单实例 rotate 后仍保证池内 v4 互异

### 4.1 问题

Cloudflare 分配 **不保证**：

- restart 后 v4 一定变化；  
- 新 v4 与 **其他实例** 一定不同。

v0.3 验收是「常互异 + 本口 v4 变化」。若要 **硬保证「池内 pairwise 互异」**，必须在软件层做 **探测 → 比较 → 冲突重试**，不能只靠一次 restart。

### 4.2 需要的调整

| # | 调整 | 说明 |
|---|------|------|
| 1 | **rotate 后互异校验** | probe 本实例 v4；读其他 healthy 实例 meta 的 v4；若命中冲突 → 不入池 |
| 2 | **冲突重试策略** | 默认再 `restart`（同 STATE）最多 `V4_UNIQUE_RETRIES`（如 3）；仍冲突则 `hard`（清 STATE 重注册）再试 `V4_UNIQUE_HARD_RETRIES`（如 1～2） |
| 3 | **退避** | 重试间隔 `V4_UNIQUE_BACKOFF`（秒，可抖动），避免打爆 CF |
| 4 | **boot 路径同样校验** | `start-instance` / entrypoint 就绪后也跑 uniqueness；冲突则对该 id 走同上重试，避免启动就撞车 |
| 5 | **回池门禁** | 仅「healthy **且** unique」写入 `healthy.json`；冲突期间保持摘除，聚合不指向该 backend |
| 6 | **API/UI 语义** | rotate 响应带 `v4`、`changed`、`unique`、`attempts`；冲突耗尽返回 409 或 `ok:false` + `reason=v4_collision` |
| 7 | **并发 rotate 锁** | 已有 per-id lock；**全池 uniqueness 检查要读一致快照**（短全局读锁或串行 uniqueness 段），避免两实例同时 rotate 换到同一新 IP |
| 8 | **（可选）短时黑名单** | 记录本池最近出现的 v4，prefer 不落回刚让出的 IP（尽力，非硬保证） |
| 9 | **文档预期** | 写清：互异是 **尽力+重试后的产品保证**；极端 CF 池枯竭时可能失败，调用方应处理 409 |

### 4.3 不做的误解

- **不能**在应用层「指定」出口 IPv4。  
- **不能**仅靠 disconnect/reconnect（v0.2 已证伪）。  
- 互异保证 **增加** rotate 延迟与 hard 注册成本，换的是确定性。

### 4.4 验收（v0.4 新增）

1. 人为或脚本连续 `POST /rotate?id=0` 多次：成功时 `unique=true`，且与 id=1 的 v4 不同。  
2. 模拟冲突（测试钩子或 mock meta）：触发重试日志，最终 unique 或明确失败。  
3. 冲突未解除期间：聚合 `:1080` 不含该 id；peer 仍通。

## 5. 实施顺序

```
1. WP-A 交付（push + 文档）— 否则后续改动进不了 GHCR
2. WP-E 互异保证 — 产品硬需求，尽早进 rotate/health
3. WP-B netns + 降权 + microsocks
4. WP-D 热加载（依赖稳定 start/stop）
5. WP-C WebUI / schedule / 日志
```

门禁：

- G0 类：降权 compose 下 N=2 boot + rotate 仍 PASS。  
- 互异：§4.4。  
- 热加载：API 加减实例后 healthy 与端口行为符合文档（预留端口前提下）。

## 6. 风险

| 风险 | 缓解 |
|------|------|
| CF 短时同 v4 | 重试 + hard；超时失败可观测 |
| hard 注册限频 | 退避；默认少 hard |
| 降权失败 | 保留 privileged 文档路径为 fallback |
| 热加载 vs Docker 端口 | 预 publish 范围；或仅热管理聚合后端 |
| microsocks 行为差 | 对照 gost 做 SOCKS5 smoke |

## 7. 非目标（重申）

- 现网强制切掉 warp-chen（可另开「切流 runbook」，不默认进 v0.4 必做）  
- N>2 soak、监控、健康精度扩展  

## 8. 文档与 ADR

| 文件 | 动作 |
|------|------|
| `docs/pivot-v0.4.md` | 本文件 |
| `.omo/plans/v0.4-hardening-hotconfig.md` | 可执行 WP 清单 |
| `docs/decisions.md` | ADR：互异重试；microsocks；降权；热加载 |
| `docs/STATUS.md` | primary → v0.4 planning |

---

**结论**：v0.4 = 交付打通 + 运行时硬化 + 体验/策略 + **配置热加载** + **rotate/boot 后 v4 池内互异保证（探测+重试+回池门禁）**；不做 N>2、监控、健康精度扩展。
