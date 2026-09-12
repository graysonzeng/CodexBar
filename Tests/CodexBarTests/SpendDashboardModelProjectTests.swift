import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

extension SpendDashboardModelTests {
    @Test
    func `project rows aggregate windowed entries and rank by cost`() throws {
        let model = SpendDashboardModel.build(
            inputs: [
                SpendDashboardModel.ProviderInput(
                    id: "codex-a",
                    provider: .codex,
                    displayName: "Codex",
                    snapshot: CostUsageTokenSnapshot(
                        sessionTokens: nil,
                        sessionCostUSD: nil,
                        last30DaysTokens: nil,
                        last30DaysCostUSD: nil,
                        currencyCode: "USD",
                        historyDays: 30,
                        daily: [
                            Self.entry(day: "2026-07-15", cost: 30),
                            Self.entry(day: "2026-07-16", cost: 10),
                        ],
                        projects: [
                            Self.project(name: "alpha", days: [
                                ("2026-07-15", 20),
                                ("2026-07-16", 5),
                            ]),
                            Self.project(name: "beta", days: [
                                ("2026-07-16", 10),
                            ]),
                        ],
                        updatedAt: Self.now)),
            ],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)

        let group = try #require(model.groups.first)
        #expect(group.projects.count == 2)
        #expect(group.projects[0].projectName == "alpha")
        #expect(group.projects[0].rank == 1)
        #expect(group.projects[0].totalCost == 25)
        #expect(group.projects[0].totalTokens == 20)
        #expect(group.projects[0].path == "/tmp/alpha")
        #expect(group.projects[1].projectName == "beta")
        #expect(group.projects[1].rank == 2)
        #expect(group.projects[1].totalCost == 10)
        #expect(group.projects[1].totalTokens == 10)
    }

    @Test
    func `project rows exclude days outside the requested window`() throws {
        let model = SpendDashboardModel.build(
            inputs: [
                SpendDashboardModel.ProviderInput(
                    id: "codex-a",
                    provider: .codex,
                    displayName: "Codex",
                    snapshot: CostUsageTokenSnapshot(
                        sessionTokens: nil,
                        sessionCostUSD: nil,
                        last30DaysTokens: nil,
                        last30DaysCostUSD: nil,
                        currencyCode: "USD",
                        historyDays: 30,
                        daily: [Self.entry(day: "2026-07-15", cost: 3)],
                        projects: [
                            Self.project(name: "alpha", days: [
                                ("2026-07-01", 100),
                                ("2026-07-15", 3),
                            ]),
                        ],
                        updatedAt: Self.now)),
            ],
            requestedDays: 7,
            now: Self.now,
            calendar: Self.calendar)

        let group = try #require(model.groups.first)
        #expect(group.projects.count == 1)
        #expect(group.projects[0].totalCost == 3)
        #expect(group.projects[0].totalTokens == 10)
    }

    @Test
    func `project rows stay attributed per source`() throws {
        let model = SpendDashboardModel.build(
            inputs: [
                SpendDashboardModel.ProviderInput(
                    id: "codex-a",
                    provider: .codex,
                    displayName: "Codex · #1",
                    snapshot: Self.snapshot(
                        currency: "USD",
                        entries: [Self.entry(day: "2026-07-15", cost: 5)],
                        projects: [Self.project(name: "shared", days: [("2026-07-15", 5)])])),
                SpendDashboardModel.ProviderInput(
                    id: "codex-b",
                    provider: .codex,
                    displayName: "Codex · #2",
                    snapshot: Self.snapshot(
                        currency: "USD",
                        entries: [Self.entry(day: "2026-07-15", cost: 7)],
                        projects: [Self.project(name: "shared", days: [("2026-07-15", 7)])])),
            ],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)

        let group = try #require(model.groups.first)
        #expect(group.projects.count == 2)
        #expect(group.projects.map(\.totalCost) == [7, 5])
        #expect(Set(group.projects.map(\.id)) == ["codex-a:shared", "codex-b:shared"])
        #expect(group.projects[0].providerName == "Codex · #2")
    }

    @Test
    func `project rows drop projects without attributable window days`() throws {
        let model = SpendDashboardModel.build(
            inputs: [
                SpendDashboardModel.ProviderInput(
                    id: "codex-a",
                    provider: .codex,
                    displayName: "Codex",
                    snapshot: CostUsageTokenSnapshot(
                        sessionTokens: nil,
                        sessionCostUSD: nil,
                        last30DaysTokens: nil,
                        last30DaysCostUSD: nil,
                        currencyCode: "USD",
                        historyDays: 30,
                        daily: [Self.entry(day: "2026-07-15", cost: 1)],
                        projects: [
                            Self.project(name: "stale", days: [("2026-05-01", 50)]),
                        ],
                        updatedAt: Self.now)),
            ],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)

        let group = try #require(model.groups.first)
        #expect(group.projects.isEmpty)
    }

    @Test
    func `project rows report unknown aggregates as nil but keep known ones`() throws {
        let model = SpendDashboardModel.build(
            inputs: [
                SpendDashboardModel.ProviderInput(
                    id: "codex-a",
                    provider: .codex,
                    displayName: "Codex",
                    snapshot: CostUsageTokenSnapshot(
                        sessionTokens: nil,
                        sessionCostUSD: nil,
                        last30DaysTokens: nil,
                        last30DaysCostUSD: nil,
                        currencyCode: "USD",
                        historyDays: 30,
                        daily: [Self.entry(day: "2026-07-15", cost: 9)],
                        projects: [
                            Self.project(name: "unknown-cost", days: [
                                ("2026-07-15", 4),
                                ("2026-07-16", nil),
                            ]),
                            Self.project(
                                name: "unknown-tokens",
                                days: [("2026-07-15", 4)],
                                tokens: nil),
                        ],
                        updatedAt: Self.now)),
            ],
            requestedDays: 30,
            now: Self.now,
            calendar: Self.calendar)

        let group = try #require(model.groups.first)
        #expect(group.projects.count == 2)
        let unknownCost = try #require(group.projects.first { $0.projectName == "unknown-cost" })
        #expect(unknownCost.totalCost == nil)
        #expect(unknownCost.totalTokens == 20)
        let unknownTokens = try #require(group.projects.first { $0.projectName == "unknown-tokens" })
        #expect(unknownTokens.totalCost == 4)
        #expect(unknownTokens.totalTokens == nil)
    }

    private static func project(
        name: String,
        days: [(String, Double?)],
        tokens: Int? = 10) -> CostUsageProjectBreakdown
    {
        CostUsageProjectBreakdown(
            name: name,
            path: "/tmp/\(name)",
            totalTokens: nil,
            totalCostUSD: nil,
            daily: days.map { day, cost in
                CostUsageDailyReport.Entry(
                    date: day,
                    inputTokens: nil,
                    outputTokens: nil,
                    totalTokens: tokens,
                    costUSD: cost,
                    modelsUsed: nil,
                    modelBreakdowns: nil)
            },
            modelBreakdowns: nil)
    }
}
