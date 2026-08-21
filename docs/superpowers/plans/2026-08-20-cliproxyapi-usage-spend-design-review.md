# Design Review: cliproxyapi-usage-spend

- Date: 2026-08-20
- Reviewed Design: docs/superpowers/specs/2026-08-20-cliproxyapi-usage-spend-design.md
- Review Scope: 根因（Usage & Spend 对 CLIProxyAPI 无输出）与方案 C（自建 usage collector → 本地 store → `CostUsageTokenSnapshot`）。对照 CodexBar 现有 spend/descriptor/fetcher 合同，以及 CLIProxyAPI main 的 management / usage-queue 协议。

## 1. 整体结论
- NEEDS_REVISION
- 一句话结论：根因成立，方案方向（独立 CLIProxyAPI spend source + 本地持久化，拒绝把 Codex/Claude JSONL 记到该行）正确；但消费协议写成了不存在的 ack、CPA 统计开关默认值写反、能力位与 tracking 测试合同自相矛盾、collector 相对 60s TTL 的周期未定义，必须先修订再实现。

## 2. 根因评审结论（按需）
- 适用性：适用
- 结论：SUPPORTED
- 理由：文档把「无数据」锁成 Usage & Spend 合同排除 + 没有 `CostUsageTokenSnapshot` loader，而不是安装路径、JSONL 扫漏或配额探测失败。CodexBar 代码与 CLIProxyAPI 上游协议都支撑这条主链。个别上游事实（`usage-statistics-enabled` 默认值）写错，不推翻根因，但会扭曲方案的主路径前提。

### 2.1 证据检查
- **合同排除（成立）**：`SpendDashboardSource.costCapableProviders` 过滤 `SettingsStore.isCostUsageEffectivelyEnabled`，后者要求 `descriptor.tokenCost.supportsTokenCost`。证据：`Sources/CodexBar/SpendDashboardController.swift:532-535`、`Sources/CodexBar/SettingsStore+MenuPreferences.swift:257-261`。`docs/providers.md` §Usage & Spend settings 写明未声明 token-cost 的 provider 会被省略。
- **CLIProxyAPI 显式关闭支出（成立）**：`CLIProxyAPIProviderDescriptor` 为 `supportsTokenCost: false`，`supportsTokenSnapshot` 走默认 `false`，`noDataMessage` 为 “CLIProxyAPI cost history is not tracked in this provider.”。证据：`Sources/CodexBarCore/Providers/CLIProxyAPI/CLIProxyAPIProviderDescriptor.swift:66-68`、`ProviderTokenCostConfig` 默认值 `Sources/CodexBarCore/Providers/ProviderDescriptor.swift:44`。
- **打开开关仍无 loader（成立）**：`CostUsageFetcher.loadTokenSnapshot` 在 `supportsTokenSnapshot == false` 时抛 `CostUsageError.unsupportedProvider`。`loadRemoteTokenSnapshot` 只处理 Bedrock 与 Cursor，其余返回 nil。证据：`Sources/CodexBarCore/CostUsageFetcher.swift:422-424, 994-996, 1570-1601`。
- **菜单 Cost 区同样 gated（成立）**：`MenuCardView+Costs.tokenUsageSection` 在 `supportsTokenCost == false` 时返回 nil。证据：`Sources/CodexBar/MenuCardView+Costs.swift:181-185`。
- **现有探测只做配额（成立）**：`CLIProxyAPIUsageFetcher` 只走 auth-files + api-call，返回 `UsageSnapshot`；`CLIProxyAPISnapshotMapper.accountUsage` 在窗口缺失时返回 nil，整账户丢弃。不填 `providerCost` / daily token 历史。
- **auth kind 过滤（成立）**：`CLIProxyAPIAuthKind` 只有 codex / gemini / antigravity / grok；`mapResolvedAuth` 其余返回 nil。`docs/cliproxyapi.md` 写明 Copilot 等 listed but not probed。这解释配额卡可能空，但不是 Usage & Spend 省略的原因。
- **usage-queue 是短 TTL 消费队列（成立）**：`GetUsageQueue` 调用 `redisqueue.PopOldest`；`popOldest` 前进 `head` 即删除；默认 retention 60s，上限 3600s。证据：CLIProxyAPI `internal/api/handlers/management/usage.go`、`internal/redisqueue/queue.go`。本仓库无 usage-queue 实现，仅设计文档提及。
- **payload 足够做日桶（成立）**：队列 JSON 含 `timestamp`、`auth_index`、`provider`、`model`、`alias`、`tokens.{input_tokens,output_tokens,reasoning_tokens,cached_tokens,cache_read_tokens,cache_creation_tokens,total_tokens}`、`failed`、`request_id`。证据：CLIProxyAPI `internal/redisqueue/plugin.go`。字段名与设计文档的 `tokens.input` 写法不一致，见 MEDIUM-1。
- **api-key-usage 不够（成立）**：仅 success/failed + recent request buckets，无 token、无美元，且只覆盖 api_key auth。
- **同类代理不进 Usage & Spend（成立）**：LiteLLM / LLM Proxy / ClawRouter / ai& 均为 `supportsTokenCost: false`，spend 走菜单 `providerCost`。CLIProxyAPI 连 `providerCost` 都没有。
- **OpenCodex 先例（成立，但产品形态不同）**：`docs/providers.md:38-40` 与 `Sources/CodexBar/SpendDashboardSource+OpenCodex.swift` 确认 opt-in、只读 JSONL、不与 native Codex 合并。OpenCodex **不是** `costCapableProviders` 里的 first-party provider，而是 dashboard 附加源；设计要把 CLIProxyAPI 做成一等 native 源，这是有意分叉，不是根因错误。
- **`tokenCostRequiresProviderSnapshot`（成立）**：仅 mistral / openai / opencodego / openrouter。不把 cliproxyapi 加进去的决策正确。证据：`Sources/CodexBar/UsageStore+TokenCost.swift:472-477`。

未在本仓库验证、但不阻断根因：CPA-Manager 如何消费队列（pop vs RESP subscribe）；本机是否同时跑面板。文档已标为假设。

### 2.2 事实 / 假设边界检查
- 主根因（合同排除 + 无 snapshot 源）是事实，不是假设。§3.3 对「用量与支出 = Settings 页」「可能与 CPA-Manager 双消费」「代理流量与 native JSONL 重叠」的划分清楚。
- **把假设写成事实的一处**：§2 / §3.2 写 `usage-statistics-enabled`「默认 true」。CLIProxyAPI `config.example.yaml` 为 `usage-statistics-enabled: false`；Go `bool` 零值也是 false；上游 issue #3048 亦记录默认 false。关掉则 `HandleUsage` 直接 return，队列永远空。这不是「部分安装」，而是默认安装。
- **协议细节写成了不存在的步骤**：§5.2「写入 store，再 ack 成功」。HTTP `GET /v0/management/usage-queue` **就是** pop，没有第二阶段 ack。进程在 pop 之后、落盘之前崩溃会丢事件，不是设计说的「允许重复」。
- §3.3「当前 main 没有非破坏性 HTTP 路由」对 HTTP 成立；同进程存在 `SubscribeUsage()`，且 `internal/api/redis_queue_protocol.go` 经端口复用提供 Redis RESP subscribe。设计未评估这条非破坏通道，但不改变「今天 Usage & Spend 为何为空」。

### 2.3 对方案的影响检查
- 根因 → 必须同时打开能力位 **并** 提供 loader：成立。只翻 `supportsTokenCost` 会进源列表然后 `unsupportedProvider`。
- 根因 → 不能用 Codex/Claude JSONL 冒充 CLIProxyAPI：成立。`CostUsageScanner.loadDailyReportCancellable` 对非 codex/claude/vertexai 返回空报告，方案 B 即使得 `supportsTokenSnapshot == true` 也不会扫到代理流量；即使误扫，所有权仍然错误。
- 根因 → 必须本地持久化消费队列：成立。
- 根因 **不** 自动推出「GET 后再 ack」或「统计开关默认已开」。这两处是方案层错误，见 HIGH-1 / HIGH-2。
- 方案 C + 可选 D 的方向与根因一致；不需要推翻重选 A/B。

## 3. 设计方案评审

### 3.1 需求与方向
- 解决的是正确问题：Settings → Usage & Spend 省略 CLIProxyAPI，不是配额卡刷新失败。
- 成功标准清晰：独立行、日桶同构、配额/支出隔离、不与 native JSONL 合并、消费必须持久化、空态可见、不回归配额测试。
- 方案对比充分：A 不解决问题，B 违反数据隔离，D 不能当唯一源。C 是正确方向。
- 更好的路径仍在 C 内部：优先考虑非破坏订阅（RESP `SubscribeUsage`），HTTP pop 仅在用户确认独占消费者时启用。即使因 RESP 默认关闭而仍选 pop，也必须把「独占消费者」写成产品合同，而不是发明 ack。
- 不建议改走菜单 `providerCost`（LiteLLM 路线）：那解决不了 Usage & Spend 源集合问题，与成功标准不符。

### 3.2 方案合理性
- 配额流水线不动、支出走独立 collector/store/snapshot，符合现有 `UsageSnapshot` vs `CostUsageTokenSnapshot` 分裂，也符合 `tokenCostRequiresProviderSnapshot` 不把 cliproxyapi 算进去的约束。
- `loadRemoteTokenSnapshot` 增加 `.cliproxyapi` 分支，与 Bedrock/Cursor 同构，技术可行。
- `credentialScopeFingerprint` 用 management base URL + key fingerprint，符合现有 snapshot 防串账字段。
- 失败域隔离（配额失败不清 spend store，反之亦然）正确。
- 边界覆盖有缺口：ack 不存在；统计开关默认关；collector 不是 dashboard 刷新的副产品，必须是进程级、周期远小于 60s、单次 poll drain-until-empty；高 QPS 时 `count=50–200` 一次不够。
- tracking 默认关，避免安装后抢走 CPA-Manager 队列，产品上正确。但成功标准要求「收集器关闭时仍显示 empty 行」，与 §6 测试「tracking on 才进入 `costCapableProviders`」冲突。
- `ProviderDescriptor.tokenCost` 是进程级静态注册表，不能按设置项动态改 `supportsTokenCost`。tracking 只能闸 collector/loader，不能闸 descriptor 能力位，除非另做 OpenCodex 式的 dashboard 过滤器。

### 3.3 实现可行性
- CodexBar 已有 `CLIProxyAPIManagementClient`（Bearer + `v0/management` 前缀 + loopback HTTP 校验）、`CostUsageStore`（SQLite、schema、损坏重建）、OpenCodex 的独立源与 disclaimer 模式。主路径可落地。
- CPA-Manager JSONL/SQLite 导入没有 schema/版本合同，作为 v1 必做项会把工期变成无界。应降为明确非目标或单独后续，直到钉死文件格式。
- 可测试性好：management client fixture、aggregator 去重/分桶、descriptor 合同、fingerprint 丢弃，都能单测。对照测试「只翻开关不提供 loader」能锁住根因。
- 风险已识别双消费、TTL 丢事件、`api_key` 入日志、`async let`；其中 TTL 与双消费的缓解写了原则，但缺少可执行的周期与 drain 规格。

### 3.4 文档质量
- 结构完整，根因/方案/验证/决策摘要齐全，无明显 TODO。
- 内部不一致：§5.2.1 关闭 tracking 仍声明能力并返回 confirmed-empty；§5.2.8 打开能力位即可入列；§6 要求 tracking on 才进入 `costCapableProviders`。
- 上游事实错误：统计开关默认值；token JSON 字段名；不存在的 ack。
- `GET /usage-statistics-enabled` 未写 `/v0/management` 前缀。现有 `managementURL` 会自动补前缀，实现时用 `"usage-statistics-enabled"` 即可，文档应写全路径以免误接。

## 4. 主要发现

### CRITICAL
- 无

### HIGH

### [HIGH] 协议: usage-queue 没有 ack，GET 就是破坏性 pop

**位置**: §5.2 步骤 3「把弹出的记录立即写入 CodexBar 本地 store，再 ack 成功」；§5.3 `popUsageQueue` 命名

**问题**: CLIProxyAPI `GetUsageQueue` 在 handler 内调用 `PopOldest`；`popOldest` 前进 `head` 后记录即从内存队列消失。HTTP 层没有 ack、没有 visibility timeout、没有 nack 回放。设计把消费写成两阶段，实现者会去找不存在的 ack API，或误以为 pop 可重试。

**影响**: 按文档实现会卡住或漏实现落盘时机。真实失败模式是 pop 成功、persist 失败 → 事件永久丢失（不是文档说的「崩溃允许重复」）。重复只在「同一条记录被 enqueue 两次」或错误地重放本地缓冲时发生。

**建议**: 删除 ack。合同改为：`GET /v0/management/usage-queue?count=N` 返回即已从 CPA 删除；解码后同步写入本地 store，失败则记 dropped/skipped，无法向 CPA 回放。方法名保持 `popUsageQueue`，禁止包装成只读。崩溃去重键用 payload 已有的 `request_id`（可加 `timestamp + auth_index` 兜底）。单次 tick 必须 drain-until-empty（或直到本轮上限），不能只拉 50–200 条就睡。

### [HIGH] 前提: usage-statistics-enabled 默认是 false，不是 true

**位置**: §2「默认 true」；§3.2 同句；§3.3 写成「部分安装可能被关掉」；§5.2 先 GET 再决定是否 poll

**问题**: 上游 `config.example.yaml` 为 `usage-statistics-enabled: false`。Go 零值 false。plugin `HandleUsage` 在 `!UsageStatisticsEnabled()` 时直接 return，队列不入队。默认 CPA 安装上，即使用户打开 CodexBar tracking，Usage & Spend 仍会一直 empty。

**影响**: 实现会按「开关默认已开」写文案和测试；真实用户打开 tracking 后仍无数据，被误判为 collector bug。成功标准里的「已收集到代理请求」在默认 CPA 配置下不会发生。

**建议**: 把 CPA `usage-statistics-enabled: true` 写成数据前提。CodexBar 必须 GET `/v0/management/usage-statistics-enabled`；false 时明确错误（可行动：到 CPA config 打开，或文档说明）。默认不要静默 PUT 打开（那会改用户代理配置并增加内存占用）。设置文案写清两道开关：CodexBar tracking **和** CPA usage-statistics。

### [HIGH] 合同: supportsTokenCost / tracking / costCapableProviders / 测试三者不一致

**位置**: §1.2 成功标准「收集器关闭时显示 empty 而不是消失」；§5.2.1 tracking 关闭仍声明能力、loader 返回 confirmed-empty；§5.2.7–8 打开 `supportsTokenCost` 后无需特殊 case；§6「tracking 开启时 supportsTokenCost && supportsTokenSnapshot」且「tracking on 时才包含 `.cliproxyapi`」

**问题**: `ProviderDescriptorRegistry` 里 `tokenCost` 是静态的，不能随 Settings 翻转。成功标准要求关闭 tracking 仍占一行；测试要求 tracking on 才进源列表。两套合同不能同时成立。

**影响**: 实现者会二选一，测试按另一套失败；或试图运行时改 descriptor，破坏全局注册表。

**建议**: 选定一条并改测试：
1. **推荐（对齐 §1.2）**：descriptor 在提供 loader 的同一 PR 里固定 `supportsTokenCost: true` + `supportsTokenSnapshot: true`。CLIProxyAPI 只要 provider enabled 且 Usage & Spend 总开关开就入列。tracking 只闸 collector：关 → confirmed-empty + “Spend tracking is off”，不 pop。测试断言 tracking 关时仍在 `costCapableProviders`，且 daily 为空、文案可行动。
2. 若产品改为「关 tracking 就从列表消失」：保持 `supportsTokenCost: true`，在 `costCapableProviders`（或 OpenCodex 式过滤器）里额外要求 tracking on。同步改 §1.2。不要动态改 descriptor。

### [HIGH] 运行时: collector 周期、生命周期与 60s TTL 不匹配

**位置**: §5.2「周期性 GET」；§5.5「60s TTL 导致 CodexBar 没开时丢事件」；未规定 interval、是否进程级、是否仅 dashboard 打开时跑

**问题**: 队列默认 60s 淘汰。若 collector 挂在 Usage & Spend 刷新（分钟级）或只在打开 Settings 时跑，即使用户开着 CodexBar 也会丢事件。`count` 省略时上游默认 1。高 QPS 时 200 条/轮不够。

**影响**: 功能在「应用开着、tracking 开着」时仍然缺口，coverage gap 会被当成正常，数据不可用。

**建议**: 规格写死：tracking 开启且 provider enabled 时，collector 在应用生命周期内运行（不依赖 Settings 页是否打开）；tick ≤ 5s（或事件驱动）；每 tick drain-until-empty，单条 GET `count` 取上限（如 200）并循环直到空响应；进程退出即停 pop。未运行期间的缺口用 coverage gap，文档建议 login item 或改用 Manager 导入。禁止把 collector 做成 dashboard scan 的副作用。

### MEDIUM

### [MEDIUM] 协议: token JSON 字段名与设计文档不一致

**位置**: §2「`tokens.{input,output,reasoning,cached,cache_read,cache_creation,total}`」

**问题**: 上游是 `input_tokens` / `output_tokens` / `reasoning_tokens` / `cached_tokens` / `cache_read_tokens` / `cache_creation_tokens` / `total_tokens`，另有 `cache_read_tokens_present`。`request_id` 在 payload 里存在，设计把去重键写成 `request_id` 是对的，但字段清单写错。

**影响**: fixture 按文档手写会解码全 0，成本全进 unpriced 或 0 美元。

**建议**: 按 `plugin.go` 的 json tag 写 decoder；缺 model 时上游已填 `"unknown"`。测试覆盖 token mix 与 `failed`。

### [MEDIUM] loader: cliproxyapi 分支不得返回 nil 掉进本地 scanner

**位置**: §5.2.6；`CostUsageFetcher.loadTokenSnapshot` 在 `loadRemoteTokenSnapshot` 返回 nil 后走 `CostUsageScanner`

**问题**: scanner 对 `.cliproxyapi` 走 `default` 空报告，不会误扫 Codex JSONL，但会把「远程失败 / tracking 关」变成一份无 provenance 语义的空本地扫描结果，而不是设计要的 confirmed-empty / error。

**影响**: 空态、stale、fingerprint mismatch 可能被显示成「无请求」而不是可行动错误。

**建议**: `.cliproxyapi` 分支始终返回非 nil snapshot 或抛 typed error；tracking 关、统计关、连不上、401 各映射到文档 §5.4 的状态。禁止 nil fallthrough。

### [MEDIUM] 范围: CPA-Manager 导入无 schema，不应挡 v1

**位置**: §1.3、§4.4、§5.2.3、§5.3 `cliproxyapiSpendImportURL`

**问题**: 只读导入作为与 pop 互斥的降级源，方向对，但 JSONL/SQLite 路径、表结构、版本均未钉死。CPA-Manager 不是默认安装。

**影响**: v1 会被导入格式拖成无界；互斥测试也无法写死。

**建议**: v1 非目标：只做 pop + 本地 store。导入留后续，或单独补一份 schema 再进范围。互斥开关可先留配置位但默认忽略。

### [MEDIUM] 安全: 队列 payload 含明文 `api_key`

**位置**: §5.5 已提到丢弃/hash；§5.3 event 字段未列 `api_key`

**问题**: `queuedUsageDetail.APIKey` json 为 `api_key`。缓解原则对，但 decoder/store 合同没写「字段必须 drop」。

**影响**: debug log 或 SQLite 一旦原样落盘就是密钥泄漏。

**建议**: 解码后立即丢弃 `api_key`；event 结构禁止该字段；测试用带 `api_key` 的 fixture 断言 store/log 不含原值。

### [MEDIUM] 产品: 与 native Codex/Claude 并存时页面合计可能双计

**位置**: §1.2、§4.3、§5.5「不提供自动 hide-native」

**问题**: 独立 source id 能避免 merge 成一行，但不能避免 dashboard 若做跨源合计时把同一流量加两遍。OpenCodex 为此提供了 hide-native 开关；本方案明确不做。

**影响**: 用户打开 tracking 后「总支出」看起来翻倍，可信度下降。

**建议**: 确认 Usage & Spend 只有分源合计、没有跨源 grand total；若有，CLIProxyAPI 行必须排除在 grand total 外，或提供可选 hide-native（默认关）。Disclaimer 必须在该行可见。

### LOW

### [LOW] 文档: 管理 API 路径写短了

**位置**: §5.2 `GET /usage-statistics-enabled`

**问题**: 实际为 `GET /v0/management/usage-statistics-enabled`。现有 client 会补前缀，短路径在代码里可行、在文档里易误导。

**建议**: 文档写全路径；client 仍传相对 path。

### [LOW] 实现: count 默认 1

**位置**: §5.2 `count=N（N 取 50–200）`

**问题**: 上游 `count` 缺省为 1。漏 query 时每 tick 只吞 1 条。

**建议**: 测试锁定 query 必带且 >1；实现禁止省略。

### [LOW] descriptor: noDataMessage 是静态闭包

**位置**: §5.2.7「改为可行动文案（key / CPA 未运行 / tracking 关闭 / 尚无请求）」

**问题**: 现有 `noDataMessage` 不能按运行时原因分支。真正可行动文案应来自 snapshot / loader error，而不是 descriptor 一句静态话。

**建议**: descriptor 留一句 generic fallback；四种原因走 loader 错误或 empty reason enum，UI 已有 error/empty 通道。

## 5. 修订建议
1. 重写消费合同：GET = pop，无 ack；立即落盘；drain-until-empty；去重键用 `request_id`。
2. 纠正 `usage-statistics-enabled` 默认为 false；两道开关都写进设置/文档；false 时 fail 成可行动错误，不假装 $0。
3. 锁定能力位合同（推荐静态 `supportsTokenCost/supportsTokenSnapshot = true` + tracking 只闸 collector），并改 §6 测试与之对齐。
4. 规定进程级 collector：tick ≤ 5s、应用在就跑、每 tick 抽空队列。
5. decoder 按真实 json tag；drop `api_key`；cliproxyapi 远程分支永不返回 nil。
6. CPA-Manager 导入移出 v1，或先补 schema。
7. 在修订说明里显式拒绝 RESP subscribe（复杂度 / 示例配置写明 RESP 关闭）或改为订阅优先。不要留成实现期口头选择。
8. 核对 Usage & Spend 是否存在跨源合计；按 MEDIUM-5 处理双计。

## 6. 下一步建议
- 进入 `design-implement`（先修订设计文档上述 HIGH 项，再实现）。
- 理由：根因成立，方案 C 方向不需要推翻；缺陷是协议/合同/运行时规格，属于修订而非重设计。不要在 ack、默认统计开关、能力位测试合同未改之前写代码。

## 7. Handoff

### 7.1 如果进入修订及实现
**同会话继续**
`直接执行 $design-implement 或 /design-implement`

**新会话恢复 prompt**
```text
请阅读设计输入 docs/superpowers/specs/2026-08-20-cliproxyapi-usage-spend-design.md
以及评审文档 docs/superpowers/plans/2026-08-20-cliproxyapi-usage-spend-design-review.md，
重点核对根因分析（如有）、事实/假设边界、以及方案修订点，
使用 $design-implement（或 /design-implement）进行方案修订及实现。
重点关注：HIGH-1 删除不存在的 ack、按 GET 即 pop 立即落盘并 drain-until-empty；HIGH-2 纠正 usage-statistics-enabled 默认为 false 并列为数据前提；HIGH-3 统一 supportsTokenCost 与 tracking 开关、costCapableProviders 和测试合同；HIGH-4 规定进程级 collector 周期（≤5s）与 60s TTL 下的抽空循环。
```

### 7.2 如果回退重新设计
不适用。根因与方案方向成立，不路由到 `design-brainstorm`。
