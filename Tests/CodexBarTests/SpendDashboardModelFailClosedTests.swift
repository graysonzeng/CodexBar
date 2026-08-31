import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

extension SpendDashboardModelTests {
    @Test
    func `invalid costs and arithmetic overflow never become spend`() throws {
        let invalid = SpendDashboardModel.ProviderInput(
            id: "invalid",
            provider: .claude,
            displayName: "Claude",
            snapshot: Self.snapshot(currency: "USD", entries: [
                Self.entry(day: "2026-07-16", cost: -.infinity, tokens: .max),
                Self.entry(day: "2026-07-15", cost: -.nan, tokens: .max),
                Self.entry(day: "2026-07-14", cost: -1),
                Self.entry(day: "2026-06-31", cost: 99),
            ]))
        let hugeA = Self.input(id: "huge-a", provider: .codex, currency: "USD", cost: .greatestFiniteMagnitude)
        let hugeB = Self.input(id: "huge-b", provider: .openai, currency: "USD", cost: .greatestFiniteMagnitude)
        let group = try #require(SpendDashboardModel.build(
            inputs: [invalid, hugeA, hugeB],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.providers.first(where: { $0.id == "invalid" })?.totalCost == nil)
        #expect(group.totalCost == nil)
        #expect(group.totalTokens == 20)
        #expect(group.hasPartialTokens)
        #expect(group.dailyPoints.isEmpty)
    }

    @Test
    func `malformed date mixed with valid usage fails the source closed`() throws {
        let snapshot = Self.snapshot(currency: "USD", entries: [
            Self.entry(day: "2026-07-16", cost: 4, tokens: 40),
            Self.entry(day: "not-a-day", cost: 2, tokens: 20),
        ])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.providers.first?.totalCost == nil)
        #expect(group.providers.first?.totalTokens == nil)
        #expect(group.totalCost == nil)
        #expect(group.totalTokens == nil)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.isEmpty)
        #expect(group.dailyPoints.isEmpty)
    }

    @Test
    func `malformed date only with unknown usage is unavailable not zero`() throws {
        let snapshot = Self.snapshot(currency: "USD", entries: [
            Self.entry(day: "2026-02-30", cost: nil, tokens: nil, model: nil),
        ])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.providers.first?.totalCost == nil)
        #expect(group.providers.first?.totalTokens == nil)
        #expect(group.totalCost == nil)
        #expect(group.totalTokens == nil)
        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.isEmpty)
        #expect(group.dailyPoints.isEmpty)
    }

    @Test
    func `explicit zero malformed date is ignored without affecting valid window rows`() throws {
        let snapshot = Self.snapshot(currency: "USD", entries: [
            Self.entry(day: "malformed", cost: 0, tokens: 0, model: nil),
            Self.entryWithBreakdowns(
                day: "also-malformed",
                totalCost: 0,
                totalTokens: 0,
                breakdowns: [.init(modelName: "zero", costUSD: 0, totalTokens: 0, requestCount: 0)]),
            Self.entry(day: "2026-07-16", cost: 3, tokens: 30),
            Self.entry(day: "2026-07-01", cost: 99, tokens: 990),
        ])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.providers.first?.totalCost == 3)
        #expect(group.providers.first?.totalTokens == 30)
        #expect(group.totalCost == 3)
        #expect(group.totalTokens == 30)
        #expect(group.modelHistoryCompleteness == .complete)
        #expect(group.models.map(\.totalCost) == [3])
        #expect(group.dailyPoints.map(\.cost) == [3])
    }

    @Test
    func `mixed invalid entry metrics make source and group totals unavailable`() throws {
        let inputs = [
            SpendDashboardModel.ProviderInput(
                id: "missing",
                provider: .claude,
                displayName: "Missing",
                snapshot: Self.snapshot(currency: "USD", entries: [
                    Self.entry(day: "2026-07-16", cost: 1, tokens: 1),
                    Self.entry(day: "2026-07-15", cost: nil, tokens: nil),
                ])),
            SpendDashboardModel.ProviderInput(
                id: "negative",
                provider: .codex,
                displayName: "Negative",
                snapshot: Self.snapshot(currency: "USD", entries: [
                    Self.entry(day: "2026-07-16", cost: 1, tokens: 1),
                    Self.entry(day: "2026-07-15", cost: -1, tokens: -1),
                ])),
            SpendDashboardModel.ProviderInput(
                id: "nonfinite",
                provider: .openai,
                displayName: "Nonfinite",
                snapshot: Self.snapshot(currency: "USD", entries: [
                    Self.entry(day: "2026-07-16", cost: 1, tokens: 1),
                    Self.entry(day: "2026-07-15", cost: .infinity, tokens: 1),
                ])),
            SpendDashboardModel.ProviderInput(
                id: "overflow",
                provider: .mistral,
                displayName: "Overflow",
                snapshot: Self.snapshot(currency: "USD", entries: [
                    Self.entry(day: "2026-07-16", cost: .greatestFiniteMagnitude, tokens: .max),
                    Self.entry(day: "2026-07-15", cost: .greatestFiniteMagnitude, tokens: .max),
                ])),
        ]
        let group = try #require(SpendDashboardModel.build(
            inputs: inputs,
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.providers.allSatisfy { $0.totalCost == nil })
        #expect(group.providers.first(where: { $0.id == "nonfinite" })?.totalTokens == 2)
        #expect(group.providers.filter { $0.id != "nonfinite" }.allSatisfy { $0.totalTokens == nil })
        #expect(group.totalCost == nil)
        #expect(group.totalTokens == 2)
        #expect(group.hasPartialTokens)
    }

    @Test
    func `invalid model breakdowns make model history unavailable`() throws {
        let snapshot = Self.snapshot(currency: "USD", entries: [
            Self.entryWithBreakdowns(
                day: "2026-07-16",
                breakdowns: [
                    .init(modelName: "complete", costUSD: 2, totalTokens: 2),
                    .init(modelName: "missing", costUSD: 4, totalTokens: 4),
                    .init(modelName: "negative", costUSD: 4, totalTokens: 4),
                    .init(modelName: "overflow", costUSD: .greatestFiniteMagnitude, totalTokens: .max),
                ]),
            Self.entryWithBreakdowns(
                day: "2026-07-15",
                breakdowns: [
                    .init(modelName: "complete", costUSD: 1, totalTokens: 1),
                    .init(modelName: "missing", costUSD: nil, totalTokens: nil),
                    .init(modelName: "negative", costUSD: -1, totalTokens: -1),
                    .init(modelName: "overflow", costUSD: .greatestFiniteMagnitude, totalTokens: .max),
                ]),
        ])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.isEmpty)
    }

    @Test
    func `partial contributing model history is unavailable instead of a lower bound`() throws {
        let snapshot = Self.snapshot(currency: "USD", entries: [
            Self.entry(day: "2026-07-16", cost: 4, tokens: 40, model: nil),
            Self.entry(day: "2026-07-15", cost: 2, tokens: 20),
        ])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.isEmpty)
        #expect(group.totalCost == 6)
    }

    @Test
    func `zero usage without a breakdown keeps model history complete`() throws {
        let snapshot = Self.snapshot(currency: "USD", entries: [
            Self.entryWithBreakdowns(day: "2026-07-16", breakdowns: []),
            Self.entry(day: "2026-07-15", cost: 2, tokens: 20),
        ])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.modelHistoryCompleteness == .complete)
        #expect(group.models.map(\.modelName) == ["test-model"])
        #expect(group.models.map(\.totalCost) == [2])
    }

    @Test
    func `unknown usage without a breakdown makes model history unavailable`() throws {
        let snapshot = Self.snapshot(currency: "USD", entries: [
            Self.entry(day: "2026-07-16", cost: nil, tokens: nil, model: nil),
            Self.entry(day: "2026-07-15", cost: 2, tokens: 20),
        ])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.isEmpty)
    }

    @Test
    func `blank model names fail closed unless their usage is explicitly zero`() throws {
        let incomplete = Self.snapshot(currency: "USD", entries: [Self.entryWithBreakdowns(
            day: "2026-07-16",
            totalCost: 3,
            totalTokens: 30,
            breakdowns: [
                .init(modelName: " \n ", costUSD: 2, totalTokens: 20),
                .init(modelName: "named", costUSD: 1, totalTokens: 10),
            ])])
        let complete = Self.snapshot(currency: "USD", entries: [Self.entryWithBreakdowns(
            day: "2026-07-16",
            totalCost: 1,
            totalTokens: 10,
            breakdowns: [
                .init(modelName: " \n ", costUSD: 0, totalTokens: 0),
                .init(modelName: "named", costUSD: 1, totalTokens: 10),
            ])])
        let incompleteGroup = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: incomplete)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)
        let completeGroup = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: complete)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(incompleteGroup.modelHistoryCompleteness == .incomplete)
        #expect(incompleteGroup.models.isEmpty)
        #expect(completeGroup.modelHistoryCompleteness == .complete)
        #expect(completeGroup.models.map(\.modelName) == ["named"])
    }

    @Test
    func `partial named breakdown totals make model history unavailable`() throws {
        let snapshot = Self.snapshot(currency: "USD", entries: [Self.entryWithBreakdowns(
            day: "2026-07-16",
            totalCost: 10,
            totalTokens: 100,
            breakdowns: [.init(modelName: "partial", costUSD: 4, totalTokens: 40)])])
        let group = try #require(SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.modelHistoryCompleteness == .incomplete)
        #expect(group.models.isEmpty)
    }

    @Test
    func `incomplete duplicate day sources do not render partial chart stacks`() throws {
        let missing = SpendDashboardModel.ProviderInput(
            id: "missing",
            provider: .claude,
            displayName: "Missing",
            snapshot: Self.snapshot(currency: "USD", entries: [
                Self.entry(day: "2026-07-16", cost: 2),
                Self.entry(day: "2026-07-16", cost: nil),
            ]))
        let overflow = SpendDashboardModel.ProviderInput(
            id: "overflow",
            provider: .codex,
            displayName: "Overflow",
            snapshot: Self.snapshot(currency: "USD", entries: [
                Self.entry(day: "2026-07-16", cost: .greatestFiniteMagnitude),
                Self.entry(day: "2026-07-16", cost: .greatestFiniteMagnitude),
            ]))
        let complete = Self.input(id: "complete", provider: .openai, currency: "USD", cost: 3)
        let group = try #require(SpendDashboardModel.build(
            inputs: [missing, overflow, complete],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        #expect(group.dailyPoints.map(\.sourceID) == ["complete"])
        #expect(group.dailyPoints.map(\.cost) == [3])
        #expect(group.dailyPoints.map(\.stackStart) == [0])
        #expect(group.dailyPoints.map(\.stackEnd) == [3])
    }

    @Test
    func `covered inactive sources contribute zero without hiding active totals`() throws {
        let inactive = SpendDashboardModel.ProviderInput(
            id: "inactive",
            provider: .claude,
            displayName: "Inactive",
            snapshot: Self.snapshot(currency: "USD", entries: [
                Self.entry(day: "2026-07-16", cost: 0, tokens: 0, model: nil),
            ]))
        let active = Self.input(id: "active", provider: .codex, currency: "USD", cost: 10)
        let group = try #require(SpendDashboardModel.build(
            inputs: [inactive, active],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar).groups.first)

        let inactiveRow = try #require(group.providers.first(where: { $0.id == "inactive" }))
        #expect(inactiveRow.totalCost == 0)
        #expect(inactiveRow.totalTokens == 0)
        #expect(inactiveRow.coveredDayCount == 7)
        #expect(group.totalCost == 10)
        #expect(group.totalTokens == 10)
        #expect(group.providers.map(\.id) == ["active", "inactive"])
        #expect(group.modelHistoryCompleteness == .complete)
        #expect(group.models.map(\.totalCost) == [10])
    }

    @Test
    func `unpriced history keeps spend unavailable and lists named models`() throws {
        let snapshot = Self.snapshot(
            currency: "CAD",
            entries: [Self.entry(day: "2026-07-16", cost: nil, tokens: 12)])
        let model = SpendDashboardModel.build(
            inputs: [.init(provider: .claude, displayName: "Claude", snapshot: snapshot)],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar)
        let group = try #require(model.groups.first)

        #expect(group.totalCost == nil)
        #expect(group.totalTokens == 12)
        #expect(group.providers.first?.totalCost == nil)
        #expect(group.models.map(\.modelName) == ["test-model"])
        #expect(group.models.map(\.totalCost) == [nil])
        #expect(spendDashboardModelHistoryPresentation(group) == .partial)
    }

    @Test
    func `Codex requests freeze source home auth and cache identity`() throws {
        let id = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpendDashboardModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let account = CodexVisibleAccount(
            id: "account",
            email: "test@example.com",
            authFingerprint: "ABC123",
            storedAccountID: id,
            selectionSource: .managedAccount(id: id),
            isActive: true,
            isLive: false,
            canReauthenticate: true,
            canRemove: true)
        let request = try #require(SpendDashboardSource.codexRequest(
            account: account,
            homePath: home.path,
            providerName: "Codex",
            index: 1,
            count: 2))

        #expect(request.source == .managedAccount(id: id))
        #expect(request.homePath == home.path)
        #expect(request.authFingerprint == "abc123")
        #expect(!request.authFileWasReadable)
        #expect(request.displayName == "Codex · #2")
        #expect(request.cacheIdentity.count == 64)
        #expect(SpendDashboardSource.scanDays == SpendDashboardSource.activityDays)
        #expect(SpendDashboardSource.scanDays == 365)
        #expect(SpendDashboardSource.codexRequest(
            account: account,
            homePath: "relative/path",
            providerName: "Codex",
            index: 0,
            count: 1) == nil)
        #expect(SpendDashboardSource.codexRequest(
            account: account,
            homePath: home.appendingPathComponent("missing", isDirectory: true).path,
            providerName: "Codex",
            index: 0,
            count: 1) == nil)

        let changed = CodexVisibleAccount(
            id: account.id,
            email: account.email,
            authFingerprint: "different",
            storedAccountID: id,
            selectionSource: account.selectionSource,
            isActive: account.isActive,
            isLive: account.isLive,
            canReauthenticate: account.canReauthenticate,
            canRemove: account.canRemove)
        let changedRequest = try #require(SpendDashboardSource.codexRequest(
            account: changed,
            homePath: request.homePath,
            providerName: "Codex",
            index: 1,
            count: 2))
        #expect(changedRequest.cacheIdentity != request.cacheIdentity)
        let rebucketedRequest = try #require(SpendDashboardSource.codexRequest(
            account: account,
            homePath: request.homePath,
            providerName: "Codex",
            index: 1,
            count: 2,
            bucketTimeZoneIdentifier: "Pacific/Kiritimati"))
        #expect(rebucketedRequest.cacheIdentity != request.cacheIdentity)

        let authData = Data("{\"tokens\":\"synthetic\"}".utf8)
        try authData.write(to: CodexAuthFingerprint.authFileURL(homePath: home.path))
        let exact = try #require(SpendDashboardSource.codexRequest(
            account: account,
            homePath: home.path,
            providerName: "Codex",
            index: 0,
            count: 1))
        #expect(exact.authFingerprint == CodexAuthFingerprint.fingerprint(data: authData))
        #expect(exact.authFileWasReadable)
        #expect(exact.cacheIdentity != request.cacheIdentity)
    }
}
