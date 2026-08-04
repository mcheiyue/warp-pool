# Architecture Decisions

## ADR-001: 走路线 B（wgcf 轻量），不走官方 multi warp-svc

- **Status:** Accepted (2026-08-05)
- **Context:** 目标机常见 1C2G；现网 `caomingjun/warp` 单实例已 ~96MB。Ercin 多实例成熟但 50–100MB/实例。
- **Decision:** 主路径用 wgcf 注册 + 轻量转发；官方 multi 仅作形态参考。
- **Consequences:** 需自研多实例编排；换 IP 语义更可控；内存目标按 wireproxy 实测，不照搬 MicroWARP ~1MB。

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

- **Status:** Accepted (2026-08-05)
- **Context:** wireproxy 需要 WG 段 + Socks5 绑定，不能直接 `-c wgcf-profile.conf`；用户态 netstack 通常不需 tun/NET_ADMIN。
- **Decision:** 每实例 `wireproxy.conf`：`WGConfig=` 指向 `wgcf-profile.conf` + `[Socks5] BindAddress`。compose **默认不挂 tun、不加 NET_ADMIN**；Phase 1 失败再最小加权并回写本 ADR。
- **Consequences:** 数据布局多一个 conf 文件；安全基线更紧。

## ADR-011: 控制面 v1 = shell/httpd（审查高优）

- **Status:** Accepted (2026-08-05)
- **Context:** socat/shell/Go/python 四选一拖到 Phase 4 会摇摆。
- **Decision:** v1 用 busybox httpd + shell（或 nc 路由）；与 health 同运维模型。证明不够再上静态 tiny Go。
- **Consequences:** 依赖少；API 表面保持 PLAN §6 JSON 契约。
