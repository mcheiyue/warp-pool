# 上游调研摘要

收集日期：2026-08-05。供 warp-pool 规划引用，非背书。

## 现网

| 名称 | 镜像 | 内存（实测） | 备注 |
|------|------|--------------|------|
| warp-chen | caomingjun/warp:latest | ~96MB | 官方 client + 代理 |
| warp-socks | ghcr.io/mon-ius/docker-warp-socks | ~26MB | 另一 SOCKS 封装 |

## 路线 A（官方 client 多实例）

- **ErcinDedeoglu/cloudflare-warp**（alkaid 等 fork）
  - `WARP_INSTANCES=N`
  - 每实例独立 `STATE_DIRECTORY` / `RUNTIME_DIRECTORY` / dbus
  - 直连端口 `40000+i`；GOST round-robin `:1080`
  - 启动错峰、注册退避、健康失败重启、shutdown 时 registration delete
  - 内存宣称 ~50–100MB/实例
  - License: **CC-BY-NC-4.0**
- **cmj2002/warp-docker (caomingjun/warp)**：单实例，现网在用

## 路线 B（wgcf / 轻量）

- **ccbkkb/MicroWARP**（MIT，高星）
  - wgcf register → conf 清洗 → `wg-quick up` → microsocks
  - ~800KB–数 MB；单 `wg0`
  - Endpoint/MTU/保活可配；阅后即焚 account 文件
- **ViRb3/wgcf**：注册与 profile 生成标准工具
- **kingcc/warproxy**：wgcf + wireproxy 单实例组合
- **ayush1920/WarpNet**：netns 多 profile + WebUI；**宿主机安装**，非单容器产品
- **baby9/wgcf-socks-docker**、**underhax/mihomo-warp-proxy**：单隧道变体

## 易混淆（不要当出口池基线）

- **WARP-Clash-API** 系：Clash 订阅 + 刷流量 + IP 选优 → 产品目标不同
- `思路.md` 中的 neilpang/warp-spot、SearchNet 链接：**未找到可靠仓库**

## 对 warp-pool 的直接启发

| 来源 | 采纳 |
|------|------|
| Ercin | 端口矩阵、错峰注册、healthy 集合、失败摘除、**STATE/RUNTIME 隔离 multi**（v0.2）；聚合改用自有 warppool 不默认 gost |
| MicroWARP / warproxy | 曾支撑 B1；**换 IP 证伪后降为 legacy** |
| WarpNest / 思路.md | 多独立 IP 产品直觉 |
| 现网 caomingjun | reconnect/restart 可换 IP；单实例 ~80–110MB |
| 2026-08-05 探针 | 见 `docs/probe-official.md`：官方 N=2 ~265MB、IP 互异、rotate 有效 |

## 关键实现细节备忘

### Ercin 多实例隔离

- `DATA_DIR=/var/lib/cloudflare-warp/instance-${i}`
- `RUNTIME_DIRECTORY=/run/warp-${i}`
- 每实例独立 dbus socket
- `warp-cli mode proxy` + `proxy port $PORT`

### MicroWARP 单实例流程

1. 无 conf → 下 wgcf → register → generate → 移到 `/etc/wireguard/wg0.conf`
2. 删 IPv6/DNS 噪音，注入 MTU、AllowedIPs、Keepalive、可选 Endpoint
3. `wg-quick up` + 策略路由修非对称
4. `exec microsocks`

### wgcf 注意

- license 绑定有设备数限制与已知 bug（先 register 再立刻 update license）
- 生成 profile 默认 MTU 1280
