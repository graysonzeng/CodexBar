import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct CLIProxyAPICollectionFailurePublicationTests {
    @Test
    func `collection failure survives successful and failed read only refreshes`() async throws {
        let (store, _) = Self.makeStore()
        let failure = try Self.failure()
        let snapshot = Self.snapshot(fingerprint: failure.fingerprint)
        store.noteCLIProxyAPICollectionFailure(failure, for: .cliproxyapi)
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, _, _ in snapshot }

        await store.refreshTokenUsage(.cliproxyapi, force: true)
        await store.refreshSpendDashboardTokenUsageNow(for: .cliproxyapi, force: true)
        #expect(store.tokenError(for: .cliproxyapi) == failure.error.errorDescription)
        #expect(store.tokenSnapshot(for: .cliproxyapi)?.sessionCostUSD == 1)
        #expect(store.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: .cliproxyapi)?
            .snapshot?.historyLabel == failure.error.errorDescription)

        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, _, _ in
            throw CLIProxyAPISpendError.storeUnreadable
        }
        await store.refreshTokenUsage(.cliproxyapi, force: true)
        await store.refreshSpendDashboardTokenUsageNow(for: .cliproxyapi, force: true)
        #expect(store.tokenError(for: .cliproxyapi) == failure.error.errorDescription)
        #expect(store.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: .cliproxyapi)?
            .snapshot?.historyLabel == failure.error.errorDescription)
    }

    @Test
    func `old credential failure cannot label a new credential read failure`() async throws {
        let (store, settings) = Self.makeStore()
        let failure = try Self.failure()
        store.noteCLIProxyAPICollectionFailure(failure, for: .cliproxyapi)
        #expect(store.currentCLIProxyAPICollectionFailure(for: .cliproxyapi) == failure)
        settings.updateProviderConfig(provider: .cliproxyapi) { $0.apiKey = "fixture-new-key" }
        #expect(store.currentCLIProxyAPICollectionFailure(for: .cliproxyapi) == nil)
        store._test_tokenUsageSnapshotLoaderOverride = { _, _, _, _, _ in
            throw CLIProxyAPISpendError.storeUnreadable
        }

        await store.refreshSpendDashboardTokenUsageNow(for: .cliproxyapi, force: true)
        let published = try #require(store.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: .cliproxyapi))
        let snapshot = try #require(published.snapshot)
        #expect(snapshot.historyLabel == CLIProxyAPISpendError.storeUnreadable.errorDescription)
        #expect(snapshot.credentialScopeFingerprint != failure.fingerprint)
    }

    @Test
    func `turning tracking off clears the visible collection error`() throws {
        let (store, settings) = Self.makeStore()
        let failure = try Self.failure()
        store.noteCLIProxyAPICollectionFailure(failure, for: .cliproxyapi)
        #expect(store.tokenError(for: .cliproxyapi) == failure.error.errorDescription)
        settings.cliproxyapiSpendTrackingEnabled = false
        #expect(store.currentCLIProxyAPICollectionFailure(for: .cliproxyapi) == nil)
        store.noteCLIProxyAPICollectionFailure(nil, for: .cliproxyapi)
        #expect(store.tokenError(for: .cliproxyapi) == nil)
    }

    private static func makeStore() -> (UsageStore, SettingsStore) {
        let settings = testSettingsStore(
            suiteName: "CLIProxyAPICollectionFailurePublicationTests",
            config: testConfigWithAllProvidersDisabled())
        settings.updateProviderConfig(provider: .cliproxyapi) {
            $0.enabled = true
            $0.apiKey = "fixture-key"
            $0.extrasEnabled = true
        }
        settings.costUsageEnabled = true
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        return (store, settings)
    }

    private static func failure() throws -> CLIProxyAPISpendCollectionFailure {
        let settings = try CLIProxyAPISettings(
            baseURL: #require(URL(string: "http://127.0.0.1:8317")),
            managementKey: "fixture-key",
            authIndex: nil,
            spendTrackingEnabled: true)
        return CLIProxyAPISpendCollectionFailure(
            fingerprint: CLIProxyAPISpendSnapshot.fingerprint(settings: settings),
            dropped: 2)
    }

    private static func snapshot(fingerprint: String) -> CostUsageTokenSnapshot {
        CostUsageTokenSnapshot(
            sessionTokens: 10,
            sessionCostUSD: 1,
            last30DaysTokens: 10,
            last30DaysCostUSD: 1,
            historyDays: 30,
            historyLabel: CLIProxyAPISpendSnapshot.observedDisclaimer,
            credentialScopeFingerprint: fingerprint,
            daily: [],
            updatedAt: Date())
    }
}
