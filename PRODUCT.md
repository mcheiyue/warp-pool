# Product

## Register

product

## Users

自用运维（单人或极小团队）。通过 SSH 隧道打开管理面，在夜间或故障时快速判断出口池健康、换 IP、入池/出池、粘性钉死，并核对「哪次请求走了哪个 backend」。

## Product Purpose

warp-pool 是多实例 Cloudflare WARP 的 SOCKS 出口池。业务只认聚合口；控制台负责成员、粘性、换 IP、历史与路由审计。成功标准：不猜状态、不找按钮、少滚动完成一次排障闭环。

## Brand Personality

克制、密实、可审计。像机房值班台，不像营销看板。

## Anti-references

- 紫/蓝渐变 dark SaaS 仪表盘
- 大号 hero 指标卡 + 装饰图标网格
- 玻璃拟态、无意义动效、宽留白营销布局
- 现网 UI 的堆叠面板与信息重复

## Design Principles

1. 状态先于装饰：健康、入池、粘性一眼可扫。
2. 密度服务排障：表优于卡，行内操作优于弹层。
3. 操作可逆且可确认：破坏性动作有明确动词与后果。
4. 审计可追：IP 与路由记录与实例 id 对齐。

## Accessibility & Inclusion

对比度优先（正文 ≥4.5:1）；键盘可达；`prefers-reduced-motion` 降级；色盲友好状态不只靠颜色（文案 + 形状）。
