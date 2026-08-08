# warp-pool 管理面 UI 评审

**目标文件**：`web/index.html`  
**寄存器**：product（运维控制台）  
**依据**：impeccable product register + Nielsen 启发式 + ui-ux-pro-max（a11y / 对比度 / 触控 / 层级）  
**Detector**：`detect.mjs` → `flat-type-hierarchy`（warning）、`em-dash-overuse`（warning；中文破折号与占位「—」，视为误报）  
**浏览器实机**：本轮未起 live-server（静态单文件评审）

---

## 总评

| 项 | 结论 |
|----|------|
| **总体** | **NEEDS-FIX** |
| **P0** | 0（无阻断任务完成项；未改 `index.html`） |
| **P1** | 4 |
| **P2** | 5 |
| **启发式总分** | **28 / 40**（Good：底子可用，发版前应修 a11y） |

**一句话**：增量改造方向正确（密度、OLED token、操作外露、池条、选路列表、历史表），已是可日用的运维台；主要欠账在可访问性与触控目标，不是再做一轮视觉重设计。

---

## 启发式评分

| # | 启发式 | 分 | 关键问题 |
|---|--------|----|----------|
| 1 | 系统状态可见性 | 3 | 有 stat / toast / 冷却文案；5s 轮询无「正在刷新」线索 |
| 2 | 系统与现实匹配 | 3 | 运维术语对受众合适；新手仍会懵「粘性 / RR」 |
| 3 | 用户控制与自由 | 3 | 确认框可取消、可退出；换 IP 无撤销（可接受） |
| 4 | 一致性与标准 | 3 | token 大体统一；toast 底色硬编码 `#1e1e2a` |
| 5 | 防错 | 3 | 删实例 / 全量换 IP / 目标 N 有确认；冷却有反馈 |
| 6 | 识别优于回忆 | 3 | 卡片操作始终外露；健康态偏颜色 |
| 7 | 灵活与效率 | 2 | 无快捷键；无批量出池；仅有「全部换 IP」 |
| 8 | 美观与极简 | 3 | 密度与 ops 场景匹配，无营销式装饰 |
| 9 | 错误识别与恢复 | 3 | toast 带原因；连接失败有提示 |
| 10 | 帮助与文档 | 2 | 仅 hint；配置项无内联说明 |
| | **合计** | **28** | **Good** |

**认知负荷**：约 2 项失败（首屏决策点多、配置 7 字段同屏）→ 中等，运维台可接受。

---

## P0 / P1 / P2 发现

### P0

无。任务路径（登录 → 看池/实例 → 换 IP / 成员 / 配置）可完成；API 接线完整。

### P1

| 文件:区域 | 问题 | 修复 |
|-----------|------|------|
| `index.html` · `.dot` + 卡片健康态 | 健康几乎只靠绿/红圆点（+ `title`）；色觉与读屏弱；违反「不只靠颜色」 | 在 meta 或点旁加可见文案「健康/异常」；`aria-label` 写全状态；可选 `role="status"` |
| `index.html` · `.btn-sm` / 卡片 `.actions` | `min-height: 32px`、小 padding，触控 < 44×44；操作钮挤在一行 | `btn-sm` 至少 `min-height: 40px`（理想 44）；窄屏 actions 可 2 列或全宽按钮 |
| `index.html` · `#toast` | 无 `role="status"` / `aria-live`；读屏听不到操作结果 | `role="status" aria-live="polite"`；错误用 `aria-live="assertive"` 或切换 `role="alert"` |
| `index.html` · `#modal` | 无 `role="dialog"` / `aria-modal` / 标题关联；无 Esc、无焦点陷阱；打开时焦点不进对话框 | 补 ARIA；打开时 `focus` 到「取消」或标题；Esc=取消；Tab 循环限制在 modal 内 |

### P2

| 文件:区域 | 问题 | 修复 |
|-----------|------|------|
| `index.html` · 文档结构 | 无 `<main>`；header 操作与内容区 landmark 弱 | `header` + `<main id="main">`（注意与现有 `#main` id 合并或改名） |
| `index.html` · `#hist-id` / `want-n` 行 | label 用 `class="hint"` 包输入，无 `for`/`id` 规范关联 | 标准 `<label for="hist-id">` |
| `index.html` · 选路 / 历史滚动区 | 仅有 `max-height`+overflow；无区域名 | `aria-label="选路日志"` / `aria-label="IP 历史"`；长列表可 `tabindex="0"` 便于键盘滚 |
| `index.html` · `.toast` 样式 | 背景 `#1e1e2a` 游离于 token | 改为 `var(--panel2)` 或新增 `--toast-bg` |
| `index.html` · 轮询 `setInterval(refresh, 5000)` | 静默刷新，状态是否最新不直观 | 页眉小字「上次刷新 HH:mm:ss」或刷新钮短暂 loading |

### P3（备忘，非必须）

- `prefers-reduced-motion`：现仅 opacity，影响极小。
- Detector `flat-type-hierarchy`：运维 dense UI 字号接近是有意的；不必强行拉大 display 阶梯。
- 配置 7 字段同屏：可按「换 IP / 互异 / 健康」分组，非发版阻断。
- 无键盘快捷键（r=刷新等）：Alex 类用户会要，可后补。

---

## 已做好（不要重做）

1. **OLED ops token + 8px 密度**：`--bg/--panel/--line` 语义清晰，product 克制配色，非营销渐变。
2. **实例卡操作始终横排外露**：出池 / 固定 / 换 IP / 历史 / 删除可发现，符合「识别优于回忆」。
3. **池条 `pool-strip`**：模式、成员、出池、清粘性一处扫完，信息架构对。
4. **选路 `ul.audit` 三列网格 + 历史 `table.hist` sticky 头**：比纯文本日志可扫，tabular + mono 合适。
5. **破坏性确认 modal + toast 反馈 + Bearer 令牌不进 URL**：防错与安全基线正确。
6. **`:focus-visible` 在 `.btn`**：键盘焦点可见已有基础。
7. **API 契约未破坏**：`/health` `/pool` `/instances` `/routes` `/ip-history` `/rotate` `/config` 与现有 JS 一致，评审未要求也不应拆线。

---

## 人物红旗（摘要）

| 人物 | 红旗 |
|------|------|
| **Alex（高效运维）** | 无快捷键；卡片 5 钮无批量；5s 轮询无法手动「只刷池」。主路径仍 <60s，可接受。 |
| **Sam（读屏/键盘）** | 健康点、toast、modal 是真痛点（见 P1）；按钮有可见文字是加分。 |
| **Riley（压测）** | 空列表/失败文案有；冷却 429 有 toast；modal 无 Esc 易卡住键盘流。 |

---

## 建议修补顺序（不自动改代码）

1. P1：toast live + modal 对话框语义 + Esc（约 15–25 行，可单次补丁）。
2. P1：健康态可见文案 / `aria-label`。
3. P1：`btn-sm` 触控高度。
4. P2：landmark、label、`aria-label`、toast token、上次刷新时间。

**本轮**：无 P0 → **未修改** `index.html`。需要落地时指定「只修 P1」即可。
