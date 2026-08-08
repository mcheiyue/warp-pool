# warp-pool v0.5 规划：可控聚合池

日期：2026-08-07（Momus 返工修订）  
基线：v0.4（Warp+netns、热加减、v4 互异、WebUI）  
原则：单容器调度优先；业务默认只认 **一个 SOCKS 入口**；不绑具体上游业务。

## 1. 一句话目标

把聚合口从「只读 RR 健康列表」升级成 **可运维的出口池入口**：

- **业务只配一个口**，永远不改。  
- **默认**：容器自行 RR 分流到健康+互异实例。  
- **API 控制**：全局粘性——外部调一下，聚合口固定走指定实例；恢复时回 RR。  
- 成员可进可出（不杀进程）；状态可观测。

## 2. 现状

### 2.1 聚合实现（main.go L119-255）

```
runAggregate()
  → getBackends(): ≤2s 缓存读 healthy.json → []backend{id, addr}
  → serveSocks(): SOCKS5 握手 → RR 轮询 backends → dialViaSocks → relay
```

- **没有粘性概念**：每次新连接都 RR 下一个。  
- **没有 sticky 文件**：选路完全靠 `healthy.json` 的 backends 顺序 + rr 计数器。  
- **backends 是 `{id, addr}`**，不含 weight / sticky。  
- control 与 aggregate 是 **两个进程**；`PUT /config` 的 `os.Setenv` 只影响 control。

### 2.2 入池实现（health-once.sh）

```
for id in 0..N-1:
  alive? → probe → unique? → 写 backends_json
写 healthy.json
```

- 入池 = 进 `backends_json`；不入 = 不写。  
- **没有 pooled 字段**：只有 healthy/unhealthy 二态。  
- 实例进程活着但想「临时不参与聚合」→ **做不到**（除非手动 kill 进程）。

### 2.3 `write_meta` 契约（实现约束，P0 必守）

现状（`scripts/lib.sh`）：

```bash
write_meta() {  # id healthy v4 failures last_rotate pid v6 unique
  jq -n ... '{ id, healthy, unique, v4, ... }' > meta.tmp && mv
}
```

- **全量覆盖、不读旧 meta**。  
- 调用点：`health-once.sh`（约 5 处）、`rotate-instance.sh`、`commit_if_unique` / `ensure_instance_unique` 等。  
- **若不改为 merge，membership 设 `pooled=false` 会在下一轮 health-once 被抹掉。**

### 2.4 缺口

| 能力         | 现状                                  |
| ------------ | ------------------------------------- |
| 成员可控     | ❌ 无 pooled 字段；只有 kill 才能出池   |
| 全局粘性     | ❌ 无 sticky 机制；每次连接都 RR       |
| rotate 排空  | ❌ 靠 lock skip，不够顺               |
| 聚合状态观测 | ❌ `/health` 只有 healthy/total        |
| 直连 vs 聚合 | 直连 `11000+i` 与聚合正交但文档没写清 |

## 3. 定位

| 角色              | 做什么                                      | 不做什么                        |
| ----------------- | ------------------------------------------- | ------------------------------- |
| 聚合 SOCKS `:1080` | 唯一对外口；默认 RR；sticky 时全局固定 id    | HTTP 代发、账号路由             |
| 直连 `11000+i`    | 排障 / 钉死                                 | 扩容必经之路                    |
| 控制 API / UI     | 成员开关、粘性开关、rotate、config          | 替代 SOCKS 传业务               |
| 外部守卫（可选）  | 调 pool API 做自动规则                      | 不塞进主镜像（P0）              |

## 4. 范围

### 纳入

| 优先级 | 项 |
|--------|-----|
| **P0** | `write_meta` **merge 语义** + meta：`pooled` / `exclude_reason`；`is_pool_eligible` |
| **P0** | `GET /pool`、`POST /pool/membership` |
| **P0** | `health-once` 只把 eligible 成员写入 `healthy.json` backends |
| **P0** | membership 后同步：`SUPERVISE_RESTART=0 health-once` |
| **P0** | WebUI：入池开关 + 聚合成员列表 |
| **P0** | smoke：可跑步骤 unpool / pool |
| **P1** | **全局粘性 sticky**：`POST/GET/DELETE /pool/sticky` |
| **P1** | rotate drain = 临时 unpool（无独立 drain 字段） |
| **P1** | `agg_enabled` 经 **状态文件** 跨进程（见 §7.5） |
| **P1** | `/data/logs/pool.log` |
| **P2** | weight + weighted RR（按需） |

### 剔除

- 源 IP hash / 目标域名绑定  
- SOCKS 用户名路由（已否决：和直连没本质区别）  
- 独立 `drain` 布尔字段（用临时 `pooled=false` + `exclude_reason=drain`）  
- 聚合层 HTTP 解析、多池、热改监听端口  
- 控制 API 代理业务流量  
- 任何具体上游产品的专用对接文档  

## 5. 入池条件（唯一真相）

```
pooled && alive && probe_ok && ( !V4_UNIQUE || unique ) && !rotate_lock
```

说明：

- **不引入 `drain` 字段**。rotate 排空 = 临时设 `pooled=false` + `exclude_reason=drain`，结束后恢复原 `pooled`。  
- 旧 meta 无 `pooled` 键 → 视为 `true`（兼容 v0.4）。  
- **`unique` / `v4_conflicts` 仍按 peer `healthy=true` 判断，不按 `pooled`**。出池实例若仍 healthy，继续占 unique 名额（避免两实例同 v4 一出一进造成冲突误判）。  
- `is_pool_eligible` 判定点：写入 `backends_json` **之前**；probe/写 meta 的 healthy 与是否进 backends **解耦**（出池可 `healthy=true`，直连仍通）。

## 6. 全局粘性（sticky）—— 核心需求

### 6.1 需求

> 1. 业务从一开始就只连聚合端口  
> 2. 无 API 控制时，容器自行调度  
> 3. 有 API 控制时，指定聚合端口后为固定实例  

### 6.2 语义

| 模式              | 行为 |
|-------------------|------|
| **默认（无 sticky）** | 聚合口 RR，自动在健康+互异成员间轮流 |
| **sticky=id**     | 聚合口 **所有新连接** 固定走 id；该 id 不在 backends 或拨号失败时 **选路回退 RR** |
| **清除 sticky**   | `DELETE /pool/sticky` 删文件，恢复 RR |

### 6.3 sticky 失效策略（钉死）

- sticky 文件 **保留**（不自动 DELETE）。  
- 选路：id 不在 backends（出池/不健康）或 `dialViaSocks` 失败 → **回退 RR**。  
- UI/`GET /pool`：仍显示 `sticky.id`，可附 `effective: false`（实现可选；最少 sticky 非 null 且 members 无该 id 即表示失效）。  
- 只有显式 `DELETE /pool/sticky` 才清文件。

### 6.4 实现（基于现有代码改动最小）

**数据：** `/data/state/sticky.json`

```json
{ "id": 0, "ts": "RFC3339" }
```

不存在 = 无粘性（RR）。（不用 `id=-1` 哨兵；缺文件即 RR。）

**aggregate（main.go）：**

1. `getSticky()`：≤2s 缓存读 `sticky.json`（与 `getBackends` 同模式）。  
2. `serveSocks` 选路：

```go
backends := get()
sticky := getSticky() // nil = 无粘性
if sticky != nil {
    for _, b := range backends {
        if b.ID == sticky.ID {
            remote, err := dialViaSocks(b.Addr, target)
            if err == nil { relay; return }
            break // 拨号失败 → 回退 RR
        }
    }
    // id 不在 backends → 回退 RR
}
// 现有 RR 逻辑不动
```

3. **不改 SOCKS 协议**；客户端无感。

**control：** 见 §7.3–7.4。

**WebUI：** 实例卡「固定到此」→ `POST /pool/sticky` body；聚合面板 sticky 状态 + 清除。

### 6.5 与成员可控的关系

- sticky 指定的 id 必须 **也在 backends** 才生效，否则回退 RR。  
- unpool 该 id → 选路失效（文件可仍在）。  
- **正交：pooled = 谁上场；sticky = 全局想走谁。**

## 7. API 设计

### 7.1 `GET /pool`

```json
{
  "enabled": true,
  "strategy": "rr",
  "listen": "0.0.0.0:1080",
  "sticky": { "id": 0, "ts": "..." },
  "members": [
    { "id": 0, "addr": "10.200.0.2:40000", "v4": "x.x.x.x", "pooled": true }
  ],
  "excluded": [
    { "id": 1, "reason": "manual", "healthy": true, "v4": "y.y.y.y", "pooled": false }
  ],
  "ts": "..."
}
```

- `members`：当前 `healthy.json` backends，**`v4` 从对应 `meta.json` join**（backends 本身仍只有 id/addr）。  
- `excluded`：存在实例目录、且不在 members 的 id（含 unpool / 不健康 / rotate_lock 等）；`reason` 优先 meta.`exclude_reason`，否则可推导。  
- `sticky`：文件不存在则为 `null`。  
- `enabled`：读 `agg_enabled` 状态文件（P0 可恒 true；P1 接文件）。

### 7.2 `POST /pool/membership`

请求（**只收 JSON body**）：

```json
{ "id": 1, "pooled": false }
```

行为（锁死）：

1. 鉴权 token。  
2. 校验实例目录存在。  
3. **只改 meta** 的 `pooled` 与 `exclude_reason`：  
   - `pooled=false` → `exclude_reason=manual`（若调用方未传 reason；P1 rotate 可写 `drain`）  
   - `pooled=true` → `exclude_reason=""`  
4. 同步：`SUPERVISE_RESTART=0` 执行 `health-once.sh`（与 delete-instance 同模式；**禁止**会挂起的错误用法）。  
5. 返回更新后的 pool 摘要或 `{ok:true, id, pooled}`。  
6. aggregate **≤2s** 缓存：调用方/验收 **sleep ≥3s** 再测聚合出口。

### 7.3 `POST /pool/sticky`

**只收 JSON body**（UI 与 API 统一，不用 query `?id=`）：

```json
{ "id": 0 }
```

→ 写 `sticky.json`；aggregate ≤2s 生效。id 必须 ≥0 且实例目录存在（不要求当时一定在 backends；不在则选路回退 RR）。

### 7.4 `GET /pool/sticky` / `DELETE /pool/sticky`

- GET：文件内容或 `{"id":null}`。  
- DELETE：删 `sticky.json`；回 RR。

### 7.5 `agg_enabled`（P1，跨进程）

control 与 aggregate 两进程；**仅 `os.Setenv` 无效**。

钉死：

- 状态文件：`/data/state/agg_enabled` 内容 `1` 或 `0`（默认不存在 = `1`）。  
- `PUT /config` 白名单键 `agg_enabled`：写 runtime-config **且** 写该状态文件。  
- aggregate：`getAggEnabled()` ≤2s 缓存读文件；`0` 时 `serveSocks` **拒新连接**（SOCKS 失败/关连接即可）。  
- P0 **不实现** `agg_enabled`（恒开）。

### 7.6 `GET /instances`

返回 meta 全字段；缺 `pooled` 时 Go 侧补 `pooled: true`。

## 8. 数据

| 文件 | 用途 |
|------|------|
| `/data/instances/<id>/meta.json` | 加 `pooled`(默认 true)、`exclude_reason` |
| `/data/state/healthy.json` | 仅 eligible 成员 backends；格式不变 `{id,addr}` |
| `/data/state/sticky.json` | 新；`{id, ts}`；缺文件=无粘性 |
| `/data/state/agg_enabled` | P1；`0`/`1`；缺=1 |
| `/data/logs/pool.log` | P1；membership/sticky 变更 |

启动级不热改：`AGG_SOCKS_PORT`、`ENABLE_AGGREGATE`。

### 8.1 `write_meta` merge 语义（P0 必做）

**推荐实现 A（唯一允许的路径）：**

1. 若 `meta.json` 存在：读入旧 JSON。  
2. 用调用方传入的 **运行时字段** 覆盖：`healthy/v4/v6/failures/last_rotate/pid/unique/...`（现有参数）。  
3. **运维字段** `pooled` / `exclude_reason`：  
   - 仅当调用方 **显式传入** 时覆盖；  
   - 否则 **保留旧值**；  
   - 旧文件无键 → `pooled=true`，`exclude_reason=""`。  
4. 原子写 `meta.tmp` + `mv`。

**调用点约定：**

- `health-once` / `rotate` / `commit_if_unique` 等 **不必传 pooled**（自动保留）。  
- 仅 `POST /pool/membership`（及 P1 rotate drain 辅助）显式改 pooled。  
- 新实例尚无 meta：首轮 `write_meta` 写出默认 `pooled=true`。

**`exclude_reason` 枚举（建议）：** `""` | `manual` | `drain`（其它字符串允许但不保证 UI 文案）。

## 9. 工作包

### WP-P0 — 成员可控

1. `lib.sh`：`write_meta` 改为 **merge**；加 `is_pool_eligible`（读 pooled，缺省 true；可查 rotate_lock）。  
2. `health-once.sh`：写 `backends_json` **前** 调 `is_pool_eligible`；false 则不入 backends，但仍可写 healthy meta。  
3. `main.go`：`GET /pool`（join meta.v4）、`POST /pool/membership`（改 meta + `SUPERVISE_RESTART=0 health-once`）；`GET /instances` 缺省补 pooled。  
4. WebUI：实例卡入池开关；聚合成员/排除列表（可先简版）。  
5. `tests/smoke-pool.sh`：按 §10 可跑步骤。  
6. VPS 旁路验证。

### WP-P1 — 粘性 + 运维

1. `main.go`：`sticky.json` + `getSticky()` + `serveSocks` 选路（含拨号失败回退）。  
2. `main.go`：`GET/POST/DELETE /pool/sticky`（body only）。  
3. WebUI：「固定到此」+ 聚合面板 sticky + 清除。  
4. `rotate-instance.sh`：开始前临时 unpool（`exclude_reason=drain`）→ rotate → 恢复原 pooled；依赖 merge 的 write_meta。  
5. `agg_enabled` 状态文件 + config 白名单 + aggregate 读取。  
6. `pool.log`。  
7. AGENT/README/ADR。

### WP-P2 — 可选

1. weight + weighted RR。

## 10. 验收（P0）— 可跑步骤

前置：N=2，双实例 healthy+unique，token 已知，AGG 口可达（如 `127.0.0.1:19080`），直连 `11000+i`。

```text
# 0) 基线
GET /pool  → members 长度 2
GET /instances → 各 id 有 pooled true（或缺省视为 true）

# 1) unpool id=1
POST /pool/membership  body {"id":1,"pooled":false}
sleep 3
GET /pool  → members 仅含 id0；excluded 含 id1，reason=manual（或非空）
for i in 1..5:
  curl -4 --socks5-hostname 127.0.0.1:$AGG_PORT https://1.1.1.1/cdn-cgi/trace
  → 解析 ip= 全部 == id0 的 meta.v4
curl -4 --socks5-hostname 127.0.0.1:$((11000+1)) https://1.1.1.1/cdn-cgi/trace
  → 仍通（直连不因 unpool 断开）

# 2) pool 回 id=1
POST /pool/membership  body {"id":1,"pooled":true}
sleep 3
GET /pool  → members 长度 2

# 3) 旧 meta 兼容（可选单测/手工）
无 pooled 键的 meta → is_pool_eligible 为 true；行为=在池

# 4) 删实例回归
DELETE /instances?id=…（或既有删除 API）
→ /data/instances/<id> 不存在；ip netns list 无对应 ns；healthy.json backends 无该 id
```

## 11. 验收（P1 sticky）— 可跑步骤

```text
# 双成员在池
POST /pool/sticky  body {"id":0}
sleep 3
for i in 1..5: 聚合 curl trace → ip 全 == id0.v4

DELETE /pool/sticky
sleep 3
# N=2 双健康：多次取样应出现 ≥2 个不同 v4（允许偶发同值，建议 ≥10 次）

# sticky 失效回退（保留文件）
POST /pool/sticky {"id":1}
POST /pool/membership {"id":1,"pooled":false}
sleep 3
聚合取样 → 不应再稳定为 id1.v4（回退到剩余 members 的 RR）
GET /pool/sticky 或 GET /pool.sticky → 仍可看到 id=1（文件未自动删）
DELETE /pool/sticky → 清除
```

## 12. 默认决策

- 新实例 / 缺字段：`pooled=true`  
- sticky = **API 全局粘性**（非 SOCKS 用户名）  
- sticky 请求 **仅 JSON body**  
- sticky id 不在 backends 或拨号失败 → **选路回退 RR，不自动删 sticky 文件**  
- 策略仅 `rr`  
- 不热改监听端口  
- 直连与池成员正交  
- unique 按 healthy，不按 pooled  
- membership 同步路径唯一：`SUPERVISE_RESTART=0 health-once`  
- 验收聚合出口前 **sleep ≥3s**

## 13. 文件触达

| 路径 | 改动 |
|------|------|
| `scripts/lib.sh` | `write_meta` merge；`is_pool_eligible` |
| `scripts/health-once.sh` | backends 前 eligible 门禁 |
| `scripts/rotate-instance.sh` | P1 临时 unpool drain |
| `cmd/warppool/main.go` | `/pool*`、`/pool/sticky`、serveSocks、agg_enabled 读文件、instances |
| `web/index.html` | 入池开关 + sticky + 聚合面板 |
| `docs/AGENT.md` / `README.md` | 通用契约 |
| `tests/smoke-pool.sh` | 新，覆盖 §10 |

## 14. WebUI 改动摘要

### 现有（v0.4）

- 池状态面板：正常/降级/不可用 + 健康 N/total  
- 实例卡：v4/v6、直连端口、冷却、换 IP、删除  
- 运行配置：冷却/模式/互异/重试/自动旋转  
- 增加/目标 N  

### v0.5 新增

1. **聚合面板**  
   - 模式：RR / 粘性 id=X（可标失效）  
   - 成员 / 排除列表  
   - 清除粘性（`DELETE /pool/sticky`）  

2. **实例卡**  
   - 入池/出池 → `POST /pool/membership` body  
   - 固定到此 → `POST /pool/sticky` body `{id}`  
   - 出池灰色 + `exclude_reason`  

3. **配置（P1）**  
   - `agg_enabled` 开关 → `PUT /config`（写状态文件）

## 15. 不变

- `runAggregate` 的 SOCKS5 握手协议  
- `dialViaSocks` 上游连接逻辑  
- `healthy.json` backends 形状 `{id,addr}`  
- `expose` TCP 中继  
- 直连口 `11000+i`  
- `POST /rotate`、`POST /instances`、`DELETE /instances` 主路径（P1 仅 rotate 脚本加临时 unpool）  
- token 鉴权；`/ui` 静态无 auth（API 仍要 token）  

## 16. Momus 返工对照

| 原问题 | 本版处理 |
|--------|----------|
| write_meta 全量覆盖抹 pooled | §8.1 merge；调用点默认不传 pooled |
| §5 含 !drain 无字段 | 公式去掉 drain；drain=临时 unpool |
| membership 同步二选一 | 锁死 SUPERVISE_RESTART=0 health-once + sleep≥3s |
| Acceptance 不可跑 | §10/§11 可跑步骤 |
| agg_enabled 跨进程 | §7.5 状态文件；P0 不做 |
| sticky body vs query | 仅 body |
| sticky 出池是否清文件 | 保留文件，选路回退 |
| GET /pool 的 v4 | join meta |
| unique vs pooled | unique 仍按 healthy |
