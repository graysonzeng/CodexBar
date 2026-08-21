import Foundation
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing

struct CLIProxyAPISpendLinuxTests {
    @Test
    func `spend tracking defaults off`() {
        #expect(CLIProxyAPISettingsReader.spendTrackingEnabled(environment: [:]) == false)
        #expect(CLIProxyAPISettingsReader.spendTrackingEnabled(environment: [
            "CLIPROXYAPI_SPEND_TRACKING": "1",
        ]))
        #expect(CLIProxyAPIProviderDescriptor.descriptor.tokenCost.supportsTokenCost)
        #expect(CLIProxyAPIProviderDescriptor.descriptor.tokenCost.supportsTokenSnapshot)
    }

    @Test
    func `unset extrasEnabled does not override spend tracking env`() {
        let preserved = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: ["CLIPROXYAPI_SPEND_TRACKING": "1"],
            provider: .cliproxyapi,
            config: ProviderConfig(id: .cliproxyapi))
        #expect(preserved["CLIPROXYAPI_SPEND_TRACKING"] == "1")

        let disabled = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: ["CLIPROXYAPI_SPEND_TRACKING": "1"],
            provider: .cliproxyapi,
            config: ProviderConfig(id: .cliproxyapi, extrasEnabled: false))
        #expect(disabled["CLIPROXYAPI_SPEND_TRACKING"] == "0")

        let enabled = ProviderConfigEnvironment.applyProviderConfigOverrides(
            base: [:],
            provider: .cliproxyapi,
            config: ProviderConfig(id: .cliproxyapi, extrasEnabled: true))
        #expect(enabled["CLIPROXYAPI_SPEND_TRACKING"] == "1")
    }

    @Test
    func `pop usage queue uses GET count query and Bearer`() async throws {
        let capture = UsageQueueCapture()
        let transport = ProviderHTTPTransportHandler { request in
            capture.append(request)
            return try Self.http("[]")
        }
        let client = try CLIProxyAPIManagementClient(
            settings: Self.settings(),
            transport: transport)
        _ = try await client.popUsageQueue()
        let request = try #require(capture.requests.first)
        #expect(request.httpMethod == "GET")
        let url = try #require(request.url)
        #expect(url.path.hasSuffix("/v0/management/usage-queue"))
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let count = try #require(items.first { $0.name == "count" }?.value.flatMap(Int.init))
        #expect(count > 1)
        #expect(count == CLIProxyAPISpendCollector.defaultPageSize)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    @Test
    func `decodes real token mix and drops api_key`() throws {
        let secret = "sk-live-should-not-leak"
        let json = """
        [
          {
            "timestamp": "2026-08-20T12:00:00Z",
            "auth_index": "idx-1",
            "provider": "openai",
            "model": "gpt-5",
            "alias": "gpt",
            "request_id": "req-1",
            "failed": false,
            "api_key": "\(secret)",
            "tokens": {
              "input_tokens": 10,
              "output_tokens": 4,
              "reasoning_tokens": 2,
              "cached_tokens": 3,
              "cache_creation_tokens": 1,
              "total_tokens": 20
            }
          },
          {
            "timestamp": "2026-08-20T12:01:00Z",
            "auth_index": "idx-1",
            "provider": "openai",
            "failed": true,
            "request_id": "req-fail",
            "fail": { "status_code": 500 },
            "tokens": { "input_tokens": 8, "output_tokens": 0 }
          }
        ]
        """
        let data = Data(json.utf8)
        #expect(CLIProxyAPISpendQueueDecoder.containsRawAPIKey(data, secret: secret))
        let decoded = try CLIProxyAPISpendQueueDecoder.events(from: data)
        #expect(decoded.skipped == 0)
        #expect(decoded.events.count == 2)
        let first = try #require(decoded.events.first)
        #expect(first.requestID == "req-1")
        #expect(first.model == "gpt-5")
        #expect(first.tokens.inputTokens == 10)
        #expect(first.tokens.outputTokens == 4)
        #expect(first.tokens.reasoningTokens == 2)
        #expect(first.tokens.cacheReadTokens == 3)
        #expect(first.tokens.cacheCreationTokens == 1)
        #expect(first.tokens.totalTokens == 20)
        #expect(first.failed == false)
        let failed = try #require(decoded.events.last)
        #expect(failed.model == "unknown")
        #expect(failed.failed)
        #expect(failed.statusCode == 500)
        #expect(CLIProxyAPISpendAggregator.listPriceUSD(event: failed, customPricing: .empty) == nil)
    }

    @Test
    func `store dedupes request_id and aggregator skips failed cost`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxyapi-spend-\(UUID().uuidString)", isDirectory: true)
        let store = CLIProxyAPISpendStore(cacheRoot: root)
        let now = Date(timeIntervalSince1970: 1_787_212_800)
        let event = Self.event(requestID: "dup", occurredAt: now, failed: false, input: 10, output: 2)
        let failed = Self.event(
            requestID: "fail",
            occurredAt: now,
            failed: true,
            input: 99,
            output: 9,
            model: "unknown-model")
        let first = try store.insert([event, failed], fingerprint: "fp-a")
        #expect(first.inserted == 2)
        let second = try store.insert([event], fingerprint: "fp-a")
        #expect(second.duplicates == 1)
        #expect(second.inserted == 0)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let custom = CostUsageCustomPricing(
            entries: ["gpt-5": .init(input: 1, output: 2)],
            fingerprint: "test")
        let snapshot = try CLIProxyAPISpendAggregator.snapshot(
            events: store.loadEvents(fingerprint: "fp-a"),
            now: now,
            historyDays: 7,
            calendar: calendar,
            customPricing: custom)
        #expect(snapshot.daily.count == 1)
        let day = try #require(snapshot.daily.first)
        #expect(day.unmeteredRequestCount == 1)
        #expect(day.requestCount == 2)
        #expect(day.costUSD != nil)
    }

    @Test
    func `collector drains until empty and persists immediately`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxyapi-spend-\(UUID().uuidString)", isDirectory: true)
        let store = CLIProxyAPISpendStore(cacheRoot: root)
        let pages = CLIProxyAPISpendPageState(pages: [
            Self.queueJSON([
                Self.eventJSON(id: "a", ts: "2026-08-20T12:00:00Z"),
                Self.eventJSON(id: "b", ts: "2026-08-20T12:00:01Z"),
            ]),
            "[]",
        ])
        let transport = ProviderHTTPTransportHandler { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("usage-statistics-enabled") {
                return try Self.http("true")
            }
            if path.hasSuffix("usage-queue") {
                return try Self.http(pages.next())
            }
            throw URLError(.badURL)
        }
        let collector = try CLIProxyAPISpendCollector(
            client: CLIProxyAPIManagementClient(settings: Self.settings(), transport: transport),
            store: store,
            pageSize: 2,
            maxPagesPerTick: 10)
        let tick = try await collector.drainUntilEmpty()
        #expect(tick.popped == 2)
        #expect(tick.inserted == 2)
        #expect(tick.pages >= 2)
        #expect(try store.loadEvents(fingerprint: CLIProxyAPISpendSnapshot.fingerprint(settings: Self.settings()))
            .map(\.requestID).sorted() == ["a", "b"])
    }

    @Test
    func `statistics disabled does not pop the queue`() async throws {
        let popped = UsageQueueCapture()
        let transport = ProviderHTTPTransportHandler { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("usage-statistics-enabled") {
                return try Self.http("false")
            }
            if path.hasSuffix("usage-queue") {
                popped.append(request)
                return try Self.http("[]")
            }
            throw URLError(.badURL)
        }
        let collector = try CLIProxyAPISpendCollector(
            client: CLIProxyAPIManagementClient(settings: Self.settings(), transport: transport),
            store: CLIProxyAPISpendStore(cacheRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent("cliproxyapi-spend-\(UUID().uuidString)", isDirectory: true)))
        await #expect(throws: CLIProxyAPISpendError.usageStatisticsDisabled) {
            _ = try await collector.drainUntilEmpty()
        }
        #expect(popped.requests.isEmpty)
    }

    @Test
    func `tracking off returns confirmed empty snapshot`() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxyapi-spend-\(UUID().uuidString)", isDirectory: true)
        let snapshot = try await CLIProxyAPISpendSnapshot.load(
            environment: [:],
            now: Date(),
            historyDays: 7,
            calendar: calendar,
            store: CLIProxyAPISpendStore(cacheRoot: root))
        #expect(snapshot.daily.isEmpty)
        #expect(snapshot.historyCoverageIsEstablished == false)
        #expect(snapshot.historyLabel == CLIProxyAPISpendError.trackingDisabled.errorDescription)
    }

    @Test
    func `unauthorized fail-closes even with history`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxyapi-spend-\(UUID().uuidString)", isDirectory: true)
        let store = CLIProxyAPISpendStore(cacheRoot: root)
        _ = try store.insert(
            [Self.event(
                requestID: "kept",
                occurredAt: Date(),
                failed: false,
                input: 1,
                output: 1)],
            fingerprint: CLIProxyAPISpendSnapshot.fingerprint(settings: Self.settings()))
        let transport = ProviderHTTPTransportHandler { _ in
            try Self.http("denied", status: 401)
        }
        await #expect(throws: CLIProxyAPISpendError.unauthorized) {
            _ = try await CLIProxyAPISpendSnapshot.load(
                environment: [
                    "CLIPROXYAPI_MANAGEMENT_KEY": "secret",
                    "CLIPROXYAPI_SPEND_TRACKING": "1",
                ],
                now: Date(),
                historyDays: 7,
                calendar: Calendar(identifier: .gregorian),
                store: store,
                client: CLIProxyAPIManagementClient(settings: Self.settings(), transport: transport))
        }
    }

    @Test
    func `store isolates events by credential fingerprint`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxyapi-spend-\(UUID().uuidString)", isDirectory: true)
        let store = CLIProxyAPISpendStore(cacheRoot: root)
        let now = Date()
        _ = try store.insert(
            [Self.event(requestID: "old-key", occurredAt: now, failed: false, input: 1, output: 1)],
            fingerprint: "fp-old")
        _ = try store.insert(
            [Self.event(requestID: "new-key", occurredAt: now, failed: false, input: 2, output: 2)],
            fingerprint: "fp-new")
        #expect(try store.loadEvents(fingerprint: "fp-new").map(\.requestID) == ["new-key"])
        #expect(try store.loadEvents(fingerprint: "fp-old").map(\.requestID) == ["old-key"])
    }

    @Test
    func `loadEvents on missing store returns empty without creating files`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxyapi-spend-missing-\(UUID().uuidString)", isDirectory: true)
        let store = CLIProxyAPISpendStore(cacheRoot: root)
        #expect(try store.loadEvents(fingerprint: "fp-missing").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.databaseURL.path))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test
    func `list price uses models.dev via upstream provider alias`() throws {
        let json = """
        {
          "google": {
            "id": "google",
            "models": {
              "gemini-2.5-pro": {
                "id": "gemini-2.5-pro",
                "cost": { "input": 1, "output": 2 }
              }
            }
          }
        }
        """
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
        let priced = Self.event(
            requestID: "gemini-priced",
            occurredAt: Date(timeIntervalSince1970: 1_787_212_800),
            failed: false,
            input: 1_000_000,
            output: 1_000_000,
            model: "gemini-2.5-pro")
        let gemini = CLIProxyAPISpendEvent(
            requestID: priced.requestID,
            occurredAt: priced.occurredAt,
            authIndex: priced.authIndex,
            upstreamProvider: "gemini",
            model: priced.model,
            alias: priced.alias,
            tokens: priced.tokens,
            failed: priced.failed,
            statusCode: priced.statusCode)
        #expect(
            CLIProxyAPISpendAggregator.listPriceUSD(
                event: gemini,
                customPricing: .empty,
                modelsDevCatalog: catalog) == 3)

        let unknown = Self.event(
            requestID: "unknown",
            occurredAt: Date(timeIntervalSince1970: 1_787_212_800),
            failed: false,
            input: 10,
            output: 2,
            model: "totally-unknown-model")
        #expect(
            CLIProxyAPISpendAggregator.listPriceUSD(
                event: unknown,
                customPricing: .empty,
                modelsDevCatalog: catalog) == nil)
    }

    private static func settings() throws -> CLIProxyAPISettings {
        try CLIProxyAPISettings(
            baseURL: #require(URL(string: "http://127.0.0.1:8317")),
            managementKey: "secret",
            authIndex: nil,
            spendTrackingEnabled: true)
    }

    private static func event(
        requestID: String,
        occurredAt: Date,
        failed: Bool,
        input: Int,
        output: Int,
        model: String = "gpt-5") -> CLIProxyAPISpendEvent
    {
        CLIProxyAPISpendEvent(
            requestID: requestID,
            occurredAt: occurredAt,
            authIndex: "idx-1",
            upstreamProvider: "openai",
            model: model,
            alias: model,
            tokens: CLIProxyAPISpendTokenMix(inputTokens: input, outputTokens: output, totalTokens: input + output),
            failed: failed,
            statusCode: failed ? 500 : nil)
    }

    private static func eventJSON(id: String, ts: String) -> String {
        """
        {"timestamp":"\(ts)","auth_index":"idx-1","provider":"openai","model":"gpt-5","request_id":"\(
            id)","failed":false,"tokens":{"input_tokens":1,"output_tokens":1,"total_tokens":2}}
        """
    }

    private static func queueJSON(_ events: [String]) -> String {
        "[\(events.joined(separator: ","))]"
    }

    private static func http(_ json: String, status: Int = 200) throws -> (Data, URLResponse) {
        let url = try #require(URL(string: "http://127.0.0.1:8317/v0/management/x"))
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (Data(json.utf8), response)
    }
}

private final class UsageQueueCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }

    func append(_ request: URLRequest) {
        self.lock.lock()
        self.storage.append(request)
        self.lock.unlock()
    }
}

private final class CLIProxyAPISpendPageState: @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [String]

    init(pages: [String]) {
        self.pages = pages
    }

    func next() -> String {
        self.lock.lock()
        defer { self.lock.unlock() }
        if self.pages.isEmpty { return "[]" }
        return self.pages.removeFirst()
    }
}
