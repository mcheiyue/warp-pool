# 官方 client 探针报告

日期：2026-08-05  
主机：美西 1C2G（与现网 warp-chen 同机）  
目的：验证「能换 IP」的官方栈在 multi / rotate 下的真实成本，指导 warp-pool 转向。

## 1. 探针 A — Ercin multi（官方 `warp-svc` ×2 + gost）

镜像：`dublok/cloudflare-warp:latest`（**仅探针**，不引入其 CC-BY-NC 代码）  
`WARP_INSTANCES=2`，旁路 `127.0.0.1:19080→1080`，测完即删。

| 项 | 结果 |
|----|------|
| 就绪 | ~20s 内 `2/2 WARP instances ready` |
| docker stats | **~265 MiB**（rotate 后 ~262 MiB） |
| warp-svc RSS | **109172 + 108860 KB**（≈2×109 MB） |
| gost RSS | **46856 KB**（go-gost，偏重） |
| dbus×2 + sudo/脚本 | 各数 MB，可忽略 |
| `warp=` | 两口均为 `on` |
| 直连 40000 / 40001 出口 | **两个不同 IPv6**（`2a09:bac1:76a0:…` vs `2a09:bac1:7680:…`） |
| 聚合 RR 8 次采样 | **严格交替两个 IP** |
| rotate：实例0 `registration delete` → `new` → `mode proxy` → `connect` | **IP 变化 = yes**（换到 `2a09:bac5:636c:…`） |

### 内存拆解（N=2）

```
2 × warp-svc  ≈ 218 MB   ← 不可共享
1 × gost      ≈  47 MB   ← 可换成 warppool，目标降到数 MB
卫星进程     ≈  数+10 MB
docker stats  ≈ 265 MB
```

**外推：** N 份官方出口 ≈ **N × ~110MB（warp-svc）+ 1 × 聚合**。  
1C2G 上 N=2 可旁路；N=5 ≈ 550MB+ 不适合默认常驻。

## 2. 探针 B — 现网 `warp-chen`（caomingjun/warp）换 IP

| 操作 | 结果 |
|------|------|
| 基线 mem | ~83 MiB（stats） |
| `warp-cli disconnect` + `connect` | **RECONNECT_IP_CHANGED=yes** |
| `docker restart warp-chen` | **RESTART_IP_CHANGED=yes** |
| 测后状态 | `warp=on`，服务恢复 |

说明：官方路径上 **轻量 reconnect 即可变出口**；delete+new 更「狠」，适合 reconnect 无效时的升级路径。

## 3. 与 B1（wgcf + wireproxy）对照

| | B1 warp-pool MVP | 官方 multi（本探针） |
|--|------------------|----------------------|
| N=2 mem | ~12–17 MB | **~265 MB** |
| 多实例 IP 互异 | 否（同锁 104.28.195.192） | **IPv6 是** |
| soft re-register 换 IP | **0%** | **yes** |
| 无 NET_ADMIN | 是 | proxy mode 下可无额外 cap |

## 4. IPv4 与宿主机直连（后续跟进）

- 默认 `cdn-cgi/trace` 常返回 **IPv6**；对 `1.1.1.1` / `ipv4.icanhazip.com` 强制 v4 可得 **IPv4 + warp=on**。
- `warp-cli proxy port` 文档写明只绑 **`127.0.0.1:{port}`**，Docker 映射宿主机端口会 FAIL；v0.2 用 `warppool expose` 在 `0.0.0.0:11000+i` 做 TCP 中继。
- IPv4 双实例是否互异、reconnect 是否换 v4：见后续实测记录（本节不预先当验收通过）。

## 5. 对产品的硬结论

1. **换 IP / 多出口 → 官方 `warp-svc`**；B1 不作主路径。  
2. **内存优化只能砍卫星**，不能砍 N×warp-svc。  
3. **rotate 默认 reconnect**，失败再 hard re-register。  
4. **许可：** 行为可借鉴 Ercin；代码自建 MIT。

## 6. 清理

Ercin 探针容器/镜像已删；`warp-chen` reconnect/restart 后已恢复。
