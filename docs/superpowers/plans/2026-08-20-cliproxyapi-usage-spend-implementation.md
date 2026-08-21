# Implementation: cliproxyapi-usage-spend

- Date: 2026-08-21
- Design Doc: docs/superpowers/specs/2026-08-20-cliproxyapi-usage-spend-design.md
- Review Doc: docs/superpowers/plans/2026-08-20-cliproxyapi-usage-spend-design-review.md
- Status: Completed

## 1. 评审意见处理摘要

- 采纳 HIGH-1：删除不存在的 ack。`GET /v0/management/usage-queue?count=N` 返回即 pop；解码后同步 `insert`；persist 失败记 dropped，无法回放；每 tick drain-until-empty。
- 采纳 HIGH-2：把 CPA `usage-statistics-enabled` 默认写成 **false**，列为数据前提。false 时不 pop，typed error，不假装 $0。
- 采纳 HIGH-3：descriptor 固定 `supportsTokenCost` + `supportsTokenSnapshot`；tracking 只闸 collector/loader，不改能力位。`costCapableProviders` 无特殊 case。tracking 关仍占一行，confirmed-empty。
- 采纳 HIGH-4：进程级 collector，`tickInterval = 5s`；每 tick drain-until-empty（pageSize 200，最多 50 页 / 10_000 条）。不挂 dashboard scan。
- 采纳 MEDIUM-1：decoder 使用上游 `*_tokens` json tag；`cached_tokens` 回退到 `cache_read_tokens`。
- 采纳 MEDIUM（scanner / nil fallthrough）：`.cliproxyapi` 走 `loadRemoteTokenSnapshot`，返回 snapshot 或 typed error，禁止 nil 掉进本地 JSONL scanner。
- 采纳 401/403 fail-closed：fingerprint 隔离 store；换 key 不发布旧账户历史。
- 未采纳：静默 PUT 打开 `usage-statistics-enabled`（评审明确禁止改用户代理配置）。
- 代码审查 HIGH/MEDIUM 已修：dashboard 发布 labeled snapshot；ProviderRow 展示 `historyLabel`；`extrasEnabled == nil` 不覆盖 env；collector 错误/停机 refresh；listPriceUSD 按 upstream alias 查 models.dev。
- 未在本机跑 `make test` / `make check`：本机 Command Line Tools 是 Swift 6.1，Homebrew Swift 6.3 编不了 KeyboardShortcuts `#Preview` 宏，且 Testing 模块要求 macOS 15，与 package `macOS 14` 冲突。Core 层 spend 合同用隔离 probe package 验证。

## 2. 根因前提处理结论（按需）

- 适用性：适用
- 处理策略：修订后实现
- 结论：根因成立且稳定。无数据是因为 Usage & Spend 合同排除 + 没有 `CostUsageTokenSnapshot` loader，不是 JSONL 扫漏或配额探测失败。实现按修订后的 pop 合同、两道开关、静态能力位、进程级 collector 落地。

### 2.1 消费的根因评审结论

- SUPPORTED
- 合同排除：`costCapableProviders` 过滤 `supportsTokenCost`。
- 打开开关仍无 loader：`loadTokenSnapshot` 在 `supportsTokenSnapshot == false` 时抛 `unsupportedProvider`；`loadRemoteTokenSnapshot` 原先只处理 Bedrock/Cursor。
- usage-queue 是短 TTL 破坏性 pop：GET 即 `PopOldest`，默认 retention 60s。
- `usage-statistics-enabled` 默认 false：上游 Go 零值 / example yaml。不推翻根因，但会扭曲主路径前提，已修订。

### 2.2 本次修订的前提边界

- 已确认事实：
  - GET usage-queue 即 pop，无 ack。
  - CPA 统计开关默认 false。
  - `ProviderDescriptor.tokenCost` 是静态注册表。
  - 队列 TTL 默认 60s。
- 未确认假设：
  - 本仓库没有 CLIProxyAPI 上游源码；pop/TTL/默认值以评审引用的上游路径为准。
  - 与 CPA-Manager 双消费无法在协议层检测。
- 对实现的影响：collector 必须进程级、≤5s、drain-until-empty；文案必须写清两道开关；tracking 不得动态改 `supportsTokenCost`。

## 3. 采纳的设计修订

- HIGH-1：无 ack；`popUsageQueue`；GET 后立即按 credential fingerprint 落盘；短页或空页结束本轮。
- HIGH-2：`usage-statistics-enabled` 默认 false；GET flag 允许 JSON fragment `true`/`false`；false 不 pop。
- HIGH-3：`supportsTokenCost` / `supportsTokenSnapshot` 恒 true；tracking 默认 false（`extrasEnabled` / `CLIPROXYAPI_SPEND_TRACKING`）；关 tracking 返回 confirmed-empty，不展示旧数字。
- HIGH-4：`CLIProxyAPIProviderRuntime` 生命周期 collector，5s tick，drain-until-empty；插入后 `refreshSpendDashboardTokenUsageNow(force: true)`。
- Store：`(dedupe_key, credential_scope)` 主键；load 必须带 fingerprint，禁止无 scope 全表扫描。

## 4. 实现摘要

- Management client：`usageStatisticsEnabled()`、`popUsageQueue(count:)`（默认 200，count>1）、401/403 → `CLIProxyAPISpendError.unauthorized`。
- Collector：先检查统计开关，再循环 pop + 立即 insert。
- Store：SQLite WAL，fingerprint 隔离。只读 `open()` 在库文件不存在时直接返回 nil，避免 `sqlite3_open_v2` 对缺失路径打 `Error: unable to open database file`。
- Snapshot loader：tracking 关 / 统计关 / 不可达 / 401 映射到设计 §5.4；`.cliproxyapi` 不返回 nil。
- Descriptor + dashboard：能力位打开；CurrencyGroup 合计排除 cliproxyapi。
- Runtime：provider enabled 且 tracking on 才跑 collector。
- 测试：`Tests/CodexBarTests/CLIProxyAPISpendTests.swift` 与 `TestsLinux/CLIProxyAPISpendLinuxTests.swift`（Linux 套件可在无 AppKit/KeyboardShortcuts 的 toolchain 上跑 Core 合同）。
- 文档：`docs/cliproxyapi.md`、`docs/providers.md` 已写 opt-in pop 合同与两道开关。

- Dashboard：cliproxyapi typed error → labeled empty snapshot；`ProviderRow.statusText` 展示非 disclaimer 的 `historyLabel`。
- Tracking 投影：`extrasEnabled == nil` 不写 env；runtime 看 merge 后的 `CLIPROXYAPI_SPEND_TRACKING`。
- 定价：custom overlay → models.dev（gemini/google/antigravity、grok/xai）→ bundled Codex/Claude。
- 涉及模块：

- `Sources/CodexBarCore/Providers/CLIProxyAPI/*Spend*`
- `Sources/CodexBarCore/CostUsageFetcher.swift`
- `Sources/CodexBar/Providers/CLIProxyAPI/*`
- `Sources/CodexBar/UsageStore.swift` / `UsageStore+TokenCost.swift`
- `Tests/CodexBarTests/CLIProxyAPISpendTests.swift`
- `TestsLinux/CLIProxyAPISpendLinuxTests.swift`
- `docs/cliproxyapi.md` / `docs/providers.md`

## 5. 验证结果

- 测试：隔离 probe package（macOS 15 + Homebrew Swift 6.3.3，path 依赖本仓库 CodexBarCore）
  - 命令：`MACOSX_DEPLOYMENT_TARGET=15.0 /opt/homebrew/opt/swift/bin/swift test --package-path /tmp/codexbar-spend-probe --scratch-path /tmp/codexbar-spend-probe/.build --filter CLIProxyAPISpendLinuxTests`
  - 结果：`CLIProxyAPISpendLinuxTests` 12/12 passed（原 11 项 + `loadEvents on missing store returns empty without creating files`）。
- 构建：`MACOSX_DEPLOYMENT_TARGET=15.0 /opt/homebrew/opt/swift/bin/swift build --target CodexBarCore` → `Build of target: 'CodexBarCore' complete!`
- 本机安装：`PATH="/opt/homebrew/opt/swift/bin:$PATH" CODEXBAR_SIGNING=adhoc ARCHES=arm64 ./Scripts/package_app.sh`，再 `ditto CodexBar.app /Applications/CodexBar.app`。
  - 包：`/Applications/CodexBar.app` 0.54.0 (126)，adhoc codesign `--verify --deep --strict` 通过，`LSUIElement=true`。
  - 进程：`98887 /Applications/CodexBar.app/Contents/MacOS/CodexBar`，与仓库包 MD5 `62f9d947d13293811fadd37788d87525` 一致；启动后 ≥8 分钟仍在，RSS ~110MB。
  - 缺库 sqlite 噪音：首包只读打开不存在的 `cliproxyapi-spend.sqlite` 会打 `Error: unable to open database file`。修 skip 后 `log show --last 3m ... eventMessage CONTAINS "sqlite"` 无该错误。
  - spend 目录：`~/Library/Application Support/CodexBar/cliproxyapi-spend` 仍不存在（tracking 默认关、无 insert，符合合同）。
  - CLI：`CodexBarCLI config providers --json` 中 `cliproxyapi.enabled=true`；二进制含 HIGH-2 文案（`Spend tracking is off...` / `usage-statistics-enabled defaults to false`）。
  - 菜单 extra：本机 `NSStatusItem Visible codexbar-merged = 0`（用户已有偏好，未改）。菜单栏右侧猫标带 `$` **不是** CodexBar；官方 extra 是 usage bar / chevron（见 `docs/icon.png`、`docs/codexbar.png`）。临时把 Visible 置 true 再还原后，仍看不到 chevron extra——extra 被该偏好藏进 Control Center overflow，不是安装失败。无辅助功能权限，未能点开 Settings → Usage & Spend。
  - 未打真实 CPA；live pop/drain 仍只由 Core 单测覆盖。
- lint/typecheck：未跑完整 `make check`。本机 `swift` 是 6.1（低于 Package.swift tools 6.2）；Homebrew Swift 6.3 编 CodexBar app 目标时 KeyboardShortcuts `#Preview` 缺 PreviewsMacros；Testing 模块要求 macOS 15，与 package `platforms: macOS 14` 冲突。本次 store/tests 已用项目 `swiftformat` 0.61.1 格式化。

## 6. 已知限制与后续建议

- 本机无法用项目标准 `make test` / `make check` 验证 app 目标与 SwiftFormat/SwiftLint。CI（Xcode 26.x / macOS 26 runner）需要再跑全套。
- 队列 60s TTL：CodexBar 未运行期间的缺口只能标 coverage gap，不能补回。
- 与 CPA-Manager 双消费无法检测；靠 tracking 默认关 + 设置警告。
- persist 失败的事件已从 CPA 消失，无法回放。
- `usage-statistics-enabled` 的 JSON fragment 解码依赖 `.fragmentsAllowed`；若上游改成非 bool 形状，会变成 decode error。
- Settings UI getter 仍是 `extrasEnabled ?? false`：仅 env 打开 tracking 时，开关显示为关。
- 本机菜单 extra 被已有 `NSStatusItem Visible codexbar-merged = 0` 隐藏。要看见图标：Menu Bar 设置里打开 CodexBar，或把该默认值改回 true。

## 7. Handoff

### 7.1 同会话继续

直接执行 $code-review 或 /code-review

### 7.2 新会话恢复 prompt

```text
请阅读设计文档 docs/superpowers/specs/2026-08-20-cliproxyapi-usage-spend-design.md、
评审文档 docs/superpowers/plans/2026-08-20-cliproxyapi-usage-spend-design-review.md、
实现文档 docs/superpowers/plans/2026-08-20-cliproxyapi-usage-spend-implementation.md，
以及本次提交的代码变更。
重点核对根因前提（如有）、设计修订、实现结果与验证证据是否一致，
使用 $code-review（或 /code-review）进行方案重审及代码审查。
```
