import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct SpendDashboardModelTests {
    @Test
    func `count labels avoid plural agreement and localize numbers`() {
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(spendDashboardRefreshFailureText(1) == "Refresh failures: 1")
            #expect(spendDashboardRefreshFailureText(2) == "Refresh failures: 2")
            #expect(spendDashboardCoverageText(covered: 3, requested: 7) == "Coverage: 3 / 7")
        }
        CodexBarLocalizationOverride.$appLanguage.withValue("de") {
            #expect(spendDashboardRefreshFailureText(1234) == "Fehlgeschlagene Aktualisierungen: 1.234")
            #expect(spendDashboardCoverageText(covered: 3, requested: 30) == "Abdeckung: 3 / 30")
        }
        CodexBarLocalizationOverride.$appLanguage.withValue("fa") {
            #expect(codexBarLocalizedInteger(12) == "۱۲")
            #expect(spendDashboardDayRangeText(7) == "۷ روز")
            #expect(spendDashboardDayRangeText(30) == "۳۰ روز")
            #expect(spendDashboardDayRangeText(SpendDashboardSource.scanDays) == "همه")
            #expect(spendDashboardRankText(1234) == "#۱٬۲۳۴")
            #expect(spendDashboardRefreshFailureText(2) == "\(L("Refresh failures")): ۲")
            #expect(spendDashboardCoverageText(covered: 3, requested: 30) == "پوشش: ۳ / ۳۰")
        }
    }

    @Test
    func `Codex account indices use app locale numerals`() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpendDashboardModelTests-index-locale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let account = CodexVisibleAccount(
            id: "locale-account",
            email: "locale@example.com",
            authFingerprint: nil,
            storedAccountID: nil,
            selectionSource: .profileHome(path: home.path),
            isActive: true,
            isLive: true,
            canReauthenticate: true,
            canRemove: true)

        let persian = CodexBarLocalizationOverride.$appLanguage.withValue("fa") {
            SpendDashboardSource.codexRequest(
                account: account,
                homePath: home.path,
                providerName: "Codex",
                index: 1,
                count: 2)?.displayName
        }
        let arabic = CodexBarLocalizationOverride.$appLanguage.withValue("ar") {
            SpendDashboardSource.codexRequest(
                account: account,
                homePath: home.path,
                providerName: "Codex",
                index: 1,
                count: 2)?.displayName
        }

        #expect(persian == "Codex · #۲")
        #expect(arabic == "Codex · #٢")
    }

    @Test
    func `dashboard source contract includes only cost capable descriptors`() {
        let providers = Set(ProviderDescriptorRegistry.all
            .filter(\.tokenCost.supportsTokenCost)
            .map(\.id))
        #expect(providers == [
            .codex,
            .claude,
            .vertexai,
            .openai,
            .mistral,
            .bedrock,
            .cursor,
            .grok,
            .opencodego,
            .openrouter,
            .cliproxyapi,
            .xai,
            // Antigravity joined via the tokscale-compatible local usage readers.
            .antigravity,
        ])
    }

    @Test
    func `cliproxyapi observed spend stays visible but excluded from billed totals`() throws {
        let model = SpendDashboardModel.build(
            inputs: [
                Self.input(id: "native", provider: .codex, currency: "USD", cost: 8),
                Self.input(id: "proxy", provider: .cliproxyapi, currency: "USD", cost: 50),
            ],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)
        let group = try #require(model.groups.first)
        #expect(group.providers.map(\.id).sorted() == ["native", "proxy"])
        #expect(group.totalCost == 8)
        #expect(group.providers.first { $0.id == "proxy" }?.totalCost == 50)
    }

    @Test
    func `cliproxyapi-only observed spend remains available in group totals`() throws {
        let model = SpendDashboardModel.build(
            inputs: [
                Self.input(id: "proxy", provider: .cliproxyapi, currency: "USD", cost: 50),
            ],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)
        let group = try #require(model.groups.first)
        #expect(group.totalCost == 50)
        #expect(group.dailyPoints.map(\.cost) == [50])
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(spendDashboardGroupCostText(group) != "Spend unavailable")
            #expect(spendDashboardProvenanceText(group.provenance) != "Spend unavailable")
            #expect(SpendDailyChartPresentation(
                dailyPoints: group.dailyPoints,
                aggregateTotal: group.totalCost).content == .chart)
        }
    }

    @Test
    func `native currencies stay separate and rank only within their currency`() throws {
        let model = SpendDashboardModel.build(
            inputs: [
                Self.input(id: "usd-low", provider: .claude, currency: "usd", cost: 2),
                Self.input(id: "eur", provider: .openai, currency: "EUR", cost: 100),
                Self.input(id: "usd-high", provider: .codex, currency: "USD", cost: 8),
            ],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)

        #expect(model.groups.map(\.currencyCode) == ["EUR", "USD"])
        let eur = try #require(model.groups.first)
        #expect(eur.providers.map(\.id) == ["eur"])
        #expect(eur.providers.map(\.rank) == [1])
        #expect(eur.totalCost == 100)
        #expect(eur.models.map(\.modelName) == ["test-model"])
        #expect(eur.models.map(\.totalCost) == [100])
        let usd = try #require(model.groups.last)
        #expect(usd.providers.map(\.id) == ["usd-high", "usd-low"])
        #expect(usd.providers.map(\.rank) == [1, 2])
        #expect(usd.totalCost == 10)
        #expect(usd.models.allSatisfy { $0.modelName == "test-model" })
        #expect(usd.models.compactMap(\.totalCost).reduce(0, +) == 10)
    }

    @Test
    func `windows anchor to injected now and report covered days honestly`() throws {
        let snapshot = Self.snapshot(
            currency: "USD",
            entries: [
                Self.entry(day: "2026-07-16", cost: 1),
                Self.entry(day: "2026-07-09", cost: 2),
                Self.entry(day: "2026-07-08", cost: 4),
                Self.entry(day: "2026-08-01", cost: 100),
            ])
        let input = SpendDashboardModel.ProviderInput(provider: .claude, displayName: "Claude", snapshot: snapshot)

        let sevenDays = SpendDashboardModel.build(
            inputs: [input],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar)
        let group = try #require(sevenDays.groups.first)
        #expect(group.totalCost == 1)
        #expect(group.coveredDayCount == 7)
        #expect(group.providers.first?.coveredDayCount == 7)

        let thirtyDays = SpendDashboardModel.build(
            inputs: [input],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)
        #expect(thirtyDays.groups.first?.totalCost == 7)
        #expect(thirtyDays.groups.first?.coveredDayCount == 30)

        let cumulativeSnapshot = Self.snapshot(
            currency: "USD",
            entries: [
                Self.entry(day: "2026-07-16", cost: 1),
                Self.entry(day: "2026-07-09", cost: 2),
                Self.entry(day: "2026-07-08", cost: 4),
                Self.entry(day: "2026-06-06", cost: 8),
                Self.entry(day: "2026-08-01", cost: 100),
            ],
            historyDays: SpendDashboardSource.scanDays)
        let cumulativeInput = SpendDashboardModel.ProviderInput(
            provider: .claude,
            displayName: "Claude",
            snapshot: cumulativeSnapshot)
        #expect(SpendDashboardModel.build(
            inputs: [cumulativeInput],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar).groups.first?.totalCost == 7)
        let allTime = SpendDashboardModel.build(
            inputs: [cumulativeInput],
            requestedDays: SpendDashboardSource.scanDays,
            now: Self.now,
            calendar: Self.calendar)
        #expect(allTime.requestedDays == SpendDashboardSource.scanDays)
        #expect(allTime.groups.first?.totalCost == 15)
        #expect(allTime.groups.first?.coveredDayCount == SpendDashboardSource.scanDays)

        let futureSnapshot = Self.snapshot(
            currency: "USD",
            entries: [Self.entry(day: "2026-07-16", cost: 1)],
            updatedAt: Date(timeIntervalSince1970: 1_900_000_000))
        let futureModel = SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: futureSnapshot)],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)
        #expect(futureModel.groups.first?.coveredDayCount == 0)

        let shortSnapshot = Self.snapshot(
            currency: "USD",
            entries: [Self.entry(day: "2026-07-16", cost: 1)],
            historyDays: 7)
        let shortModel = SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: shortSnapshot)],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)
        #expect(shortModel.groups.first?.coveredDayCount == 7)
    }

    @Test
    func `chart domain uses the exact requested window despite sparse points`() throws {
        let input = SpendDashboardModel.ProviderInput(
            provider: .claude,
            displayName: "Claude",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [Self.entry(day: "2026-07-16", cost: 1)]))
        let sevenDays = try #require(SpendDashboardModel.build(
            inputs: [input],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)
        let thirtyDays = try #require(SpendDashboardModel.build(
            inputs: [input],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar).groups.first)
        let anchor = Self.calendar.startOfDay(for: Self.now)
        let sevenDayStart = try #require(Self.calendar.date(byAdding: .day, value: -6, to: anchor))
        let thirtyDayStart = try #require(Self.calendar.date(byAdding: .day, value: -29, to: anchor))
        let end = try #require(Self.calendar.date(byAdding: .day, value: 1, to: anchor))

        #expect(sevenDays.dailyPoints.map(\.day) == [anchor])
        #expect(thirtyDays.dailyPoints.map(\.day) == [anchor])
        #expect(sevenDays.chartDomain == sevenDayStart...end)
        #expect(thirtyDays.chartDomain == thirtyDayStart...end)
    }

    @Test
    func `currency coverage intersects disjoint provider windows`() throws {
        let earlier = try SpendDashboardModel.ProviderInput(
            id: "earlier",
            provider: .claude,
            displayName: "Earlier",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [Self.entry(day: "2026-07-09", cost: 2)],
                historyDays: 7,
                updatedAt: #require(Self.calendar.date(byAdding: .day, value: -7, to: Self.now))))
        let later = SpendDashboardModel.ProviderInput(
            id: "later",
            provider: .codex,
            displayName: "Later",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [Self.entry(day: "2026-07-16", cost: 3)],
                historyDays: 7))
        let group = try #require(SpendDashboardModel.build(
            inputs: [earlier, later],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.coveredDayCount == 0)
        #expect(group.providers.allSatisfy { $0.coveredDayCount == 7 })
        #expect(group.totalCost == 5)
        #expect(group.providers.map(\.id) == ["later", "earlier"])
        #expect(group.dailyPoints.map(\.sourceID) == ["earlier", "later"])
    }

    @Test
    func `currency coverage counts only overlapping provider days`() throws {
        let earlier = try SpendDashboardModel.ProviderInput(
            id: "earlier",
            provider: .claude,
            displayName: "Earlier",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [Self.entry(day: "2026-07-12", cost: 2)],
                historyDays: 7,
                updatedAt: #require(Self.calendar.date(byAdding: .day, value: -4, to: Self.now))))
        let later = SpendDashboardModel.ProviderInput(
            id: "later",
            provider: .codex,
            displayName: "Later",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [Self.entry(day: "2026-07-16", cost: 3)],
                historyDays: 7))
        let group = try #require(SpendDashboardModel.build(
            inputs: [earlier, later],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.coveredDayCount == 3)
        #expect(group.providers.allSatisfy { $0.coveredDayCount == 7 })
        #expect(group.totalCost == 5)
    }

    @Test
    func `uncovered same currency source keeps complete model rows without ranking them as complete`() throws {
        let covered = Self.input(id: "covered", provider: .claude, currency: "USD", cost: 4)
        let uncovered = SpendDashboardModel.ProviderInput(
            id: "uncovered",
            provider: .codex,
            displayName: "Uncovered",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [Self.entry(day: "2026-08-01", cost: 10)],
                historyDays: 1,
                updatedAt: Date(timeIntervalSince1970: 1_785_542_400))) // 2026-08-01 00:00:00 UTC
        let group = try #require(SpendDashboardModel.build(
            inputs: [covered, uncovered],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.totalCost == 4)
        #expect(group.totalTokens == 10)
        #expect(group.hasPartialCost)
        #expect(group.hasPartialTokens)
        #expect(group.pricedProviderCount == 1)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.map(\.provider) == [.claude])
        #expect(group.models.map(\.modelName) == ["test-model"])
        #expect(group.models.map(\.totalCost) == [4])
        #expect(spendDashboardModelHistoryPresentation(group) == .partial)
        CodexBarLocalizationOverride.$appLanguage.withValue("en") {
            #expect(spendDashboardGroupTokenText(group).hasPrefix("~"))
            #expect(spendDashboardHistoryCaption(group, requestedDays: 7).contains("Partial estimate"))
        }
    }

    @Test
    func `only uncovered source reports model breakdown unavailable`() throws {
        let uncovered = SpendDashboardModel.ProviderInput(
            provider: .claude,
            displayName: "Claude",
            snapshot: Self.snapshot(
                currency: "USD",
                entries: [Self.entry(day: "2026-08-01", cost: 10)],
                historyDays: 1,
                updatedAt: Date(timeIntervalSince1970: 1_785_542_400))) // 2026-08-01 00:00:00 UTC
        let group = try #require(SpendDashboardModel.build(
            inputs: [uncovered],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.coveredDayCount == 0)
        #expect(group.totalCost == nil)
        #expect(group.totalTokens == nil)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.isEmpty)
        #expect(spendDashboardModelHistoryPresentation(group) == .unavailable)
    }

    @Test
    func `uncovered source affects only its own currency model history`() throws {
        let covered = Self.input(id: "covered", provider: .claude, currency: "USD", cost: 4)
        let uncovered = SpendDashboardModel.ProviderInput(
            id: "uncovered",
            provider: .codex,
            displayName: "Uncovered",
            snapshot: Self.snapshot(
                currency: "EUR",
                entries: [Self.entry(day: "2026-08-01", cost: 10)],
                historyDays: 1,
                updatedAt: Date(timeIntervalSince1970: 1_785_542_400))) // 2026-08-01 00:00:00 UTC
        let groups = SpendDashboardModel.build(
            inputs: [covered, uncovered],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups
        let eur = try #require(groups.first(where: { $0.currencyCode == "EUR" }))
        let usd = try #require(groups.first(where: { $0.currencyCode == "USD" }))

        #expect(eur.modelHistoryCompleteness == .incomplete)
        #expect(eur.models.isEmpty)
        #expect(usd.modelHistoryCompleteness == .complete)
        #expect(usd.models.map(\.totalCost) == [4])
    }

    @Test
    func `ISO history stays Gregorian while preserving the injected timezone`() throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: 7 * 60 * 60))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = timeZone
        let now = try #require(gregorian.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 16,
            hour: 12)))
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = timeZone
        let snapshot = Self.snapshot(
            currency: "USD",
            entries: [Self.entry(day: "2026-07-16", cost: 4)],
            updatedAt: now)
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: now,
            calendar: buddhist).groups.first)

        #expect(group.totalCost == 4)
        #expect(group.coveredDayCount == 7)
        #expect(group.dailyPoints.map(\.day) == [gregorian.startOfDay(for: now)])
    }

    @Test
    func `daily values aggregate once and produce deterministic nonoverlapping stacks`() throws {
        let first = SpendDashboardModel.ProviderInput(
            id: "a",
            provider: .claude,
            displayName: "Claude",
            snapshot: Self.snapshot(currency: "USD", entries: [
                Self.entry(day: "2026-07-16", cost: 2),
                Self.entry(day: "2026-07-16", cost: 3),
            ]))
        let second = SpendDashboardModel.ProviderInput(
            id: "b",
            provider: .codex,
            displayName: "Codex",
            snapshot: Self.snapshot(currency: "USD", entries: [Self.entry(day: "2026-07-16", cost: 4)]))
        let group = try #require(SpendDashboardModel.build(
            inputs: [second, first],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.dailyPoints.map(\.sourceID) == ["a", "b"])
        #expect(group.dailyPoints.map(\.cost) == [5, 4])
        #expect(group.dailyPoints.map(\.stackStart) == [0, 5])
        #expect(group.dailyPoints.map(\.stackEnd) == [5, 9])
    }
}

extension SpendDashboardModelTests {
    /// Shared fixture helpers for dashboard model tests.
    static func input(
        id: String,
        provider: UsageProvider,
        currency: String,
        cost: Double) -> SpendDashboardModel.ProviderInput
    {
        SpendDashboardModel.ProviderInput(
            id: id,
            provider: provider,
            displayName: provider.rawValue,
            snapshot: self.snapshot(currency: currency, entries: [self.entry(day: "2026-07-16", cost: cost)]))
    }

    static func snapshot(
        currency: String,
        entries: [CostUsageDailyReport.Entry],
        historyDays: Int = 30,
        projects: [CostUsageProjectBreakdown] = [],
        updatedAt: Date = now) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            currencyCode: currency,
            historyDays: historyDays,
            daily: entries,
            projects: projects,
            updatedAt: updatedAt)
    }

    static func entry(
        day: String,
        cost: Double?,
        tokens: Int? = 10,
        model: String? = "test-model") -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: model.map {
                [.init(modelName: $0, costUSD: cost, totalTokens: tokens)]
            })
    }

    static func entryWithBreakdowns(
        day: String,
        totalCost: Double = 0,
        totalTokens: Int = 0,
        breakdowns: [CostUsageDailyReport.ModelBreakdown]) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: totalTokens,
            costUSD: totalCost,
            modelsUsed: nil,
            modelBreakdowns: breakdowns)
    }

    static let now = Date(timeIntervalSince1970: 1_784_179_200) // 2026-07-16 00:00:00 UTC
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
