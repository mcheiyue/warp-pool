# warp-pool v0.2 转向：官方芯 + 现有壳

依据：[probe-official.md](./probe-official.md)、[decisions.md](./decisions.md) ADR-013/014。

## 目标（不变）

单容器（或可选多容器编排）、多独立 WARP 出口、按端口直连或池内 RR、单实例 rotate 不拆整池、MIT、不绑下游业务。

## 核心变化

| 层 | v0.1 (B1) | v0.2 (官方) |
|----|-----------|-------------|
| 注册/隧道 | wgcf + wireproxy | **cloudflare-warp (`warp-svc`) proxy mode** |
| 每实例隔离 | conf 文件 | `STATE_DIRECTORY` + `RUNTIME_DIRECTORY` + dbus |
| 直连端口 | 11000+i | **40000+i**（与官方 proxy port 一致）或仍映射 11000+i→内部 |
| 聚合 | warppool RR | **保留** |
| 控制 API | warppool control | **保留**；rotate 实现换 `warp-cli` |
| 内存期望 | N=2 ~15MB | **N=2 ~220–270MB**（已测 ~265，gost 可再降） |

## 推荐实现形态（单镜像 B，偏产品）

```
entrypoint
  ├─ for i in 0..N-1:
  │     dbus-i + warp-svc (STATE=instance-i, proxy port=40000+i)
  │     串行：probe warp=on 再下一个（复用 BOOT_HEALTH_WAIT）
  ├─ warppool aggregate :1080  (healthy.json → 127.0.0.1:40000+i)
  ├─ warppool control :9090
  └─ health-loop / 巡检拉起
```

**相对 Ercin 的主动减负（自写时）：**

- 不启 direct/ss 多 gost 监听  
- 聚合用已有 warppool（探针里 gost ~47MB 可省大半）  
- rotate 先 reconnect，再 re-register  
- 默认 `WARP_INSTANCES=2`  
- shutdown 时 `registration delete` 防设备槽泄漏（可配置）

## 目录/脚本调整（最小 diff 思路）

| 路径 | 动作 |
|------|------|
| `Dockerfile` | 基镜像 debian/ubuntu + 装 `cloudflare-warp`；去掉 wgcf/wireproxy；保留 Go 编 warppool |
| `scripts/ensure-instance.sh` | 改为准备 `instance-i` 目录；无 conf 则等 warp-cli register |
| `scripts/start-instance.sh` | 起 dbus + `warp-svc` env 隔离 + mode proxy + port |
| `scripts/rotate-instance.sh` | reconnect；可选 `--hard` delete+new |
| `scripts/health-once.sh` | 探 `127.0.0.1:$((40000+i))` 的 trace |
| `scripts/lib.sh` | 删除 sanitize/wgcf 逻辑；保留端口/路径辅助 |
| `cmd/warppool` | **尽量不动** |
| `entrypoint.sh` | 监督对象从 wireproxy 改为 warp-svc PID |
| `legacy/` 或 branch | 可选保留 B1 以对照 |

## 验收（v0.2 探针级，取代 B1 内存红线）

1. N=2：两直连口 `warp=on`，出口 IP **不同**（允许偶发相同，主验「常不同」）。  
2. 聚合 1080：连续采样出现 ≥2 个 IP 或明确 RR 到两 backend。  
3. `POST /rotate?id=0`：该实例 IP 变化或 status 重连成功（记录成功率）。  
4. 杀一实例：聚合仍通（healthy 摘除）。  
5. docker stats N=2 **≤300MB** 冷启动 10min 内（泄漏另用 MemoryMax/周期 rotate 文档化）。  
6. 默认无 `NET_ADMIN`（proxy）；若某环境失败再记例外。

## 可选路径 A（编排，更懒）

若只想运维、不维护官方包安装：

- compose：`warp-a` / `warp-b` = `caomingjun/warp`（或 slim）  
- `warp-pool` 镜像瘦身为 **仅 warppool + health**（Docker socket 或固定 host 端口探活/rotate）  
- 适合「自己用」；产品名仍可叫 pool，但「单容器」卖点弱  

主仓库仍优先 **单镜像 B**；A 放 `deploy/compose-multi-chen/` 示例即可。

## 明确不做

- 继续把 B1 当换 IP 方案宣传  
- Fork Ercin 源码进树  
- 默认 N=5 常驻 1C2G  
- 为省 ~3MB 去共享 dbus 导致 IPC 隐患  

## 实施顺序（待你下令再写代码）

1. Dockerfile + `start-warp-instance.sh` 最小 N=1  
2. N=2 + healthy + aggregate  
3. rotate 阶梯 + control 接线  
4. 更新 README/PLAN 验收；B1 标 deprecated  
5. VPS 旁路回归（勿直接切现网 1080）
