# Architecture Decisions

## ADR-001: 走路线 B（wgcf 轻量），不走官方 multi warp-svc

- **Status:** **Superseded** (2026-08-05) → 见 **ADR-013**
- **Context:** 目标机常见 1C2G；现网 `caomingjun/warp` 单实例已 ~96MB。Ercin 多实例成熟但 50–100MB/实例。
- **Decision（原）:** 主路径用 wgcf 注册 + 轻量转发；官方 multi 仅作形态参考。
- **Why superseded:** VPS 上 B1 MVP soft re-register **换 IP 成功率 0%**（换号不换出口）；官方 multi 探针 N=2 IP 互异 + registration rotate 可换 IP。轻量不再满足核心需求「可切出口」。
- **Consequences:** B1 代码可留作历史/对照分支；主路径改官方 `warp-svc` proxy multi。

## ADR-002: v1 隔离用 wireproxy 多进程（B1），不用 netns（B2）

- **Status:** Accepted (2026-08-05)
- **Context:** 同 netns 多内核 wg 会抢默认路由；netns 正确但重。wireproxy 每进程绑定一份 conf，天然多出口。
- **Decision:** v1 = N × wireproxy；聚合层 RR。netns 留 v1.1 若性能不够再上。
- **Consequences:** 实现快；依赖 wireproxy 行为；Phase 1 必须先单实例验证权限/tun/RSS。

## ADR-003: 不整仓 fork Ercin / MicroWARP

- **Status:** Accepted
- **Context:** Ercin 为 CC-BY-NC；MicroWARP 单实例。产品要 MIT、多实例、可商用自用。
- **Decision:** 干净仓库；借鉴端口/健康/错峰注册等**行为**；代码自写或 MIT 组件组合。
- **Consequences:** 工期略长；许可清晰。

## ADR-004: 切 IP = 池内 soft re-register，禁止默认狂全量注册

- **Status:** Accepted
- **Context:** CF 对同出口频繁 register 限流；「降智」也不能靠无限换号保证。
- **Decision:** 持久化 profile；rotate 默认单实例；全量 rotate 串行 + `ROTATE_ALL_GAP` + cooldown；健康失败先摘除，过阈值再自动 soft rotate（Phase 4）。
- **Consequences:** 文档必须写清「换会话≠保证干净 IP」。

## ADR-005: 控制 API 默认本机；非 loopback 强制 token

- **Status:** Accepted（2026-08-05 修订）
- **Decision:** `CONTROL_BIND=127.0.0.1` 默认；可选 `CONTROL_TOKEN`。若 bind 非 loopback 且 token 为空 → **拒绝启动**。
- **Consequences:** compose 示例不映射 9090 到 `0.0.0.0` 除非用户显式改并设 token。

## ADR-006: 通用产品，业务零耦合

- **Status:** Accepted
- **Decision:** 仓库名、README、镜像描述不出现具体下游业务；迁移现网写在外部运维笔记。

## ADR-007: 内存与 IP 验收放宽（审查 B1/B4）

- **Status:** Accepted (2026-08-05, Oracle review)
- **Context:** N=5 ≤80MB 与「N 个 IP 必互异」写入成功标准但无实测；MicroWARP 内存不可外推；CF 池可分配相同出口。
- **Decision:**
  - 正式内存上限 **N=5 ≤120MB**；**≤80MB 为 stretch**；Phase 1 测 RSS 前不得进 CI 红线。
  - 验收主验「口通 / backend 切换 / rotate 隔离」；IP 互异为尽力，允许重复后再 soft rotate。
- **Consequences:** §1.2 #2/#3/#6、§10 已改；宣传与 CI 对齐现实。

## ADR-008: 进程监督模型（审查 B2）

- **Status:** Accepted (2026-08-05)
- **Context:** N 个 wireproxy + health + 聚合 + 控制面，无监督的 shell `&` 易半死。
- **Decision:** entrypoint 为 PID1（或 tini+entrypoint）；SIGTERM 有序停；巡检拉起。Phase 1：唯一 wireproxy 退出 → 容器 exit ≠ 0。Phase 2+：单实例挂 → 降级，不整容器退出。
- **Consequences:** 见 PLAN §3.4；多一点脚本，少 3am 事故。

## ADR-009: 聚合层 v1 = 自写 RR，gost 备选（审查 B3）

- **Status:** Accepted (2026-08-05)
- **Context:** gost 静态 YAML 不会读 `healthy.json`；热更新需 rewrite+reload，连接会抖；「gost 或自写」并列等于未决策。
- **Decision:** v1 默认极简自写 RR（读 healthy，失败跳过）。gost 仅当自写不够时引入，并必须写 reload 协议。
- **Consequences:** Phase 1 不生成 gost 配置当唯一路径；目录脚本名 `gen-aggregate.sh`。

## ADR-010: wireproxy 配置契约与权限下限（审查 B5）

- **Status:** Accepted (2026-08-05)；**VPS smoke 确认无 cap 可通**
- **Context:** wireproxy 需要 WG 段 + Socks5 绑定，不能直接 `-c wgcf-profile.conf`；用户态 netstack 通常不需 tun/NET_ADMIN。
- **Decision:** 每实例 `wireproxy.conf`：`WGConfig=` + `[Socks5] BindAddress`。compose **默认不挂 tun、不加 NET_ADMIN**。美西 1C2G smoke：N=1/N=2 均无 cap 成功。
- **Consequences:** 若某内核/环境握手失败，再最小加 cap 并记环境差异；非默认。

## ADR-012: 多实例串行 healthy 启动

- **Status:** Accepted (2026-08-05, smoke)
- **Context:** 并行拉起多个 wireproxy 时易出现双端握手失败；错峰注册不够。
- **Decision:** entrypoint 对每个实例：ensure → start → **probe 成功（或超时）** 再进下一个；`BOOT_HEALTH_WAIT` 默认 90s。
- **Consequences:** 冷启动变慢（N×握手），换稳定。

## ADR-011: 控制面 v1 = shell/httpd（审查高优）

- **Status:** Accepted (2026-08-05)；实现上已用 **warppool control（Go）**，契约不变
- **Context:** socat/shell/Go/python 四选一拖到 Phase 4 会摇摆。
- **Decision:** 控制 API 与聚合同进程族（Go 静态二进制可接受）；JSON 契约保持。
- **Consequences:** 依赖少；不因实现语言再开 ADR。

## ADR-013: 主路径改为官方 warp-svc proxy multi（2026-08-05 探针后）

- **Status:** Accepted
- **Context:** 见 [probe-official.md](./probe-official.md)。用户核心需求是**可切 IP / 多出口**，不是极致内存。B1 内存优但出口锁死；官方 N=2 ~265MB、IP 互异、rotate 有效。
- **Decision:**
  1. **隧道层：** N × 官方 `warp-svc`，`mode proxy` + 每实例独立 `STATE_DIRECTORY` / `RUNTIME_DIRECTORY` / dbus（行为对齐 Ercin，**代码自写 MIT**）。
  2. **聚合/控制：** 保留现有 `warppool aggregate|control` + healthy.json + cooldown；**不**默认上 go-gost（探针中 gost 单进程 ~47MB）。
  3. **rotate 阶梯：** 默认 `disconnect`+`connect`（chen 探针已变 IP）→ 失败再 `registration delete`+`new`（Ercin 探针已变 IP）→ 最后才动整容器。
  4. **默认 N=2**；N≥5 仅文档上限，1C2G 不作为默认验收。
  5. **权限：** proxy multi 目标无 `NET_ADMIN`/tun；与 caomingjun 默认 tunnel 模式区分。
- **Consequences:** Dockerfile 改装 `cloudflare-warp`；废弃 wgcf/wireproxy 主路径；内存叙事改为「~110MB × N + 聚合」；IPv6 出口需业务侧知晓。

## ADR-014: warp-pool v0.2 结构调整（保留壳、换芯）

- **Status:** Accepted
- **Keep:** 端口矩阵、healthy 语义、RR 聚合、control API、监督模型、GHCR CI、通用无业务名。
- **Replace:** `scripts/ensure|start` 的 wgcf/wireproxy → `start-warp-instance` 风格官方启动；rotate 调 `warp-cli`；health 探 `40000+i` 或 `11000+i` 上 `warp=on`。
- **Drop from default image:** wgcf、wireproxy 二进制（可另 tag `legacy-b1` 若仍要对照）。
- **Optional later:** 编排模式（A：多 caomingjun 容器 + 仅 warppool 控制面）作为 `deploy/compose-sidecar` 示例，主产品仍是单镜像 B。

## ADR-015: v0.3 主路径改为 Warp 模式 + netns + WebUI

- **Status:** **Accepted** (2026-08-06) — G0 netns 探针 PASS，见 [probe-warp-netns.md](./probe-warp-netns.md)
- **Context:**
  - v0.2 WarpProxy：API/聚合可用，但 IPv4 常撞车；整容器/单实例重启 **不保证换 v4**。
  - 双 `caomingjun/warp`（Mode **Warp**）旁路：v4 互异；只 restart 一侧则 **仅该侧 v4 变**。
  - G0：同容器 netns×2 Warp 亦 v4 互异 + 单边 exact-PID restart 换 v4。
  - 产品优先「一个容器内调度」，内存次要。
- **Decision:**
  1. 每实例：**独立 netns** + `warp-svc` **Mode Warp** + ns 内 **gost** SOCKS（veth `10.200.<id>.2:40000+id`）。
  2. rotate 默认 = **restart**（停 expose/gost/warp-svc 精确 PID 再起，keep STATE）；`hard` 清 STATE 再注册。禁止 `pkill warp-svc`。
  3. 保留 warppool aggregate/control；单页 WebUI 于 control 的 `/` 与 `/ui/`。
  4. 权限：`NET_ADMIN` + `SYS_ADMIN` + `/dev/net/tun`；root entrypoint。
- **Consequences:** 废弃「默认无 cap / proxy multi」叙事；v0.2 镜像逻辑 superseded；内存 ~80–110MiB×N；详见 `docs/pivot-v0.3.md`。

