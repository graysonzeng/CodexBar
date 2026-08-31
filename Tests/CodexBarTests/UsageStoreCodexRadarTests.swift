import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct UsageStoreCodexRadarTests {
    @Test
    func `first success publishes raw snapshot and bumps revision`() async throws {
        let store = Self.makeStore(suite: "UsageStoreCodexRadarTests-first")
        let transport = Self.transport(body: Self.fullPayload)
        store._test_codexRadarTransportOverride = transport
        let now = Self.t0

        await store.refreshCodexRadarIntelligence(now: now)

        #expect(await transport.requests().count == 1)
        let snapshot = try #require(store.codexRadarSnapshot)
        #expect(snapshot.point(for: .gpt56SolXhigh).iq == 100.45)
        #expect(snapshot.point(for: .gpt56SolXhigh).averageMinutes == 24.37)
        #expect(store.codexRadarRevision == 1)
        #expect(store.codexRadarLastSuccessfulFetchAt == now)
        #expect(store.codexRadarLastFailureAt == nil)
        #expect(store.errors.isEmpty)
        _ = store.menuObservationToken
    }

    @Test
    func `success TTL skips at 4 minutes 59 seconds and fetches at 5 minutes`() async {
        let store = Self.makeStore(suite: "UsageStoreCodexRadarTests-ttl")
        let transport = Self.transport(body: Self.fullPayload)
        store._test_codexRadarTransportOverride = transport
        let t0 = Self.t0

        await store.refreshCodexRadarIntelligence(now: t0)
        await store.refreshCodexRadarIntelligence(now: t0.addingTimeInterval(4 * 60 + 59))
        #expect(await transport.requests().count == 1)

        await store.refreshCodexRadarIntelligence(now: t0.addingTimeInterval(5 * 60))
        #expect(await transport.requests().count == 2)
        #expect(store.codexRadarRevision == 1)
        #expect(store.codexRadarLastSuccessfulFetchAt == t0.addingTimeInterval(5 * 60))
    }

    @Test
    func `failure retry skips at 59 seconds and fetches at 61 seconds`() async {
        let store = Self.makeStore(suite: "UsageStoreCodexRadarTests-failure-ttl")
        let transport = Self.transport(body: "not-json", statusCode: 400)
        store._test_codexRadarTransportOverride = transport
        let t0 = Self.t0

        await store.refreshCodexRadarIntelligence(now: t0)
        #expect(store.codexRadarSnapshot == nil)
        #expect(store.codexRadarRevision == 0)
        #expect(store.codexRadarLastFailureAt == t0)
        #expect(store.codexRadarLastSuccessfulFetchAt == nil)
        #expect(store.errors.isEmpty)

        await store.refreshCodexRadarIntelligence(now: t0.addingTimeInterval(59))
        #expect(await transport.requests().count == 1)

        await store.refreshCodexRadarIntelligence(now: t0.addingTimeInterval(61))
        #expect(await transport.requests().count == 2)
        #expect(store.codexRadarLastFailureAt == t0.addingTimeInterval(61))
        #expect(store.errors.isEmpty)
    }

    @Test
    func `force bypasses success and failure gates`() async throws {
        let store = Self.makeStore(suite: "UsageStoreCodexRadarTests-force")
        let transport = Self.transport(body: Self.fullPayload)
        store._test_codexRadarTransportOverride = transport
        let t0 = Self.t0

        await store.refreshCodexRadarIntelligence(now: t0)
        await store.refreshCodexRadarIntelligence(force: true, now: t0.addingTimeInterval(1))
        #expect(await transport.requests().count == 2)

        store._test_codexRadarTransportOverride = Self.transport(body: "not-json", statusCode: 404)
        await store.refreshCodexRadarIntelligence(force: true, now: t0.addingTimeInterval(2))
        let failing = try #require(store._test_codexRadarTransportOverride as? ProviderHTTPTransportStub)
        #expect(await failing.requests().count == 1)
        #expect(store.codexRadarSnapshot != nil)
        #expect(store.codexRadarLastFailureAt == t0.addingTimeInterval(2))

        store._test_codexRadarTransportOverride = transport
        await store.refreshCodexRadarIntelligence(force: true, now: t0.addingTimeInterval(3))
        #expect(await transport.requests().count == 3)
    }

    @Test
    func `in-flight force and nonforce coalesce into one request`() async throws {
        let store = Self.makeStore(suite: "UsageStoreCodexRadarTests-coalesce")
        let gate = ReleaseGate()
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            await gate.wait()
            return Self.httpResponse(url: url, body: Self.fullPayload)
        }
        store._test_codexRadarTransportOverride = transport

        let first = Task { await store.refreshCodexRadarIntelligence(now: Self.t0) }
        try await Self.waitUntil { await transport.requests().count == 1 }
        store.scheduleCodexRadarIntelligenceRefresh(force: true, now: Self.t0.addingTimeInterval(1))
        let second = Task { await store.refreshCodexRadarIntelligence(now: Self.t0.addingTimeInterval(2)) }
        await gate.release()
        await first.value
        await second.value

        #expect(await transport.requests().count == 1)
        #expect(store.codexRadarRevision == 1)
    }

    @Test
    func `same raw snapshot updates success time without bumping revision`() async {
        let store = Self.makeStore(suite: "UsageStoreCodexRadarTests-same-raw")
        let transport = Self.transport(body: Self.fullPayload)
        store._test_codexRadarTransportOverride = transport
        let t0 = Self.t0

        await store.refreshCodexRadarIntelligence(now: t0)
        await store.refreshCodexRadarIntelligence(force: true, now: t0.addingTimeInterval(10))

        #expect(await transport.requests().count == 2)
        #expect(store.codexRadarRevision == 1)
        #expect(store.codexRadarLastSuccessfulFetchAt == t0.addingTimeInterval(10))
        #expect(store.codexRadarSnapshot?.point(for: .gpt56SolHigh).iq == 98.21)
    }

    @Test
    func `different raw snapshot publishes and bumps revision`() async {
        let store = Self.makeStore(suite: "UsageStoreCodexRadarTests-different-raw")
        let first = Self.transport(body: Self.fullPayload)
        store._test_codexRadarTransportOverride = first
        let t0 = Self.t0

        await store.refreshCodexRadarIntelligence(now: t0)
        store._test_codexRadarTransportOverride = Self.transport(body: Self.updatedPayload)
        await store.refreshCodexRadarIntelligence(force: true, now: t0.addingTimeInterval(10))

        #expect(store.codexRadarRevision == 2)
        #expect(store.codexRadarSnapshot?.point(for: .gpt56SolXhigh).iq == 101.0)
        #expect(store.codexRadarLastSuccessfulFetchAt == t0.addingTimeInterval(10))
    }

    @Test
    func `absent slots merge last-good without filling from other models`() async throws {
        let store = Self.makeStore(suite: "UsageStoreCodexRadarTests-merge")
        store._test_codexRadarTransportOverride = Self.transport(body: Self.fullPayload)
        let t0 = Self.t0

        await store.refreshCodexRadarIntelligence(now: t0)
        store._test_codexRadarTransportOverride = Self.transport(body: Self.partialPayload)
        await store.refreshCodexRadarIntelligence(force: true, now: t0.addingTimeInterval(10))

        let snapshot = try #require(store.codexRadarSnapshot)
        #expect(store.codexRadarRevision == 2)
        #expect(snapshot.point(for: .gpt56SolXhigh).iq == 101.0)
        #expect(snapshot.point(for: .gpt56SolXhigh).averageMinutes == 25.0)
        #expect(snapshot.point(for: .deepseekV4ProMax).iq == 87.1)
        #expect(snapshot.point(for: .deepseekV4ProMax).averageMinutes == 42.41)
        #expect(snapshot.point(for: .gpt56SolHigh).iq == 98.21)
    }

    @Test
    func `failure keeps last-good and does not write provider errors`() async {
        let store = Self.makeStore(suite: "UsageStoreCodexRadarTests-failure-last-good")
        store._test_codexRadarTransportOverride = Self.transport(body: Self.fullPayload)
        let t0 = Self.t0

        await store.refreshCodexRadarIntelligence(now: t0)
        let published = store.codexRadarSnapshot
        store._test_codexRadarTransportOverride = Self.transport(body: "not-json", statusCode: 404)
        await store.refreshCodexRadarIntelligence(force: true, now: t0.addingTimeInterval(10))

        #expect(store.codexRadarSnapshot == published)
        #expect(store.codexRadarRevision == 1)
        #expect(store.codexRadarLastSuccessfulFetchAt == t0)
        #expect(store.codexRadarLastFailureAt == t0.addingTimeInterval(10))
        #expect(store.errors.isEmpty)
    }

    @Test
    func `cancel drops in-flight result without publishing or writing clocks`() async throws {
        let store = Self.makeStore(suite: "UsageStoreCodexRadarTests-cancel")
        let transport = ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            try await Task.sleep(for: .seconds(30))
            return Self.httpResponse(url: url, body: Self.fullPayload)
        }
        store._test_codexRadarTransportOverride = transport

        let pending = Task { await store.refreshCodexRadarIntelligence(now: Self.t0) }
        try await Self.waitUntil { await transport.requests().count == 1 }
        store.cancelCodexRadarIntelligence()
        await pending.value

        #expect(store.codexRadarSnapshot == nil)
        #expect(store.codexRadarRevision == 0)
        #expect(store.codexRadarLastSuccessfulFetchAt == nil)
        #expect(store.codexRadarLastFailureAt == nil)
        #expect(store.errors.isEmpty)
        #expect(store.codexRadarTask == nil)
    }

    @Test
    func `automatic refresh does not request CodexRadar`() async {
        let store = Self.makeStore(suite: "UsageStoreCodexRadarTests-automatic")
        Self.stubProviderRefresh(store)
        let transport = Self.transport(body: Self.fullPayload)
        store._test_codexRadarTransportOverride = transport

        await store.refresh(forceTokenUsage: false)
        await store.refresh(enrichmentMode: .automatic)

        #expect(await transport.requests().isEmpty)
        #expect(store.codexRadarSnapshot == nil)
    }

    @Test
    func `refresh forceTokenUsage true issues exactly one CodexRadar request`() async {
        let store = Self.makeStore(suite: "UsageStoreCodexRadarTests-force-token")
        Self.stubProviderRefresh(store)
        let transport = Self.transport(body: Self.fullPayload)
        store._test_codexRadarTransportOverride = transport

        await store.refresh(forceTokenUsage: true)

        #expect(await transport.requests().count == 1)
        #expect(store.codexRadarRevision == 1)
        #expect(store.codexRadarSnapshot != nil)
    }

    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private static func makeStore(suite: String) -> UsageStore {
        let settings = testSettingsStore(suiteName: suite)
        settings.providerDetectionCompleted = true
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false
        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            guard let providerMetadata = metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: providerMetadata, enabled: false)
        }
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    private static func stubProviderRefresh(_ store: UsageStore) {
        store._test_providerRefreshOverride = { _ in }
        store._test_tokenUsageRefreshOverride = { _, _ in }
        store._test_codexCreditsLoaderOverride = {
            CreditsSnapshot(remaining: 0, events: [], updatedAt: Date())
        }
    }

    private static func transport(body: String, statusCode: Int = 200) -> ProviderHTTPTransportStub {
        ProviderHTTPTransportStub { request in
            let url = try #require(request.url)
            return Self.httpResponse(url: url, body: body, statusCode: statusCode)
        }
    }

    private nonisolated static func httpResponse(
        url: URL,
        body: String,
        statusCode: Int = 200) -> (Data, URLResponse)
    {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]) ?? HTTPURLResponse()
        return (Data(body.utf8), response)
    }

    private static func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @escaping @Sendable () async -> Bool) async throws
    {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("timed out waiting for CodexRadar transport")
    }

    private nonisolated static let fullPayload = #"""
    {
      "schema": 3,
      "mode": "equal_latest_3",
      "benchmark_id": "deep-swe",
      "points": [
        {"model": "gpt-5.6-sol", "effort": "xhigh", "iq": 100.45, "average_minutes": 24.37},
        {"model": "gpt-5.6-sol", "effort": "high", "iq": 98.21, "average_minutes": 19.82},
        {"model": "gpt-5.6-sol", "effort": "medium", "iq": 93.3, "average_minutes": 16.16},
        {"model": "deepseek-v4-flash", "effort": "max", "iq": 86.16, "average_minutes": 31.39},
        {"model": "deepseek-v4-pro", "effort": "max", "iq": 87.1, "average_minutes": 42.41},
        {"model": "dsh-ignored", "effort": "max", "iq": 1, "average_minutes": 1}
      ]
    }
    """#

    private nonisolated static let updatedPayload = #"""
    {
      "schema": 3,
      "mode": "equal_latest_3",
      "benchmark_id": "deep-swe",
      "points": [
        {"model": "gpt-5.6-sol", "effort": "xhigh", "iq": 101.0, "average_minutes": 25.0},
        {"model": "gpt-5.6-sol", "effort": "high", "iq": 98.21, "average_minutes": 19.82},
        {"model": "gpt-5.6-sol", "effort": "medium", "iq": 93.3, "average_minutes": 16.16},
        {"model": "deepseek-v4-flash", "effort": "max", "iq": 86.16, "average_minutes": 31.39},
        {"model": "deepseek-v4-pro", "effort": "max", "iq": 87.1, "average_minutes": 42.41}
      ]
    }
    """#

    private nonisolated static let partialPayload = #"""
    {
      "schema": 3,
      "mode": "equal_latest_3",
      "benchmark_id": "deep-swe",
      "points": [
        {"model": "gpt-5.6-sol", "effort": "xhigh", "iq": 101.0, "average_minutes": 25.0},
        {"model": "gpt-5.6-sol", "effort": "high", "iq": 98.21, "average_minutes": 19.82},
        {"model": "gpt-5.6-sol", "effort": "medium", "iq": 93.3, "average_minutes": 16.16},
        {"model": "deepseek-v4-flash", "effort": "max", "iq": 86.16, "average_minutes": 31.39}
      ]
    }
    """#
}

private actor ReleaseGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !self.isReleased else { return }
        await withCheckedContinuation { self.continuation = $0 }
    }

    func release() {
        self.isReleased = true
        self.continuation?.resume()
        self.continuation = nil
    }
}
