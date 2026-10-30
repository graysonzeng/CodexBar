---
summary: "CLIProxyAPI 在 Usage & Spend 无数据的根因，以及把代理观测流量接入本地成本历史的改造方案。"
read_when:
  - 调试 CLIProxyAPI 在 Usage & Spend 无输出
  - 把 CLIProxyAPI 请求用量接入 CostUsageTokenSnapshot
  - 避免把代理流量与 Codex/Claude 本地 JSONL 重复记账
---

# Design: CLIProxyAPI Usage & Spend

- Date: 2026-08-20
- Status: Revised
- Scope: L

## 1. 设计目标和范围

### 1.1 要解决的问题

安装并启用 CLIProxyAPI 后，Settings → Usage & Spend（中文界面「用量与支出」）对该 provider 没有输出。菜单栏配额卡片即使能显示 Codex/Gemini/Antigravity/Grok 的 remaining percent，支出页仍把 CLIProxyAPI 当成不存在的源。

问题不是「刷新失败后显示空卡片」，而是 **CLIProxyAPI 从未进入 Usage & Spend 的源集合**，现有探测也只拉上游配额窗口，不生产 `CostUsageTokenSnapshot`。

### 1.2 成功标准

- Usage & Spend 在 CLIProxyAPI 已启用、management key 可用、且 CodexBar 已收集到代理请求后，出现独立的 CLIProxyAPI 行，而不是被静默省略。
- 该行提供与现有 native 源同构的日桶：tokens、list-price 估算、request count、coverage、model mix。
- 配额探测与支出探测分离：配额继续走 `auth-files` + `api-call`；支出不依赖上游 5h/weekly remaining。
- 同一请求不得与 Codex/Claude 本地 JSONL 合并成一行；允许两行并存，但 UI 必须标明 CLIProxyAPI 是代理观测值。
- 不得消费式抽空 CLIProxyAPI 的 `usage-queue` 而不持久化；不得在未声明的情况下与 CPA-Manager 抢同一条消费队列。
- 无流量、CPA 未运行、或收集器关闭时，显示明确 empty/error 状态，而不是从源列表消失。
- 现有 CLIProxyAPI 配额测试与 Usage & Spend 的 Codex/Claude 扫描行为不回归。

### 1.3 本次范围

- 根因：Usage & Spend 选源合同、CLIProxyAPI descriptor 能力位、CPA management API 实际形状。
- 选定方案：CodexBar 自建 CLIProxyAPI usage collector，把请求级 token 记录落成 `CostUsageTokenSnapshot`。
- descriptor / fetch / spend-dashboard / 设置项 / 文档 / 测试合同。
- 进程级 collector：tracking 开启且 provider enabled 时，在应用生命周期内以 ≤5s tick drain `usage-queue`。

### 1.4 非目标

- 不把 CLIProxyAPI 变成账单收据；成本仍是 list-price estimate。
- 不修改 CLIProxyAPI 上游仓库去新增 `/v0/management/usage/limits` 历史账单接口。
- 不把 Claude/Copilot/Kimi 等未探测 auth kind 补进配额卡片（可在后续配额迭代单独做）。
- 不把代理流量改记到 Codex/Claude native 行。
- 不扫描 `~/.codex/sessions` 或 Claude JSONL 来冒充 CLIProxyAPI 支出。
- 本次不实现 Widget、不改 Sparkle 发布流程。
- v1 不实现 CPA-Manager JSONL/SQLite 导入（无钉死 schema）；配置位可留但默认忽略。
- v1 不接 RESP `SubscribeUsage`：示例配置默认关闭 RESP，复杂度高于 HTTP pop；独占消费者合同写进设置文案即可。

## 2. 背景与约束

Usage & Spend 是本地估算成本历史页，不是菜单栏配额卡。`docs/providers.md` 写明 native 源必须 advertise `tokenCost.supportsTokenCost`：Codex、Claude、OpenAI Admin、Mistral、AWS Bedrock、Vertex AI、Cursor、OpenCode Go。未声明该合同的 provider 会被省略，而不是显示空订阅。

CLIProxyAPI 当前是配额适配器：读运行中的 [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) management API（默认 `http://127.0.0.1:8317`），不读 git checkout，也不读本地 session JSONL。探测路径：

1. `CLIProxyAPISettingsReader` 要求 `CLIPROXYAPI_MANAGEMENT_KEY`（或 config `apiKey`）。
2. `GET /v0/management/auth-files` 列出凭证。
3. 只保留 Codex / Gemini / Antigravity / Grok（含 xai 别名），最多 12 个。
4. `POST /v0/management/api-call` 让 CPA 用存储凭证打上游 usage API。
5. `CLIProxyAPISnapshotMapper` 聚合成 `UsageSnapshot` 的 primary/secondary/`extraRateWindows`。

CPA 自身另有请求级 usage 通道，但 CodexBar 完全未接：

- `GET /v0/management/usage-queue?count=N`：handler 内 `PopOldest`，返回即从内存队列删除。无 ack、无 visibility timeout、无 nack。`count` 缺省为 1，上限由调用方给出。默认 retention 60s，上限 3600s。
- 记录 JSON tag：`timestamp`、`auth_index`、`provider`、`model`、`alias`、`request_id`、`failed`、`api_key`、`tokens.{input_tokens,output_tokens,reasoning_tokens,cached_tokens,cache_read_tokens,cache_creation_tokens,total_tokens}`、`fail.status_code`。缺 model 时上游已填 `"unknown"`。
- `GET /v0/management/api-key-usage`：仅 `api_key` auth 的 success/failed 与 recent request buckets，无 token、无美元。
- `GET /v0/management/usage-statistics-enabled`：CPA `usage-statistics-enabled` **默认 false**（Go 零值 + `config.example.yaml`）。false 时 `HandleUsage` 直接 return，队列不入队。
- 请求日志 API 按 request id 下发文件，不是日聚合账单。
- CPA-Manager / CPA-Manager-Plus 正是因为队列是消费型，才自己落到 SQLite/JSONL。v1 不导入它们的文件。

约束：

- Provider 数据必须隔离：CLIProxyAPI 行不得显示其他 provider 的 identity/plan 字段。
- 成本数字必须带 `CostProvenance`；代理观测值标 `listPriceEstimate`。
- 私钥网 HTTP 已对 CLIProxyAPI 放行，新 collector 必须走同一 management key / base URL / `ProviderEndpointOverrideValidator`。
- 不得在未明确请求时打真实 Keychain 或活账户。
- Swift 并发：collector 的必选失败与可选导入不能用「一个必选 + 一个可选」的 sibling `async let`。

## 3. 根因分析（按需）

### 3.1 是否需要根因分析

- 需要
- 理由：无数据可能被理解成配置错误、CPA 没跑、解析失败或 Usage & Spend 合同排除。这四种修法完全不同。必须先锁定是合同排除，才能决定做 collector 而不是「打开开关」或「去扫 Codex JSONL」。

### 3.2 已确认事实

- Usage & Spend 副标题是 “Local estimated cost history across supported providers.” 源集合来自 `SpendDashboardSource.costCapableProviders` → `SettingsStore.isCostUsageEffectivelyEnabled`，后者要求 `descriptor.tokenCost.supportsTokenCost`。证据：`Sources/CodexBar/SpendDashboardController.swift`、`Sources/CodexBar/SettingsStore+MenuPreferences.swift`、`docs/providers.md` §Usage & Spend settings。
- CLIProxyAPI descriptor 显式关闭支出合同：`supportsTokenCost: false`，`supportsTokenSnapshot` 默认 false，`noDataMessage` 为 “CLIProxyAPI cost history is not tracked in this provider.”，`supportsCredits: false`。证据：`Sources/CodexBarCore/Providers/CLIProxyAPI/CLIProxyAPIProviderDescriptor.swift`。
- `CostUsageFetcher.loadTokenSnapshot` 在 `supportsTokenSnapshot == false` 时抛 `CostUsageError.unsupportedProvider`。`loadRemoteTokenSnapshot` 只处理 Bedrock 与 Cursor。证据：`Sources/CodexBarCore/CostUsageFetcher.swift`。
- 菜单 Cost 区同样 gated：`tokenUsageSection` 在 `supportsTokenCost == false` 时返回 nil。证据：`Sources/CodexBar/MenuCardView+Costs.swift`。
- 现有 fetcher 只映射配额窗口，不填 `providerCost` / `costUsage` / daily token 历史。Gemini/Codex/Grok 映射在窗口缺失时返回 nil，整账户被丢弃。证据：`CLIProxyAPIUsageFetcher.swift`、`CLIProxyAPISnapshotMapper.swift`。
- Claude、Copilot 及其他 CPA auth type 被 `mapResolvedAuth` 直接丢弃。文档也写明 GitHub Copilot 等 listed but not probed。证据：`CLIProxyAPIManagementClient.swift`、`docs/cliproxyapi.md`。
- CPA `usage-queue` 是短 TTL 消费队列，不是历史 API。`GetUsageQueue` 调用 `redisqueue.PopOldest`；HTTP GET 返回即删除。默认 retention 60 秒。证据：CLIProxyAPI `internal/api/handlers/management/usage.go`、`internal/redisqueue/queue.go`。
- 队列 payload 已有足够字段构造日桶：`timestamp` + `tokens.*_tokens` + `model` + `auth_index` + `provider` + `failed` + `request_id`。证据：`internal/redisqueue/plugin.go`。
- `api-key-usage` 不够撑 Usage & Spend：无 token、无 cost、只覆盖 api_key auth。证据：`internal/api/handlers/management/api_key_usage.go`。
- CPA `usage-statistics-enabled` 默认 **false**。默认安装上队列永远空，除非用户在 CPA config 打开该开关。证据：`config.example.yaml`、Go bool 零值、上游 issue #3048。
- LLM Proxy / LiteLLM / ClawRouter / ai& 同样 `supportsTokenCost: false`；它们把 spend 放进菜单 `providerCost`，而不是 Usage & Spend。CLIProxyAPI 连 `providerCost` 都没填。证据：各 provider descriptor。
- OpenCodex 是 Usage & Spend 的 opt-in 只读 JSONL 源，刻意不与 native Codex 合并，避免双计。这是代理类流量的既有产品先例。证据：`docs/providers.md`、`Sources/CodexBar/SpendDashboardSource+OpenCodex.swift`。
- `ProviderDescriptor.tokenCost` 是进程级静态注册表，不能随 Settings 翻转 `supportsTokenCost`。

### 3.3 未确认假设

- 用户说的「用量与支出」主要指 Settings 页，而不是菜单配额卡。若配额卡也是空的，那是第二条故障：CPA 未监听 8317、缺 management key、auth 全是 Claude/Copilot、或上游 `api-call` 失败。本方案两条都覆盖，但 Usage & Spend 即使配额正常也仍会空。
- 用户机器上可能同时跑 CPA-Manager。若 CodexBar 也 `PopOldest`，会把面板的请求监控抽空。缓解靠 tracking 默认关 + 设置警告；协议层无法检测双消费。
- 经代理的 Codex/Claude 客户端仍会写自己的本地 session 日志。启用 collector 后，Usage & Spend 可能同时出现 native Codex 行与 CLIProxyAPI 行，数字部分重叠。同币种 CurrencyGroup 合计会把两行加在一起，因此 CLIProxyAPI 必须排除在 group total 之外。
- CPA 同进程存在 RESP `SubscribeUsage()`，但示例配置默认关闭 RESP。v1 明确不走订阅。
- `GET /v0/management/usage-statistics-enabled` 的 JSON 形状可能是裸 bool 或 `{"enabled":...}`；解码必须兼容两者。

### 3.4 对设计的影响

- 只把 `supportsTokenCost` 翻成 true 会让 CLIProxyAPI 进入源列表，但 `loadTokenSnapshot` 立刻 `unsupportedProvider`，页面仍无数据或变成 error 行。必须同时提供 snapshot loader。
- 不能把 `~/.codex` / Claude JSONL 记到 CLIProxyAPI：那是另一套所有权，且会与 native 源双计。
- 不能把 `usage-queue` 当只读账单：GET 就是 pop。必须立即本地持久化；pop 成功、persist 失败的记录永久丢失，记 dropped/skipped，不能向 CPA 回放。崩溃去重靠 `request_id`（`timestamp + auth_index` 兜底），不是「允许重复消费」。
- `api-key-usage` 不能当主源。
- 配额路径保持独立；支出路径失败不得清掉配额 snapshot。
- tracking 只闸 collector / pop，不闸 descriptor 能力位。关闭 tracking 时 CLIProxyAPI 仍在 `costCapableProviders` 里，loader 返回 confirmed-empty。
- 数据前提：CPA `usage-statistics-enabled=true` **和** CodexBar spend tracking on。缺任一都不得假装 $0。
## 4. 方案对比

### 4.1 方案 A — 合同内诚实空态，不接支出

- 核心思路：维持 `supportsTokenCost: false`。Usage & Spend 继续省略 CLIProxyAPI。文档和设置文案写明该页只统计 native token-cost 源；CLIProxyAPI 只提供菜单配额。配额探测保持现状。
- 优点：零实现风险，无双计，不碰消费队列，与当前 `docs/providers.md` 合同一致。
- 缺点：用户在安装启用后看「用量与支出」仍然没有任何 CLIProxyAPI 输出，问题原样保留。
- 适用前提：产品确认 CLIProxyAPI 只做配额网关，支出由 Codex/Claude native 日志负责。

### 4.2 方案 B — 打开 token-cost 开关，复用 Codex/Claude 本地扫描

- 核心思路：`supportsTokenCost = true`，loader 去扫 `CODEX_HOME` / Claude JSONL，结果挂到 `.cliproxyapi`。
- 优点：实现快，已有 scanner 与定价。
- 缺点：所有权错误；与 native Codex/Claude 行双计；经代理但客户端不写 JSONL 的流量（curl、第三方网关客户端）仍然为 0；Claude-via-CPA 若没开 Claude provider 会把别人的日志算进 CLIProxyAPI。
- 适用前提：不存在。与「provider 数据隔离」和 Usage & Spend 所有权规则冲突。

### 4.3 方案 C — CodexBar 自建 usage-queue collector + 本地持久化（推荐）

- 核心思路：CLIProxyAPI 成为独立 spend source。CodexBar 轮询或导入请求级 usage，持久化到自己的 store，聚合成 `CostUsageTokenSnapshot`，打开 `supportsTokenCost` + `supportsTokenSnapshot`。配额探测不动。
- 优点：数据所有权正确（代理观测）；字段足够做日桶和 token mix；与 OpenCodex 先例同构；不依赖上游 remaining percent；CPA 不在线时仍能展示已持久化历史。
- 缺点：必须处理消费队列互斥、短 TTL、定价覆盖、以及与 native 日志的重叠说明。
- 适用前提：用户同意 CLIProxyAPI 行表示「代理看到的请求」，不是供应商账单。

### 4.4 方案 D — 只读导入 CPA-Manager SQLite/JSONL

- 核心思路：不碰 `usage-queue`。若本机存在 CPA-Manager / CPA-Manager-Plus 导出或 SQLite，则只读导入。
- 优点：不与面板抢队列；历史更完整。
- 缺点：CPA-Manager 不是默认安装；路径/schema 会漂；没有面板的用户永远无数据。
- 适用前提：作为方案 C 的降级/补充源，不能当唯一源。

### 4.5 选型结论

- 选择：方案 C，方案 D 作为可选导入。
- 理由：方案 A 不解决问题。方案 B 违反数据隔离并双计。方案 C 使用 CPA 真正拥有的请求级 token 数据，并由 CodexBar 承担历史，这正是 CPA-Manager 对同一队列做过的事。方案 D 保留给已经在跑面板的用户，避免双消费者。

## 5. 详细方案

### 5.1 核心思路

把 CLIProxyAPI 的「配额」和「支出」拆成两条互不覆盖的流水线。

```text
配额（已有）                         支出（新增）
auth-files + api-call               usage-queue poll 或 Manager 导入
    → UsageSnapshot 窗口                 → CodexBar 本地 store
    → 菜单百分比                         → CostUsageTokenSnapshot
                                         → Usage & Spend 独立行
```

支出数字 = 请求 token × models.dev / 自定义 list price，provenance = `listPriceEstimate`。没有供应商扣费字段时 `meteredCostUSD` 保持 nil。

CLIProxyAPI 在 Usage & Spend 中是一等 native 源，不是 OpenCodex 那种非 provider 附加行。它仍不得 merge 进 Codex/Claude。

### 5.2 关键数据流 / 控制流

1. 用户启用 CLIProxyAPI，填 management key 与可选 base URL。Providers → CLIProxyAPI 增加 **Track CLIProxyAPI spend** 开关，写入 `ProviderConfig.extrasEnabled`，默认 **false**，避免安装后在不知情时抢走 CPA-Manager 的队列。
2. Descriptor 在提供 loader 的同一变更里固定 `supportsTokenCost: true` + `supportsTokenSnapshot: true`。`ProviderDescriptorRegistry` 是静态的；tracking **不得** 动态改能力位。
3. `SpendDashboardSource.costCapableProviders` 无特殊 case：CLIProxyAPI 只要 provider enabled 且 Usage & Spend 总开关开就入列。tracking 关闭时仍占一行，loader 返回 confirmed-empty + “Spend tracking is off”，**不 pop**。
4. 若 tracking 开启且 provider enabled：`CLIProxyAPIProviderRuntime` 在应用生命周期内跑 `CLIProxyAPISpendCollector`（不依赖 Settings 页是否打开，禁止挂在 dashboard scan 上）。
   - Tick ≤ 5s。每 tick：先 `GET /v0/management/usage-statistics-enabled`。false 则停止本轮 pop，把状态标成可行动错误（到 CPA config 打开 `usage-statistics-enabled`），不假装 $0。不要静默 PUT 打开该开关。
   - 主路径：`GET /v0/management/usage-queue?count=200`（query 必带且 >1；上游缺省为 1）。**响应返回即已从 CPA 删除**。解码后同步写入本地 store；persist 失败记 dropped/skipped，无法回放。循环直到空响应或本轮上限（例如 50 次 GET / 10_000 条），不得只拉一轮就睡。
   - 无 ack 步骤。方法名保持 `popUsageQueue`，禁止包装成只读。
   - 去重键：`request_id`；空则 `timestamp + auth_index + model`。
   - `api_key` 解码后立即丢弃，event / store / log 禁止原值。
5. Collector 将记录规范为内部 event：`occurredAt`、`provider`、`model`、`authIndex`、token mix、`failed`。失败请求计入 request coverage 的 unmetered，不计入 cost。
6. `CLIProxyAPISpendAggregator` 按 Usage & Spend 的 pinned IANA 日历把 event 打成 `CostUsageDailyReport.Entry`，再用 custom overlay → models.dev → bundled Codex/Claude list price 填 `costUSD`。未知模型 unpriced，不编造价格。
7. `CostUsageFetcher.loadRemoteTokenSnapshot` 增加 `.cliproxyapi` 分支：读 store 聚合结果，返回非 nil `CostUsageTokenSnapshot`（historyDays 随 dashboard scan window，provenance `.listPriceEstimate`）。tracking 关、统计关、连不上、401 各映射到 §5.4。**禁止返回 nil 掉进本地 scanner**。
8. Descriptor：`noDataMessage` 留一句 generic fallback。四种运行时原因走 loader error / snapshot `historyLabel`，UI 已有 error/empty 通道。
9. 菜单卡片：配额窗口保持现有 extra rows。Cost 区随 `supportsTokenCost` 显示；tracking 关或 snapshot 空时走 empty/error，不编造数字。配额失败不得清 spend store，spend 失败不得清配额 snapshot。
10. 停用 provider 或关闭 tracking 时：停止 poll；已落盘历史保留，直到用户清 cache。隐藏源走现有 `spendDashboardHiddenSourceIDs`。
11. Usage & Spend 同币种 `CurrencyGroup.totalCost` / `totalTokens` **排除** `cliproxyapi`，避免与 native Codex/Claude 行双计。该行仍可见，disclaimer “Observed by CLIProxyAPI, not a bill”。v1 不提供 hide-native 开关。

### 5.3 接口 / 配置 / 数据结构变更

接口：

- `CLIProxyAPIManagementClient` 新增破坏性方法：`usageStatisticsEnabled()`、`popUsageQueue(count:)`。禁止把 pop 封装成「看起来只读」的名字。`popUsageQueue` 必须带 `count` query 且默认 200。
- `CLIProxyAPIUsageFetcher.fetchUsage` 保持配额-only。不要把 spend 塞进同一返回值。
- `CostUsageFetcher.loadRemoteTokenSnapshot` 识别 `.cliproxyapi`，始终返回 snapshot 或抛 typed error。
- `UsageStore.tokenCostRequiresProviderSnapshot` **不** 把 cliproxyapi 加进去。Spend 走独立 token snapshot，与 Cursor/Claude 相同，避免配额 `UsageSnapshot` 被误当成 cost 源。
- `UsageStore.loadTokenUsageSnapshot` 对 `.cliproxyapi` 与 Bedrock 一样走 `ProviderRegistry.makeEnvironment`，以便 management key / base URL / tracking 进入 loader 环境。

配置：

- 现有：`apiKey`（management key）、`enterpriseHost`（base URL）、`workspaceID`（auth_index，仅配额过滤）。
- 新增：`ProviderConfig.extrasEnabled` → CodexBar spend tracking（bool，默认 false）。环境变量 `CLIPROXYAPI_SPEND_TRACKING` 供测试注入。
- `workspaceID` **不** 过滤 spend 聚合；代理总览需要全账户。配额仍可按 auth_index 过滤。
- v1 不读 `cliproxyapiSpendImportURL`。

数据结构：

- `CLIProxyAPISpendEvent`：request_id、occurredAt、authIndex、upstreamProvider、model、alias、token mix、failed、statusCode。禁止 `api_key` 字段。
- Store：`Application Support/CodexBar/cliproxyapi-spend/cliproxyapi-spend.sqlite`。schema version；损坏时隔离重建，不得删配额缓存。
- Snapshot：标准 `CostUsageTokenSnapshot.daily[]`；`sessions` 用 auth_index 当 session 维；`credentialScopeFingerprint` 用 management base URL + key SHA-256，防止换 endpoint 后串账。

设置 UI：

- Providers → CLIProxyAPI 增加 Spend tracking 开关。
- 文案必须写清两道开关：CodexBar tracking **和** CPA `usage-statistics-enabled`（默认关）。开启 tracking 后 CodexBar 会从 CPA `usage-queue` **取出** 记录并本地保存；若正在使用 CPA-Manager，不要双开消费。

文档：

- 更新 `docs/cliproxyapi.md` 与 `docs/providers.md` Usage & Spend 源列表，把 CLIProxyAPI 标为 opt-in proxy-observed estimate，并写明数据前提与 pop 合同。

### 5.4 错误处理与回退策略

- CPA 未运行 / 连接拒绝：配额走现有 error；spend 若 store 有历史则返回该 snapshot 并在 `historyLabel` 标 stale；store 为空则 confirmed-empty + “CLIProxyAPI is not reachable at {base}”。`.cliproxyapi` 远程分支不返回 nil。
- 401/403 management key：双方都 fail closed，不把旧别人的账户数据挂到新 key。fingerprint 不匹配则不发布。
- `usage-statistics-enabled=false`：不 pop；typed error，可行动文案要求打开 CPA config。不假装 0 美元。store 已有历史仍可展示，但必须同时暴露该错误，不得把空队列当成「无请求」。
- `usage-queue` 空：正常（TTL 短或本 tick 已抽空）。只要 store 有历史就展示历史。
- 解码失败：跳过坏记录，累计 skipped count；只有当一次 poll 全部失败且 store 空时才升为 error。
- persist 失败：事件已从 CPA 消失，记 dropped。不得重 GET 指望同一条回来。
- 与 CPA-Manager 双消费：无法在协议层检测。缓解靠默认关闭 tracking 与设置警告。
- 定价缺失：token 仍展示，cost 走 unpriced coverage，与 Codex scanner 相同。
- 关闭 tracking：停止 collector，不再 pop。loader 仍入源列表，返回 confirmed-empty + “Spend tracking is off”。已落盘历史保留但不展示为当前 spend（confirmed-empty 优先于旧数字，避免用户以为仍在采集）。

### 5.5 风险与缓解

- 风险：消费队列抽空 CPA-Manager。
  - 缓解：默认关闭；文档/设置明确 “pops usage-queue”。
- 风险：60s TTL 导致 CodexBar 没开或 tick 过慢时丢事件。
  - 缓解：进程级 collector、tick ≤ 5s、每 tick drain-until-empty；未运行期间的缺口用 coverage gap，不是 0；建议 login item。
- 风险：与 native Codex/Claude 日志双计。
  - 缓解：独立 source id `cliproxyapi`；disclaimer；CurrencyGroup 合计排除 CLIProxyAPI。
- 风险：`api_key` 字段进入 store/日志。
  - 缓解：解码后立即丢弃；event 结构禁止该字段；测试用带 `api_key` 的 fixture 断言 store/log 不含原值。
- 风险：打开 `supportsTokenCost` 后无 loader，页面从「省略」变成 error。
  - 缓解：能力位与 loader、store、测试同一落地；tracking 默认关时返回 confirmed-empty 而不是 throw。
- 风险：sibling `async let` 把必选 poll 和可选工作绑在一起。
  - 缓解：顺序 await。v1 无可选 import。
- 风险：实现者去找 ack API 或只拉 50–200 条就睡。
  - 缓解：合同写死 GET=pop、立即落盘、drain-until-empty；测试锁定 `count` query。
## 6. 验证计划

- 单测 `CLIProxyAPIManagementClient`：`usage-queue` JSON fixture（真实 `*_tokens` tag、token mix、`failed`、缺 model、含 `api_key`）；确认 pop URL、Bearer、`count` query 必带且 >1；断言解码后无 `api_key`。
- 单测 aggregator：同一 `request_id` 不双计；failed 不计 cost；跨日按 pinned timezone 分桶；未知模型 unpriced。
- 单测 descriptor：`supportsTokenCost && supportsTokenSnapshot` 为静态 true，与 tracking 无关。
- 单测 `costCapableProviders`：provider enabled + cost usage enabled 时包含 `.cliproxyapi`，**即使 tracking 关闭**。tracking 关时 daily 为空、文案可行动。
- 单测 loader：tracking 关 / 统计关 / 连不上 / 401 都不返回 nil；统计关不假装 $0。
- 单测 collector：单 tick drain-until-empty（多页 `count=200` 直到空）；persist 失败不重放 CPA；tick 间隔 ≤5s 由注入 clock 锁定。
- 单测 spend dashboard：CLIProxyAPI 行不 merge 进 Codex；hiddenSourceIDs 可藏；fingerprint 变化丢弃旧 publication；同币种 group total 不含 cliproxyapi。
- 回归：现有 `CLIProxyAPIUsageFetcherTests` 配额窗口、auth kind 过滤、loopback URL 保持原样。`ProviderArchitectureGatekeeperTests` 的 `supportsTokenSnapshot` 集合加上 `.cliproxyapi`。
- 聚焦：`swift test --filter CLIProxyAPI` 以及新增 `CLIProxyAPISpend*`。落地前 `make check` 与 `make test`。禁止对真实 CPA 账户做 live probe，除非用户明确要求。
- 对照：不改 loader、只翻 `supportsTokenCost` 的路径必须不再存在——能力位与 loader 同一变更。

根因前提验证：省略是合同 + 缺 loader，而不是 UI 漏渲染。打开能力位后无 loader 会 `unsupportedProvider`；本变更必须两者一起提供。

## 7. 关键决策摘要

- Usage & Spend 无输出的根因是合同排除（`supportsTokenCost == false`）加上没有 `CostUsageTokenSnapshot` 源，不是安装路径或 JSONL 扫漏。
- 现有 CLIProxyAPI 探测只做上游配额 remaining，故意不跟踪 cost history。
- CPA `usage-queue` 是唯一可用的请求级 token 源，但是消费型短缓存；GET 即 pop，无 ack。CodexBar 必须自己持久化。
- CPA `usage-statistics-enabled` 默认 false，是数据前提，不是「部分安装」。
- 采用独立 CLIProxyAPI spend collector（默认关闭）+ 进程级 ≤5s drain；拒绝把 Codex/Claude 本地日志记到该 provider；v1 拒绝 RESP subscribe 与 Manager 导入。
- 能力位静态 true；tracking 只闸 collector。关闭 tracking 仍占 Usage & Spend 一行。
- 配额与支出失败域隔离。
- 成本 provenance 固定为 list-price estimate；UI 标明 proxy-observed；group total 排除该行。

## 8. 修订记录

- 2026-08-21 / design-implement：采纳评审 HIGH-1–4 与落地所需 MEDIUM。删除 ack；GET=pop 立即落盘并 drain-until-empty。纠正 `usage-statistics-enabled` 默认为 false 并列数据前提。静态 `supportsTokenCost/supportsTokenSnapshot`，tracking 只闸 collector，测试与 `costCapableProviders` 对齐。规定进程级 collector tick ≤5s。decoder 按真实 json tag；drop `api_key`；远程分支永不返回 nil。v1 移出 CPA-Manager 导入并显式拒绝 RESP subscribe。同币种合计排除 CLIProxyAPI。

## 9. Handoff

### 9.1 同会话继续

直接执行 $design-implement 或 /design-implement

### 9.2 新会话恢复 prompt

```text
请阅读设计输入 docs/superpowers/specs/2026-08-20-cliproxyapi-usage-spend-design.md
以及评审文档 docs/superpowers/plans/2026-08-20-cliproxyapi-usage-spend-design-review.md，
重点核对根因分析（如有）、事实/假设边界、以及方案修订点，
使用 $design-implement（或 /design-implement）进行方案修订及实现。
重点关注：HIGH-1 删除不存在的 ack、按 GET 即 pop 立即落盘并 drain-until-empty；HIGH-2 纠正 usage-statistics-enabled 默认为 false 并列为数据前提；HIGH-3 统一 supportsTokenCost 与 tracking 开关、costCapableProviders 和测试合同；HIGH-4 规定进程级 collector 周期（≤5s）与 60s TTL 下的抽空循环。
```
## 8. Handoff

### 8.1 同会话继续

直接执行 $design-review 或 /design-review

### 8.2 新会话恢复 prompt

```text
请阅读设计文档 docs/superpowers/specs/2026-08-20-cliproxyapi-usage-spend-design.md，
使用 $design-review（或 /design-review）对该方案进行评审；若文档包含根因分析，
请一并分析根因判断、证据与设计方案是否正确、合理，以及两者是否一致。
```
