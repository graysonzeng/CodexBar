#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct CLIProxyAPISpendStorageLinuxTests {
    @Test
    func `persist failure preserves dropped count and pauses later pops`() async throws {
        let failing = Self.failingStore()
        let pops = UsageQueueCapture()
        let pages = CLIProxyAPISpendPageState(pages: [
            Self.queueJSON([
                Self.eventJSON(id: "a", ts: "2026-08-20T12:00:00Z"),
                Self.eventJSON(id: "b", ts: "2026-08-20T12:00:01Z"),
            ]),
            Self.queueJSON([Self.eventJSON(id: "c", ts: "2026-08-20T12:00:02Z")]),
        ])
        let collector = try CLIProxyAPISpendCollector(
            client: CLIProxyAPIManagementClient(settings: Self.settings(), transport: Self.queueTransport(
                pops: pops,
                pages: pages)),
            store: failing,
            pageSize: 2,
            maxPagesPerTick: 10)
        let fingerprint = try CLIProxyAPISpendSnapshot.fingerprint(settings: Self.settings())
        var gate = CLIProxyAPISpendDrainGate()

        do {
            _ = try await gate.drain(fingerprint: fingerprint) {
                try await collector.drainUntilEmpty()
            }
            Issue.record("expected persistFailed")
        } catch let error as CLIProxyAPISpendError {
            #expect(error == .persistFailed(dropped: 2))
            let message = error.errorDescription ?? ""
            #expect(message.contains("2 popped usage-queue event(s) were not saved"))
            #expect(message.contains("paused"))
            #expect(message.contains("Turn Track CLIProxyAPI spend off then on"))
            #expect(!message.contains("secret"))
        }
        #expect(gate.isPaused(for: fingerprint))
        #expect(gate.failure?.dropped == 2)
        #expect(pops.requests.count == 1)

        await #expect(throws: CLIProxyAPISpendError.persistFailed(dropped: 2)) {
            _ = try await gate.drain(fingerprint: fingerprint) {
                try await collector.drainUntilEmpty()
            }
        }
        #expect(pops.requests.count == 1)
    }

    @Test
    func `resume after persist failure pops again`() async throws {
        let pops = UsageQueueCapture()
        let failingPages = CLIProxyAPISpendPageState(pages: [
            Self.queueJSON([Self.eventJSON(id: "lost", ts: "2026-08-20T12:00:00Z")]),
        ])
        let failingCollector = try CLIProxyAPISpendCollector(
            client: CLIProxyAPIManagementClient(settings: Self.settings(), transport: Self.queueTransport(
                pops: pops,
                pages: failingPages)),
            store: Self.failingStore(),
            pageSize: 2)
        let fingerprint = try CLIProxyAPISpendSnapshot.fingerprint(settings: Self.settings())
        var gate = CLIProxyAPISpendDrainGate()
        await #expect(throws: CLIProxyAPISpendError.persistFailed(dropped: 1)) {
            _ = try await gate.drain(fingerprint: fingerprint) {
                try await failingCollector.drainUntilEmpty()
            }
        }
        #expect(pops.requests.count == 1)

        gate.resume()
        #expect(!gate.isPaused(for: fingerprint))

        let recoveredRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxyapi-spend-ok-\(UUID().uuidString)", isDirectory: true)
        let recoveredPages = CLIProxyAPISpendPageState(pages: [
            Self.queueJSON([Self.eventJSON(id: "kept", ts: "2026-08-20T12:01:00Z")]),
            "[]",
        ])
        let recoveredCollector = try CLIProxyAPISpendCollector(
            client: CLIProxyAPIManagementClient(settings: Self.settings(), transport: Self.queueTransport(
                pops: pops,
                pages: recoveredPages)),
            store: CLIProxyAPISpendStore(cacheRoot: recoveredRoot),
            pageSize: 2)
        let tick = try await gate.drain(fingerprint: fingerprint) {
            try await recoveredCollector.drainUntilEmpty()
        }
        #expect(tick.inserted == 1)
        #expect(pops.requests.count == 2)
        #expect(try CLIProxyAPISpendStore(cacheRoot: recoveredRoot)
            .loadEvents(fingerprint: fingerprint)
            .map(\.requestID) == ["kept"])
    }

    @Test
    func `scope change does not leak persist pause across credentials`() async throws {
        let pops = UsageQueueCapture()
        let pages = CLIProxyAPISpendPageState(pages: [
            Self.queueJSON([Self.eventJSON(id: "a", ts: "2026-08-20T12:00:00Z")]),
            Self.queueJSON([Self.eventJSON(id: "b", ts: "2026-08-20T12:00:01Z")]),
        ])
        let collector = try CLIProxyAPISpendCollector(
            client: CLIProxyAPIManagementClient(settings: Self.settings(), transport: Self.queueTransport(
                pops: pops,
                pages: pages)),
            store: Self.failingStore(),
            pageSize: 2)
        var gate = CLIProxyAPISpendDrainGate()
        await #expect(throws: CLIProxyAPISpendError.persistFailed(dropped: 1)) {
            _ = try await gate.drain(fingerprint: "fp-a") {
                try await collector.drainUntilEmpty()
            }
        }
        #expect(gate.isPaused(for: "fp-a"))
        #expect(pops.requests.count == 1)

        await #expect(throws: CLIProxyAPISpendError.persistFailed(dropped: 1)) {
            _ = try await gate.drain(fingerprint: "fp-b") {
                try await collector.drainUntilEmpty()
            }
        }
        #expect(pops.requests.count == 2)
        #expect(!gate.isPaused(for: "fp-a"))
        #expect(gate.isPaused(for: "fp-b"))
    }

    @Test
    func `fresh-read success does not hide failed collection`() throws {
        let now = Date(timeIntervalSince1970: 1_787_212_800)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let snapshot = CLIProxyAPISpendAggregator.snapshot(
            events: [Self.event(requestID: "kept", occurredAt: now, failed: false, input: 1, output: 1)],
            now: now,
            historyDays: 7,
            calendar: calendar,
            credentialScopeFingerprint: "fp-a",
            historyLabel: CLIProxyAPISpendSnapshot.observedDisclaimer)
        #expect(snapshot.historyCoverageIsEstablished)
        #expect(!snapshot.daily.isEmpty)

        let overlaid = CLIProxyAPISpendSnapshot.overlayingCollectionFailure(
            snapshot,
            failure: CLIProxyAPISpendCollectionFailure(fingerprint: "fp-a", dropped: 3))
        #expect(overlaid.historyLabel == CLIProxyAPISpendError.persistFailed(dropped: 3).errorDescription)
        #expect(overlaid.daily == snapshot.daily)
        #expect(overlaid.historyCoverageIsEstablished)
        #expect(overlaid.historyLabel?.contains("secret") != true)

        let other = CLIProxyAPISpendSnapshot.overlayingCollectionFailure(
            snapshot,
            failure: CLIProxyAPISpendCollectionFailure(fingerprint: "fp-b", dropped: 3))
        #expect(other.historyLabel == CLIProxyAPISpendSnapshot.observedDisclaimer)
        #expect(other.daily == snapshot.daily)
    }

    @Test
    func `missing DB stays empty without creating files`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxyapi-spend-missing-\(UUID().uuidString)", isDirectory: true)
        let store = CLIProxyAPISpendStore(cacheRoot: root)
        #expect(try store.loadEvents(fingerprint: "fp-missing").isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.databaseURL.path))
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test
    func `corrupt schema and query errors throw rather than history`() throws {
        let now = Date(timeIntervalSince1970: 1_787_212_800)
        let event = Self.event(requestID: "kept", occurredAt: now, failed: false, input: 1, output: 1)

        let garbageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxyapi-spend-garbage-\(UUID().uuidString)", isDirectory: true)
        let garbageStore = CLIProxyAPISpendStore(cacheRoot: garbageRoot)
        try FileManager.default.createDirectory(at: garbageRoot, withIntermediateDirectories: true)
        try Data("not a sqlite database".utf8).write(to: garbageStore.databaseURL)
        Self.expectStoreReadFailure(garbageStore)
        Self.expectStoreWriteFailure(garbageStore, event: event)

        let schemaRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxyapi-spend-schema-\(UUID().uuidString)", isDirectory: true)
        let schemaStore = CLIProxyAPISpendStore(cacheRoot: schemaRoot)
        try Self.makeDatabase(at: schemaStore.databaseURL, userVersion: 2, createEventsTable: true)
        #expect(throws: CLIProxyAPISpendError.unsupportedSchema) {
            _ = try schemaStore.loadEvents(fingerprint: "fp-a")
        }
        #expect(throws: CLIProxyAPISpendError.unsupportedSchema) {
            _ = try schemaStore.insert([event], fingerprint: "fp-a")
        }
        #expect(try Self.userVersion(at: schemaStore.databaseURL) == 2)
        #expect(FileManager.default.fileExists(atPath: schemaStore.databaseURL.path))

        let queryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxyapi-spend-query-\(UUID().uuidString)", isDirectory: true)
        let queryStore = CLIProxyAPISpendStore(cacheRoot: queryRoot)
        try Self.makeDatabase(at: queryStore.databaseURL, userVersion: 1, createEventsTable: false)
        #expect(throws: CLIProxyAPISpendError.storeUnreadable) {
            _ = try queryStore.loadEvents(fingerprint: "fp-a")
        }
    }

    @Test
    func `write open failure does not rebuild the spend file`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxyapi-spend-open-\(UUID().uuidString)", isDirectory: true)
        let store = CLIProxyAPISpendStore(cacheRoot: root)
        try FileManager.default.createDirectory(at: store.databaseURL, withIntermediateDirectories: true)
        let before = try FileManager.default.contentsOfDirectory(atPath: store.databaseURL.path)
        #expect(throws: CLIProxyAPISpendError.storeUnreadable) {
            _ = try store.insert(
                [Self.event(requestID: "x", occurredAt: Date(), failed: false, input: 1, output: 1)],
                fingerprint: "fp-a")
        }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: store.databaseURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.databaseURL.path) == before)
    }

    @Test
    func `snapshot load throws instead of publishing empty covered history`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxyapi-spend-snap-\(UUID().uuidString)", isDirectory: true)
        let store = CLIProxyAPISpendStore(cacheRoot: root)
        try Self.makeDatabase(at: store.databaseURL, userVersion: 2, createEventsTable: true)
        let transport = ProviderHTTPTransportHandler { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("usage-statistics-enabled") {
                return try Self.http("true")
            }
            throw URLError(.badURL)
        }
        await #expect(throws: CLIProxyAPISpendError.unsupportedSchema) {
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

    private static func failingStore() -> CLIProxyAPISpendStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cliproxyapi-spend-fail-\(UUID().uuidString)", isDirectory: true)
        let store = CLIProxyAPISpendStore(cacheRoot: root)
        try? FileManager.default.createDirectory(at: store.databaseURL, withIntermediateDirectories: true)
        return store
    }

    private static func expectStoreReadFailure(_ store: CLIProxyAPISpendStore) {
        do {
            _ = try store.loadEvents(fingerprint: "fp-a")
            Issue.record("expected a typed store read failure")
        } catch let error as CLIProxyAPISpendError {
            #expect(error == .storeUnreadable || error == .unsupportedSchema)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    private static func expectStoreWriteFailure(_ store: CLIProxyAPISpendStore, event: CLIProxyAPISpendEvent) {
        do {
            _ = try store.insert([event], fingerprint: "fp-a")
            Issue.record("expected a typed store write failure")
        } catch let error as CLIProxyAPISpendError {
            #expect(error == .storeUnreadable || error == .unsupportedSchema)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    private static func makeDatabase(at url: URL, userVersion: Int, createEventsTable: Bool) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw CLIProxyAPISpendError.storeUnreadable
        }
        defer { sqlite3_close(db) }
        if createEventsTable {
            let sql = """
            CREATE TABLE events (
                dedupe_key TEXT NOT NULL,
                credential_scope TEXT NOT NULL,
                request_id TEXT NOT NULL,
                occurred_at REAL NOT NULL,
                auth_index TEXT NOT NULL,
                upstream_provider TEXT NOT NULL,
                model TEXT NOT NULL,
                alias TEXT NOT NULL,
                input_tokens INTEGER,
                output_tokens INTEGER,
                reasoning_tokens INTEGER,
                cache_read_tokens INTEGER,
                cache_creation_tokens INTEGER,
                total_tokens INTEGER,
                failed INTEGER NOT NULL,
                status_code INTEGER,
                PRIMARY KEY (dedupe_key, credential_scope)
            );
            """
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw CLIProxyAPISpendError.storeUnreadable
            }
        }
        guard sqlite3_exec(db, "PRAGMA user_version = \(userVersion)", nil, nil, nil) == SQLITE_OK else {
            throw CLIProxyAPISpendError.storeUnreadable
        }
    }

    private static func userVersion(at url: URL) throws -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw CLIProxyAPISpendError.storeUnreadable
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK else {
            throw CLIProxyAPISpendError.storeUnreadable
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw CLIProxyAPISpendError.storeUnreadable
        }
        return Int(sqlite3_column_int(statement, 0))
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
        output: Int) -> CLIProxyAPISpendEvent
    {
        CLIProxyAPISpendEvent(
            requestID: requestID,
            occurredAt: occurredAt,
            authIndex: "idx-1",
            upstreamProvider: "openai",
            model: "gpt-5",
            alias: "gpt-5",
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

    private static func queueTransport(
        pops: UsageQueueCapture,
        pages: CLIProxyAPISpendPageState) -> ProviderHTTPTransportHandler
    {
        ProviderHTTPTransportHandler { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("usage-statistics-enabled") {
                return try Self.http("true")
            }
            if path.hasSuffix("usage-queue") {
                pops.append(request)
                return try Self.http(pages.next())
            }
            throw URLError(.badURL)
        }
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
