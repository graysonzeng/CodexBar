import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `overview CodexRadar card sits between spend and provider rows`() throws {
        let (controller, menu) = try self.makeOverviewCodexRadarMenu(
            includeSpend: true,
            includeProviderRows: true,
            snapshot: Self.codexRadarSnapshot())
        defer { controller.releaseStatusItemsForTesting() }

        let ids = menu.items.compactMap { $0.representedObject as? String }
        let spendIndex = try #require(ids.firstIndex(of: "overviewSpendSummary"))
        let radarIndex = try #require(ids.firstIndex(of: "overviewCodexRadar"))
        let firstRowIndex = try #require(ids.firstIndex { $0.hasPrefix("overviewRow-") })
        #expect(spendIndex < radarIndex)
        #expect(radarIndex < firstRowIndex)
        #expect(ids.count(where: { $0 == "overviewCodexRadar" }) == 1)
        #expect(!ids.contains("overviewEmptyState"))

        let radarItem = try #require(menu.items.first { ($0.representedObject as? String) == "overviewCodexRadar" })
        #expect(radarItem.submenu == nil)
        #expect(radarItem.action == nil)
        #expect(!(radarItem.representedObject as? String ?? "").hasPrefix("overviewRow-"))
    }

    @Test
    func `overview CodexRadar card still shows when provider rows are empty`() throws {
        let (controller, menu) = try self.makeOverviewCodexRadarMenu(
            includeSpend: false,
            includeProviderRows: false,
            snapshot: Self.codexRadarSnapshot())
        defer { controller.releaseStatusItemsForTesting() }

        let ids = menu.items.compactMap { $0.representedObject as? String }
        #expect(ids.contains("overviewCodexRadar"))
        #expect(!ids.contains(where: { $0.hasPrefix("overviewRow-") }))
        #expect(!ids.contains("overviewEmptyState"))
        #expect(!menu.items.contains { $0.title == "No overview data available." })
        #expect(!menu.items.contains { $0.title == "No providers selected for Overview." })
    }

    @Test
    func `nil CodexRadar snapshot keeps existing overview empty state`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.mergedMenuLastSelectedWasOverview = true
        settings.costUsageEnabled = false
        self.enableOverviewProviders(settings, providers: [.codex, .claude])

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store.codexRadarSnapshot = nil
        store._setSnapshotForTesting(nil, provider: .codex)
        store._setSnapshotForTesting(nil, provider: .claude)
        store._setErrorForTesting("failed", provider: .codex)
        store._setErrorForTesting("failed", provider: .claude)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        let ids = menu.items.compactMap { $0.representedObject as? String }
        #expect(!ids.contains("overviewCodexRadar"))
        #expect(ids.contains("overviewEmptyState") || menu.items.contains { $0.title == "No overview data available." })
    }

    @Test
    func `visible fingerprint not raw revision drives adjunct readiness`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.mergedMenuLastSelectedWasOverview = true
        self.enableOverviewProviders(settings, providers: [.codex, .claude])
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store.codexRadarSnapshot = Self.codexRadarSnapshot(minutes: 19.82)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let baseline = controller.menuAdjunctReadinessSignature()
        store.codexRadarRevision += 1
        #expect(controller.menuAdjunctReadinessSignature() == baseline)

        store.codexRadarSnapshot = Self.codexRadarSnapshot(minutes: 19.81)
        #expect(controller.menuAdjunctReadinessSignature() == baseline)

        store.codexRadarSnapshot = Self.codexRadarSnapshot(minutes: 19.4)
        #expect(controller.menuAdjunctReadinessSignature() != baseline)
    }

    @Test
    func `HTTP fixture reaches the Overview card through the store`() async {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer { self.disableMenuCardsForTesting() }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.mergedMenuLastSelectedWasOverview = true
        settings.costUsageEnabled = false
        self.enableOverviewProviders(settings, providers: [.codex, .claude])

        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            #expect(request.httpMethod == "GET")
            #expect(url == CodexRadarIntelligence.endpointURL)
            return Self.codexRadarHTTPResponse(url: url)
        }
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._test_codexRadarTransportOverride = transport
        await store.refreshCodexRadarIntelligence(force: true, now: Date())
        #expect(store.codexRadarSnapshot != nil)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        let ids = menu.items.compactMap { $0.representedObject as? String }
        #expect(ids.contains("overviewCodexRadar"))
        let requests = await transport.requests()
        #expect(!requests.isEmpty)
    }

    @Test
    func `warmup does not fetch CodexRadar intelligence`() async {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer { self.disableMenuCardsForTesting() }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.mergedMenuLastSelectedWasOverview = false
        self.enableOverviewProviders(settings, providers: [.codex, .claude])

        let transport = ProviderHTTPTransportStub { request in
            Issue.record("warmup must not fetch \(request.url?.absoluteString ?? "")")
            throw URLError(.notConnectedToInternet)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        store._test_codexRadarTransportOverride = transport
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        controller.warmMergedSwitcherSiblingContent(in: menu)
        let requests = await transport.requests()
        #expect(requests.isEmpty)
        #expect(store.codexRadarSnapshot == nil)
        controller.menuDidClose(menu)
    }

    private func makeOverviewCodexRadarMenu(
        includeSpend: Bool,
        includeProviderRows: Bool,
        snapshot: CodexRadarIntelligenceSnapshot?) throws -> (StatusItemController, NSMenu)
    {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = true
        settings.costUsageEnabled = includeSpend
        settings.costSummaryDisplayStyle = .both
        self.enableOverviewProviders(settings, providers: [.codex, .claude])

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store.codexRadarSnapshot = snapshot
        if !includeProviderRows {
            store._setSnapshotForTesting(nil, provider: .codex)
            store._setSnapshotForTesting(nil, provider: .claude)
            store._setErrorForTesting("failed", provider: .codex)
            store._setErrorForTesting("failed", provider: .claude)
        }
        if includeSpend {
            let now = Date()
            let components = Calendar.current.dateComponents([.year, .month, .day], from: now)
            let year = try #require(components.year)
            let month = try #require(components.month)
            let dayOfMonth = try #require(components.day)
            let day = String(format: "%04d-%02d-%02d", year, month, dayOfMonth)
            store._setTokenSnapshotForTesting(
                CostUsageTokenSnapshot(
                    sessionTokens: 100,
                    sessionCostUSD: 1,
                    last30DaysTokens: 100,
                    last30DaysCostUSD: 1,
                    costProvenance: .listPriceEstimate,
                    daily: [
                        CostUsageDailyReport.Entry(
                            date: day,
                            inputTokens: 60,
                            outputTokens: 40,
                            totalTokens: 100,
                            requestCount: 1,
                            costUSD: 1,
                            modelsUsed: ["test-model"],
                            modelBreakdowns: nil),
                    ],
                    updatedAt: now),
                provider: .codex)
        }

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        return (controller, menu)
    }

    private func enableOverviewProviders(_ settings: SettingsStore, providers: Set<UsageProvider>) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: providers.contains(provider))
        }
    }

    private static func codexRadarSnapshot(minutes: Double = 19.82) -> CodexRadarIntelligenceSnapshot {
        CodexRadarIntelligenceSnapshot(
            points: CodexRadarIntelligenceTarget.allCases.map { target in
                CodexRadarIntelligencePoint(target: target, iq: 98.21, averageMinutes: minutes)
            })
    }

    private nonisolated static func codexRadarHTTPResponse(url: URL) -> (Data, URLResponse) {
        let body = """
        {
          "schema": 3,
          "mode": "equal_latest_3",
          "benchmark_id": "deep-swe",
          "points": [
            {"model": "gpt-5.6-sol", "effort": "xhigh", "iq": 100.45, "average_minutes": 24.37},
            {"model": "gpt-5.6-sol", "effort": "high", "iq": 98.21, "average_minutes": 19.82},
            {"model": "gpt-5.6-sol", "effort": "medium", "iq": 93.3, "average_minutes": 16.16},
            {"model": "deepseek-v4-flash", "effort": "max", "iq": 86.16, "average_minutes": 31.39},
            {"model": "deepseek-v4-pro", "effort": "max", "iq": 87.1, "average_minutes": 42.41}
          ]
        }
        """
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }
}
