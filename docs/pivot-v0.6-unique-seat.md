# Pivot v0.6 — 池内互异座位 + chen 式重抽

**Plan**: [../.omo/plans/v0.6-unique-seat-hard-rotate.md](../.omo/plans/v0.6-unique-seat-hard-rotate.md)

## One-liner

换 IP = hard 重抽（对齐 chen）；已入座 unique **禁止**被 collision 互踢；未入座者有限次 hard，仍撞则本轮不入座。

## Evidence (2026-08-18)

- history: `restart` 253 vs `hard` 25；`195.192` ×60  
- boot: id0 seat 195.192 → id1 `v4_collision exhausted at boot`  
- 现网: `HEALTH_AUTO_ROTATE=1`, compose `ROTATE_MODE=restart`, dirs=5 / env N=2  

## Non-goals

旁观冒充多出口、IP 黑名单、换栈。
