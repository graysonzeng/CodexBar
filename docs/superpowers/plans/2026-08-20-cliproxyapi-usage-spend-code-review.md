# Code Review: CLIProxyAPI Usage & Spend

- Date: 2026-08-21
- Design Doc: docs/superpowers/specs/2026-08-20-cliproxyapi-usage-spend-design.md
- Review Doc: docs/superpowers/plans/2026-08-20-cliproxyapi-usage-spend-design-review.md
- Implementation Doc: docs/superpowers/plans/2026-08-20-cliproxyapi-usage-spend-implementation.md
- Status: NEEDS_FIX → 修复后 PASS_WITH_NOTES
- Review Scope: 对照设计 §5.2 / §5.4 / HIGH-1..4 与当前 CLIProxyAPI spend collector、loader、dashboard、tracking 投影实现

## 1. 整体结论

- 初审 NEEDS_FIX；修复后 PASS_WITH_NOTES
- 一句话结论：GET=pop、drain-until-empty、supportsTokenCost/loader 合同已落地；Usage & Spend typed error、extrasEnabled 投影、collector refresh、models.dev alias 已修。残留：Settings UI getter 与 app 目标未在本机执行。

## 2. 根因前提处理结论

- 适用性：适用
- 处理策略：沿用（实现已按评审修订的根因边界落地；本轮问题是 UI/运行时通道，不是根因回退）
- 结论：队列 GET 即 pop、usage-statistics-enabled 默认 false、无 loader 不能只翻 supportsTokenCost，这三条仍成立。

### 2.1 消费的根因评审结论

- SUPPORTED：GET `/v0/management/usage-queue` 即 pop，无 ack
- SUPPORTED：`usage-statistics-enabled` 默认 false
- SUPPORTED：`supportsTokenCost` 必须同时提供 snapshot loader
- SUPPORTED：进程级 collector ≤5s + drain-until-empty

### 2.2 本次修订的前提边界

- 已确认事实：collector 先查 statistics flag；loader 对 tracking 关 / 有历史的统计关 / 有历史的 unreachable 返回带 `historyLabel` 的 snapshot；401 即使有历史也 throw
- 未确认假设：models.dev 对 CPA `gemini` / `grok` / `antigravity` provider id 的目录键与上游字段一致
- 对实现的影响：定价链补 models.dev 时必须带 provider 别名，失败则保持 unpriced，不得编造

## 3. 一致性核对

| 设计点 | 实现 | 结论 |
|---|---|---|
| HIGH-1 GET=pop，立即落盘，drain-until-empty | `popUsageQueue` GET + `count`；`insert` 在下一页之前；空页结束 | 一致 |
| HIGH-2 statistics 默认 false，false 不 pop | collector `usageStatisticsEnabled()` false → throw；测试断言未打 usage-queue | 一致 |
| HIGH-3 supportsTokenCost && supportsTokenSnapshot 静态 true | descriptor 两旗均为 true；tracking 另走 extrasEnabled | 一致 |
| HIGH-4 进程级 5s collector | `tickInterval = .seconds(5)`；runtime Task 循环 | 一致 |
| §5.4 可行动错误上屏 | loader 写了 `historyLabel` / throw；dashboard catch 清 snapshot；ProviderRow 不读 label | **不一致** |
| §5.2 overlay → models.dev → bundled | overlay + `codexCostUSD`/`claudeCostUSD`（内部含 models.dev）；无 `upstreamProvider` 别名查找 | 部分一致 |
| tracking 默认关，env 可开 | Settings `extrasEnabled ?? false`；投影无条件写 `"0"`/`"1"` | **不一致** |

## 4. Findings

### [HIGH] 错误处理: dashboard 刷新吞掉 CLIProxyAPI typed error

**文件**: `Sources/CodexBar/UsageStore+SpendDashboardTokenCost.swift:118-148`

**问题**: `refreshSpendDashboardTokenUsageNow` 成功路径会发布 cliproxyapi snapshot（含 `historyLabel`）。catch 对任意错误（含 `usageStatisticsDisabled` / `unauthorized` / `unreachable` / `persistFailed`）只 `clearSpendDashboardTokenSnapshot`。菜单路径 `refreshTokenUsage` 会写 `tokenErrors`；dashboard 独立通道没有对应发布。loader 在 store 为空时 throw，设计要求的可行动文案因此进不了 Usage & Spend。

**影响**: 统计关、401、连不上时，打开 Usage & Spend 变成 confirmed-empty / “Spend unavailable”，用户看不到“打开 usage-statistics-enabled”或“更新 management key”。

**建议**: cliproxyapi catch 发布 `historyCoverageIsEstablished=false` 且 `historyLabel=error.localizedDescription` 的空 snapshot；401 维持 fail-closed（不要回挂旧 fingerprint 历史）。

### [HIGH] UI: ProviderRow 不展示 snapshot.historyLabel

**文件**: `Sources/CodexBar/SpendDashboardModel.swift:46-74,605-626`；`Sources/CodexBar/PreferencesSpendDashboardPane.swift:642-676`

**问题**: loader 已把 trackingDisabled / statisticsDisabled / unreachable 写入 `historyLabel`。`SpendDashboardModel.ProviderRow` 只有 tokens/cost；面板在两者都是 nil 时显示静态 “Spend unavailable”。`historyLabel` 只出现在菜单 cost 图，不出现在 Usage & Spend。

**影响**: 即使成功发布带 label 的 snapshot（tracking 关、有历史的统计关），dashboard 仍无该文案。§5.4 的四种原因对主页面无效。

**建议**: cliproxyapi 且 `historyLabel` 不是 observed disclaimer 时，写入 `ProviderRow.statusText` 并在 By subscription 行下展示。

### [HIGH] 配置: extrasEnabled 投影覆盖 CLIPROXYAPI_SPEND_TRACKING

**文件**: `Sources/CodexBarCore/Providers/CLIProxyAPI/CLIProxyAPIProviderDescriptor.swift:10-12`；`Sources/CodexBar/Providers/CLIProxyAPI/CLIProxyAPIProviderRuntime.swift:22-30`；`Sources/CodexBar/Providers/CLIProxyAPI/CLIProxyAPISettingsStore.swift:5-6`

**问题**: 投影 `($0.extrasEnabled ?? false) ? "1" : "0"` 在 `extrasEnabled == nil` 时也写 `"0"`，precedence 默认 `.config`，覆盖进程环境。runtime `shouldRun` 只看 Settings 开关（nil → false），即使 drainOnce 里 env 为 1 也不会启动 collector。

**影响**: 只设 `CLIPROXYAPI_SPEND_TRACKING=1`、从未点过 UI 开关的用户，tracking 实际关闭，队列不会被抽。与 HIGH-3「tracking 由开关门控、env 可开」不一致。

**建议**: `extrasEnabled == nil` 时投影返回 nil（不写 key）；显式 false/true 才写 `"0"`/`"1"`。runtime 在 Settings 关且 extras 未设时，仍读取 makeEnvironment 后的 env flag。

### [MEDIUM] 运行时: collector drainOnce 吞掉全部错误

**文件**: `Sources/CodexBar/Providers/CLIProxyAPI/CLIProxyAPIProviderRuntime.swift:42-62`

**问题**: `drainUntilEmpty` 的 `usageStatisticsDisabled` / persistFailed / 401 被 catch-all `return`。仅当 `inserted > 0` 才 `refreshSpendDashboardTokenUsageNow`。打开 dashboard 仍会 force refresh，但已打开的页面在 5s tick 上不会从「有历史」切到「统计已关」label。

**影响**: 运行中关掉 CPA 统计或 key 失效时，主页面最多等到下一次手动刷新/TTL。

**建议**: 非取消错误也 force refresh dashboard；tracking 从开到关时同样补一次 refresh。

### [MEDIUM] 定价: listPriceUSD 未按 upstreamProvider 查 models.dev

**文件**: `Sources/CodexBarCore/Providers/CLIProxyAPI/CLIProxyAPISpendAggregator.swift:255-308`

**问题**: 设计链是 custom overlay → models.dev → bundled Codex/Claude。现有 `codexCostUSD(model:)` / `claudeCostUSD(model:)` 内部会走 models.dev，但 CPA 队列里的 Gemini / Grok / Antigravity 不一定能命中 Claude/Codex 族路由；也没有 `gemini→google`、`grok→xai` 别名。

**影响**: 非 Claude/GPT 模型更容易 unpriced，token 在、cost 空。不编造价格这一点是对的，但 §5.2 的 models.dev 台阶不完整。

**建议**: 在 bundled 之前按 `upstreamProvider` 别名调用 models.dev lookup；查不到保持 nil。

### [LOW] Store: ensureSchema 只在 user_version == 0 建表

**文件**: `Sources/CodexBarCore/Providers/CLIProxyAPI/CLIProxyAPISpendStore.swift:179-204`

**问题**: `schemaVersion` 已是 1，但未来升到 2 时旧库会跳过 DDL。当前 v1 无迁移需求。

**影响**: 现在无用户可见 bug；下一次 schema 变更会卡住。

**建议**: 本轮不改。下次改 schema 时改成 version < current 再 migrate。

### [LOW] Store: sqlite bind 使用 SQLITE_TRANSIENT 惯用法

**文件**: `Sources/CodexBarCore/Providers/CLIProxyAPI/CLIProxyAPISpendStore.swift:218-224`

**问题**: `unsafeBitCast(-1, to: sqlite3_destructor_type.self)` 是 SQLite 常见写法，复制 string bytes。不是功能缺陷。

**影响**: 无。

**建议**: 不改。

## 5. 未采纳 / 降级说明

- schema / SQLITE_TRANSIENT：不构成 §5.4 回归，本轮不修。
- 指纹 publication gate 未复用 Cursor auto-cookie 逻辑：cliproxyapi store 已按 fingerprint 隔离，401 fail-closed 由 loader throw 覆盖。保持现状。

## 6. 验证缺口

- 无测试锁定 dashboard catch 将 typed error 发布为 labeled empty snapshot（UsageStore 在 CodexBar app 目标；本机 Homebrew Swift 6.3 编不了 KeyboardShortcuts `#Preview`）。
- ProviderRow `historyLabel` 测试已写入 `SpendDashboardCachedPresentationTests`，同样未在本机跑通 app 目标。

## 7. Handoff

本轮 HIGH/MEDIUM 已修。无需再走 `$fix-implement`。

## 8. 修复记录

- Date: 2026-08-21
- 结论: PASS_WITH_NOTES

### 已修

- HIGH dashboard 吞 typed error：`UsageStore+SpendDashboardTokenCost.swift` 对 `.cliproxyapi` catch 发布 `emptySnapshot(historyCoverageIsEstablished: false, historyLabel: error.localizedDescription)`；401 仍 fail-closed，不回挂旧 fingerprint。
- HIGH ProviderRow 不展示 `historyLabel`：`SpendDashboardModel.ProviderRow.statusText` + `SpendProviderPanel` caption。跳过 observed disclaimer。
- HIGH extrasEnabled 覆盖 env：投影 `extrasEnabled == nil` 返回 nil，不写 `CLIPROXYAPI_SPEND_TRACKING`。显式 true/false 才写 `"1"`/`"0"`。runtime `shouldRun` 读 merge 后的 env，不读 Settings getter。
- MEDIUM collector 吞错：`drainOnce` 非取消错误 force refresh；tracking 从开到关也 refresh。
- MEDIUM models.dev：`listPriceUSD` 在 bundled Codex/Claude 之前按 `gemini→google` / `grok→xai` / `antigravity→google` 查 models.dev；查不到保持 unpriced。

### 测试

- `CLIProxyAPISpendLinuxTests` 11/11 passed（probe package，含 extrasEnabled 不覆盖 env、gemini models.dev=$3、unknown model=nil）。
- `CodexBarCore` build complete（Homebrew Swift 6.3.3，`MACOSX_DEPLOYMENT_TARGET=15.0`）。
- 未跑 `make test` / `make check`：本机 CLT Swift 6.1；Homebrew 6.3 编 CodexBar 目标缺 PreviewsMacros。

### 未改

- LOW `ensureSchema` 只在 `user_version == 0` 建表。
- LOW `SQLITE_TRANSIENT` 惯用法。

### 残留 NOTES

- Settings UI getter 仍是 `extrasEnabled ?? false`：仅 env 打开 tracking 时，开关显示为关，但 collector 会跑。点一次开关会把 extras 写成 false 并覆盖 env。
- app 目标 `historyLabel` UI 测试未在本机执行。
