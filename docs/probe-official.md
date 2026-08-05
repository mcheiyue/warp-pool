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
docker stats  ≈ 265 MB   （与 RSS 加总同量级）
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

说明：官方路径上 **轻量 reconnect 即可变出口**，不必每次 delete registration；delete+new 更「狠」、占设备名额，适合 reconnect 无效时的升级路径。

## 3. 与 B1（wgcf + wireproxy）对照

| | B1 warp-pool MVP | 官方 multi（本探针） |
|--|------------------|----------------------|
| N=2 mem | ~12–17 MB | **~265 MB** |
| 多实例 IP 互异 | 否（同锁 104.28.195.192） | **是** |
| soft re-register 换 IP | **0%**（换号不换出口） | **yes** |
| 无 NET_ADMIN | 是 | proxy mode 下 Ercin multi **无额外 cap** |
| 换 IP 可用性 | 证伪 | **成立** |

## 4. 对产品的硬结论

1. **换 IP / 多出口互异 → 必须官方 `warp-svc`，B1 不作主路径。**  
2. **内存优化只能砍卫星（gost→warppool、少起无用端口），不能砍 N×warp-svc。**  
3. **rotate 默认优先 `disconnect`/`connect`（或等价重连）；失败再 registration delete+new。**  
4. **出口可能是 IPv6**（本探针 RR 全为 `2a09:…`）；业务若只认 IPv4 需单独验收/强制 v4（另开项）。  
5. **许可：** 行为可借鉴 Ercin；代码与镜像自建 MIT，禁止整段复制其脚本。

## 5. 清理

探针容器/volume/镜像已删除；未改动 `warp-socks`；`warp-chen` 仅做 reconnect/restart 后已恢复 `warp=on`。
