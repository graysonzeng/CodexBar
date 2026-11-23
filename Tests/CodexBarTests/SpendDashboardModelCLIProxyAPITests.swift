import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension SpendDashboardModelTests {
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
            let trendChart = SpendTrendChartModel(group: group, section: .daily, day: nil)
            #expect(trendChart.total == 50)
            #expect(!trendChart.buckets.isEmpty)
        }
    }
}
