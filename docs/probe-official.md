## 官方 client 重启换 IP 的真实表现（2026-08-05 实测）

warp-chen 重启现象：
- 重启前：104.28.165.131
- 重启后：104.28.165.53
- 再次重启：104.28.165.132

**原因**：Cloudflare WARP 使用 CGNAT + 重启分配策略，**不是每次 restart 都换一个全新干净 IP**，而是走一个「最近可用 IP」池。重启后出口变化的概率低。

**对我们的启示**：
- reconnect/disconnect 更可靠（轻量，不占设备名额）
- registration delete + new 更彻底，但要等冷却
- IPv6 比 IPv4 更稳定（v6 出口更易变）

此现象已记录在 `docs/probe-official.md`，供后续 rotate 策略参考。
