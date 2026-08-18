# Pivot v0.5.7 — 自愈逻辑纠偏

**Plan**: [../.omo/plans/v0.5.7-selfheal-logic.md](../.omo/plans/v0.5.7-selfheal-logic.md)  
**Trigger**: 现网 9bfef8e 出现 1/5、members 空、同 IP 6 连杀、start lock timeout、entrypoint 全死自杀。

## One-liner

同 IP 仅在与**它人冲突**时重试；自动 rotate 加冷却；start 锁缩短；health 单飞；rotate 不嵌套全量 health；sticky 跟随健康。

## Ship order

WP0 (P0.1–0.4) → WP1/2 (P1) → WP3 (P2) → smoke → GHCR → 现网 A1–A8

## Non-goals

IP 黑名单、换栈、guard 大改、WebUI 翻版。
