import Foundation

public enum CLIProxyAPISpendAggregator {
    struct DayAccumulator {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheCreation = 0
        var reasoning = 0
        var tokens = 0
        var cost: Double = 0
        var sawInput = false
        var sawOutput = false
        var sawCacheRead = false
        var sawCacheCreation = false
        var sawReasoning = false
        var sawTokens = false
        var sawCost = false
        var priced = 0
        var unpriced = 0
        var unmetered = 0
        var estimated = 0
        var models: [String: ModelAccumulator] = [:]
    }

    struct ModelAccumulator {
        var tokens = 0
        var cost: Double = 0
        var sawTokens = false
        var sawCost = false
        var input: Int?
        var output: Int?
        var cacheRead: Int?
        var cacheCreation: Int?
        var reasoning: Int?
    }

    struct SessionAccumulator {
        var lastActivity = Date.distantPast
        var input: Int?
        var output: Int?
        var cacheRead: Int?
        var reasoning: Int?
        var tokens: Int?
        var requests = 0
        var cost: Double?
        var models: [String: ModelAccumulator] = [:]
    }

    public static func snapshot(
        events: [CLIProxyAPISpendEvent],
        now: Date,
        historyDays: Int,
        calendar: Calendar,
        customPricing: CostUsageCustomPricing = .empty,
        credentialScopeFingerprint: String? = nil,
        historyLabel: String? = nil,
        historyCoverageIsEstablished: Bool = true) -> CostUsageTokenSnapshot
    {
        let days = max(1, min(365, historyDays))
        let today = calendar.startOfDay(for: now)
        let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        var unique: [String: CLIProxyAPISpendEvent] = [:]
        for event in events {
            unique[event.dedupeKey] = event
        }
        let windowed = unique.values.filter { $0.occurredAt >= windowStart && $0.occurredAt <= now }
            .sorted { lhs, rhs in
                if lhs.occurredAt != rhs.occurredAt {
                    return lhs.occurredAt < rhs.occurredAt
                }
                return lhs.dedupeKey < rhs.dedupeKey
            }

        var daysByKey: [String: DayAccumulator] = [:]
        var sessions: [String: SessionAccumulator] = [:]
        for event in windowed {
            let dayKey = CostUsageLocalDay.key(from: event.occurredAt, calendar: calendar)
            var day = daysByKey[dayKey] ?? DayAccumulator()
            Self.merge(event, into: &day, customPricing: customPricing)
            daysByKey[dayKey] = day

            let sessionID = event.authIndex.isEmpty ? event.dedupeKey : event.authIndex
            var session = sessions[sessionID] ?? SessionAccumulator()
            session.lastActivity = max(session.lastActivity, event.occurredAt)
            session.requests += 1
            Self.merge(event, into: &session, customPricing: customPricing)
            sessions[sessionID] = session
        }

        let daily = daysByKey.keys.sorted().compactMap { key -> CostUsageDailyReport.Entry? in
            guard let day = daysByKey[key] else { return nil }
            return Self.entry(dayKey: key, day: day)
        }
        let sessionRows = sessions.keys.sorted().compactMap { key -> CostUsageSessionBreakdown? in
            guard let session = sessions[key] else { return nil }
            return CostUsageSessionBreakdown(
                sessionID: key,
                lastActivity: session.lastActivity,
                inputTokens: session.input,
                cachedInputTokens: session.cacheRead,
                outputTokens: session.output,
                reasoningTokens: session.reasoning,
                totalTokens: session.tokens,
                requestCount: session.requests,
                costUSD: session.cost,
                modelBreakdowns: Self.modelBreakdowns(session.models))
        }
        .sorted { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity {
                return lhs.lastActivity > rhs.lastActivity
            }
            return lhs.sessionID < rhs.sessionID
        }

        return CostUsageFetcher.tokenSnapshot(
            from: CostUsageDailyReport(data: daily, summary: nil),
            now: now,
            historyDays: days,
            useCurrentLocalDayForSession: true,
            calendar: calendar,
            historyCoverageIsEstablished: historyCoverageIsEstablished,
            costProvenance: .listPriceEstimate,
            credentialScopeFingerprint: credentialScopeFingerprint,
            historyLabel: historyLabel,
            sessions: Array(sessionRows.prefix(64)),
            updatedAt: now)
    }

    private static func merge(
        _ event: CLIProxyAPISpendEvent,
        into day: inout DayAccumulator,
        customPricing: CostUsageCustomPricing)
    {
        let tokens = event.tokens
        if let input = tokens.inputTokens {
            day.input += input
            day.sawInput = true
        }
        if let output = tokens.outputTokens {
            day.output += output
            day.sawOutput = true
        }
        if let cacheRead = tokens.cacheReadTokens {
            day.cacheRead += cacheRead
            day.sawCacheRead = true
        }
        if let cacheCreation = tokens.cacheCreationTokens {
            day.cacheCreation += cacheCreation
            day.sawCacheCreation = true
        }
        if let reasoning = tokens.reasoningTokens {
            day.reasoning += reasoning
            day.sawReasoning = true
        }
        if let total = tokens.totalTokens {
            day.tokens += total
            day.sawTokens = true
        } else if let inferred = Self.inferredTotal(tokens) {
            day.tokens += inferred
            day.sawTokens = true
        }

        if event.failed {
            day.unmetered += 1
        } else if let cost = Self.listPriceUSD(event: event, customPricing: customPricing) {
            day.priced += 1
            day.cost += cost
            day.sawCost = true
        } else {
            day.unpriced += 1
        }

        var model = day.models[event.model] ?? ModelAccumulator()
        Self.merge(event, cost: event.failed ? nil : Self.listPriceUSD(event: event, customPricing: customPricing), into: &model)
        day.models[event.model] = model
    }

    private static func merge(
        _ event: CLIProxyAPISpendEvent,
        into session: inout SessionAccumulator,
        customPricing: CostUsageCustomPricing)
    {
        session.input = Self.add(session.input, event.tokens.inputTokens)
        session.output = Self.add(session.output, event.tokens.outputTokens)
        session.cacheRead = Self.add(session.cacheRead, event.tokens.cacheReadTokens)
        session.reasoning = Self.add(session.reasoning, event.tokens.reasoningTokens)
        session.tokens = Self.add(
            session.tokens,
            event.tokens.totalTokens ?? Self.inferredTotal(event.tokens))
        if !event.failed, let cost = Self.listPriceUSD(event: event, customPricing: customPricing) {
            session.cost = Self.add(session.cost, cost)
        }
        var model = session.models[event.model] ?? ModelAccumulator()
        Self.merge(
            event,
            cost: event.failed ? nil : Self.listPriceUSD(event: event, customPricing: customPricing),
            into: &model)
        session.models[event.model] = model
    }

    private static func merge(
        _ event: CLIProxyAPISpendEvent,
        cost: Double?,
        into model: inout ModelAccumulator)
    {
        model.input = Self.add(model.input, event.tokens.inputTokens)
        model.output = Self.add(model.output, event.tokens.outputTokens)
        model.cacheRead = Self.add(model.cacheRead, event.tokens.cacheReadTokens)
        model.cacheCreation = Self.add(model.cacheCreation, event.tokens.cacheCreationTokens)
        model.reasoning = Self.add(model.reasoning, event.tokens.reasoningTokens)
        if let tokens = event.tokens.totalTokens ?? Self.inferredTotal(event.tokens) {
            model.tokens += tokens
            model.sawTokens = true
        }
        if let cost {
            model.cost += cost
            model.sawCost = true
        }
    }

    private static func entry(dayKey: String, day: DayAccumulator) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: dayKey,
            inputTokens: day.sawInput ? day.input : nil,
            outputTokens: day.sawOutput ? day.output : nil,
            cacheReadTokens: day.sawCacheRead ? day.cacheRead : nil,
            cacheCreationTokens: day.sawCacheCreation ? day.cacheCreation : nil,
            reasoningTokens: day.sawReasoning ? day.reasoning : nil,
            totalTokens: day.sawTokens ? day.tokens : nil,
            requestCount: day.priced + day.unpriced + day.unmetered + day.estimated,
            costUSD: day.sawCost ? day.cost : nil,
            modelsUsed: day.models.keys.sorted(),
            modelBreakdowns: self.modelBreakdowns(day.models),
            unpricedRequestCount: day.unpriced,
            unmeteredRequestCount: day.unmetered,
            estimatedRequestCount: day.estimated)
    }

    private static func modelBreakdowns(_ models: [String: ModelAccumulator]) -> [CostUsageDailyReport.ModelBreakdown] {
        models.keys.sorted().map { name in
            let model = models[name] ?? ModelAccumulator()
            return CostUsageDailyReport.ModelBreakdown(
                modelName: name,
                costUSD: model.sawCost ? model.cost : nil,
                totalTokens: model.sawTokens ? model.tokens : nil,
                inputTokens: model.input,
                outputTokens: model.output,
                cacheReadTokens: model.cacheRead,
                cacheCreationTokens: model.cacheCreation,
                reasoningTokens: model.reasoning)
        }
    }

    public static func listPriceUSD(
        event: CLIProxyAPISpendEvent,
        customPricing: CostUsageCustomPricing) -> Double?
    {
        self.listPriceUSD(
            event: event,
            customPricing: customPricing,
            modelsDevCatalog: nil,
            modelsDevCacheRoot: nil)
    }

    static func listPriceUSD(
        event: CLIProxyAPISpendEvent,
        customPricing: CostUsageCustomPricing,
        modelsDevCatalog: ModelsDevCatalog?,
        modelsDevCacheRoot: URL? = nil) -> Double?
    {
        guard !event.failed else { return nil }
        let tokens = event.tokens
        let input = tokens.inputTokens ?? 0
        let output = tokens.outputTokens ?? 0
        let cacheRead = tokens.cacheReadTokens ?? 0
        let cacheWrite = tokens.cacheCreationTokens ?? 0
        let hasTokenData = tokens.totalTokens != nil
            || tokens.inputTokens != nil
            || tokens.outputTokens != nil
            || tokens.cacheReadTokens != nil
            || tokens.cacheCreationTokens != nil
            || tokens.reasoningTokens != nil
        guard hasTokenData else { return nil }
        if let overlay = customPricing.costUSD(
            providerID: event.upstreamProvider,
            model: event.model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite)
        {
            return overlay
        }
        if let overlay = customPricing.costUSD(
            model: event.model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWriteTokens: cacheWrite)
        {
            return overlay
        }
        if let cost = Self.modelsDevCostUSD(
            event: event,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            catalog: modelsDevCatalog,
            cacheRoot: modelsDevCacheRoot)
        {
            return cost
        }
        if let cost = CostUsagePricing.codexCostUSD(
            model: event.model,
            inputTokens: input,
            cachedInputTokens: cacheRead,
            outputTokens: output,
            cacheWriteInputTokens: cacheWrite,
            pricingDate: event.occurredAt,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot)
        {
            return cost
        }
        return CostUsagePricing.claudeCostUSD(
            model: event.model,
            inputTokens: input,
            cacheReadInputTokens: cacheRead,
            cacheCreationInputTokens: cacheWrite,
            outputTokens: output,
            pricingDate: event.occurredAt,
            modelsDevCatalog: modelsDevCatalog,
            modelsDevCacheRoot: modelsDevCacheRoot)
    }

    private static func modelsDevCostUSD(
        event: CLIProxyAPISpendEvent,
        input: Int,
        output: Int,
        cacheRead: Int,
        cacheWrite: Int,
        catalog: ModelsDevCatalog?,
        cacheRoot: URL?) -> Double?
    {
        for providerID in Self.modelsDevProviderIDs(for: event.upstreamProvider) {
            let lookup = catalog?.pricing(providerID: providerID, modelID: event.model)
                ?? ModelsDevPricingPipeline.lookup(
                    providerID: providerID,
                    modelID: event.model,
                    now: event.occurredAt,
                    cacheRoot: cacheRoot)
            guard let pricing = lookup?.pricing else { continue }
            return CostUsageCustomPricing.costUSD(
                rates: CostUsageCustomPricing.Rates(
                    input: pricing.inputCostPerToken * 1_000_000,
                    output: pricing.outputCostPerToken * 1_000_000,
                    cacheRead: pricing.cacheReadInputCostPerToken.map { $0 * 1_000_000 },
                    cacheWrite: pricing.cacheCreationInputCostPerToken.map { $0 * 1_000_000 }),
                inputTokens: input,
                outputTokens: output,
                cacheReadTokens: cacheRead,
                cacheWriteTokens: cacheWrite)
        }
        return nil
    }

    private static func modelsDevProviderIDs(for upstreamProvider: String) -> [String] {
        let key = upstreamProvider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "gemini", "google", "antigravity":
            return ["google"]
        case "grok", "xai":
            return ["xai"]
        case "openai", "codex":
            return ["openai"]
        case "claude", "anthropic":
            return ["anthropic"]
        case "":
            return []
        default:
            return [key]
        }
    }

    private static func inferredTotal(_ tokens: CLIProxyAPISpendTokenMix) -> Int? {
        let parts = [
            tokens.inputTokens,
            tokens.outputTokens,
            tokens.reasoningTokens,
            tokens.cacheReadTokens,
            tokens.cacheCreationTokens,
        ].compactMap(\.self)
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0, +)
    }

    private static func add(_ lhs: Int?, _ rhs: Int?) -> Int? {
        switch (lhs, rhs) {
        case let (left?, right?): left + right
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): nil
        }
    }

    private static func add(_ lhs: Double?, _ rhs: Double?) -> Double? {
        switch (lhs, rhs) {
        case let (left?, right?): left + right
        case let (left?, nil): left
        case let (nil, right?): right
        case (nil, nil): nil
        }
    }
}
