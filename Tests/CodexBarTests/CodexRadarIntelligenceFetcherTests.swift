import CodexBarCore
import Foundation
import Testing

struct CodexRadarIntelligenceFetcherTests {
    @Test
    func `allowlist order and wire keys are fixed`() {
        #expect(CodexRadarIntelligenceTarget.allCases.map(\.model) == [
            "gpt-5.6-sol",
            "gpt-5.6-sol",
            "gpt-5.6-sol",
            "deepseek-v4-flash",
            "deepseek-v4-pro",
        ])
        #expect(CodexRadarIntelligenceTarget.allCases.map(\.effort) == [
            "xhigh",
            "high",
            "medium",
            "max",
            "max",
        ])
        #expect(
            CodexRadarIntelligence.endpointURL.absoluteString
                == "https://api.codexradar.com/api/v1/intelligence-efficiency?benchmark=deep-swe")
    }

    @Test
    func `roundedDisplayInt uses guarded Math.round and does not clamp`() {
        #expect(CodexRadarIntelligence.roundedDisplayInt(19.82) == 20)
        #expect(CodexRadarIntelligence.roundedDisplayInt(98.21) == 98)
        #expect(CodexRadarIntelligence.roundedDisplayInt(0.5) == 1)
        #expect(CodexRadarIntelligence.roundedDisplayInt(1.5) == 2)
        #expect(CodexRadarIntelligence.roundedDisplayInt(0) == 0)
        #expect(CodexRadarIntelligence.roundedDisplayInt(-1) == -1)
        #expect(CodexRadarIntelligence.roundedDisplayInt(1e300) == nil)
        #expect(CodexRadarIntelligence.roundedDisplayInt(.nan) == nil)
        #expect(CodexRadarIntelligence.roundedDisplayInt(.infinity) == nil)
        #expect(CodexRadarIntelligence.roundedDisplayInt(-.infinity) == nil)
    }

    @Test
    func `snapshot init fills five slots by target`() {
        let snapshot = CodexRadarIntelligenceSnapshot(points: [
            CodexRadarIntelligencePoint(target: .gpt56SolHigh, iq: 98.21, averageMinutes: 19.82),
        ])

        #expect(snapshot.points.map(\.target) == CodexRadarIntelligenceTarget.allCases)
        #expect(snapshot.point(for: .gpt56SolHigh).iq == 98.21)
        #expect(snapshot.point(for: .gpt56SolHigh).averageMinutes == 19.82)
        #expect(snapshot.point(for: .gpt56SolXhigh).iq == nil)
        #expect(snapshot.point(for: .gpt56SolXhigh).averageMinutes == nil)
        #expect(snapshot.point(for: .deepseekV4ProMax).iq == nil)
    }

    @Test
    func `fetch issues a credential-less GET with timeout and Accept`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            try (Self.fixtureData(), Self.http(request.url, status: 200))
        }

        _ = try await CodexRadarIntelligence.fetch(transport: stub)
        let request = try #require(await stub.requests().first)

        #expect(request.httpMethod == "GET")
        #expect(request.url == CodexRadarIntelligence.endpointURL)
        #expect(request.timeoutInterval == 30)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpBody == nil)
        #expect(await stub.requests().count == 1)
    }

    @Test
    func `fetch keeps raw doubles and ignores dsh targets`() async throws {
        let snapshot = try await self.fetch(body: Self.fixtureData())

        #expect(snapshot.points.map(\.target) == CodexRadarIntelligenceTarget.allCases)
        #expect(snapshot.point(for: .gpt56SolXhigh).iq == 100.45)
        #expect(snapshot.point(for: .gpt56SolXhigh).averageMinutes == 24.37)
        #expect(snapshot.point(for: .gpt56SolHigh).iq == 98.21)
        #expect(snapshot.point(for: .gpt56SolHigh).averageMinutes == 19.82)
        #expect(snapshot.point(for: .gpt56SolMedium).iq == 93.3)
        #expect(snapshot.point(for: .gpt56SolMedium).averageMinutes == 16.16)
        #expect(snapshot.point(for: .deepseekV4FlashMax).iq == 86.16)
        #expect(snapshot.point(for: .deepseekV4FlashMax).averageMinutes == 31.39)
        #expect(snapshot.point(for: .deepseekV4ProMax).iq == 87.1)
        #expect(snapshot.point(for: .deepseekV4ProMax).averageMinutes == 42.41)
        #expect(snapshot.points.allSatisfy { $0.iq != 1.0 && $0.iq != 3.0 })
        #expect(snapshot.sourceUpdatedAt == Self.sourceUpdatedAt("2026-08-30T17:38:19+00:00"))
    }

    @Test
    func `partially absent allowlist slots succeed as nil`() async throws {
        let snapshot = try await self.fetch(body: Self.withoutAllowlistPoint(
            model: "deepseek-v4-pro",
            effort: "max"))

        #expect(snapshot.point(for: .gpt56SolHigh).averageMinutes == 19.82)
        #expect(snapshot.point(for: .deepseekV4ProMax).iq == nil)
        #expect(snapshot.point(for: .deepseekV4ProMax).averageMinutes == nil)
        #expect(snapshot.points.count(where: { $0.iq != nil }) == 4)
    }

    @Test
    func `retries a transient HTTP status then succeeds`() async throws {
        actor Codes {
            var remaining = [503, 200]
            func next() -> Int {
                self.remaining.removeFirst()
            }
        }
        let codes = Codes()
        let fixture = try Self.fixtureData()
        let stub = ProviderHTTPTransportStub { request in
            let status = await codes.next()
            let headers = status == 503 ? ["Retry-After": "0"] : [String: String]()
            return try (status == 200 ? fixture : Data(), Self.http(request.url, status: status, headers: headers))
        }

        let snapshot = try await CodexRadarIntelligence.fetch(transport: stub)

        #expect(await stub.requests().count == 2)
        #expect(snapshot.point(for: .gpt56SolHigh).averageMinutes == 19.82)
    }

    @Test
    func `non-HTTP responses and transport failures are invalidResponse`() async {
        let nonHTTP = ProviderHTTPTransportHandler { request in
            (
                Data(),
                URLResponse(
                    url: request.url ?? CodexRadarIntelligence.endpointURL,
                    mimeType: "application/json",
                    expectedContentLength: 0,
                    textEncodingName: nil))
        }
        let transportError = ProviderHTTPTransportHandler { _ in
            throw URLError(.badServerResponse)
        }

        await #expect(throws: CodexRadarIntelligenceError.invalidResponse) {
            _ = try await CodexRadarIntelligence.fetch(transport: nonHTTP)
        }
        await #expect(throws: CodexRadarIntelligenceError.invalidResponse) {
            _ = try await CodexRadarIntelligence.fetch(transport: transportError)
        }
    }

    @Test
    func `HTTP 4xx is httpStatus without retry`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            try (Data(#"{"error":"no"}"#.utf8), Self.http(request.url, status: 404))
        }

        await #expect(throws: CodexRadarIntelligenceError.httpStatus(404)) {
            _ = try await CodexRadarIntelligence.fetch(transport: stub)
        }
        #expect(await stub.requests().count == 1)
    }

    @Test
    func `HTTP 5xx after retry is httpStatus`() async throws {
        let stub = ProviderHTTPTransportStub { request in
            try (Data(), Self.http(request.url, status: 500, headers: ["Retry-After": "0"]))
        }

        await #expect(throws: CodexRadarIntelligenceError.httpStatus(500)) {
            _ = try await CodexRadarIntelligence.fetch(transport: stub)
        }
        #expect(await stub.requests().count == 2)
    }

    @Test
    func `malformed JSON is invalidJSON`() async {
        await #expect(throws: CodexRadarIntelligenceError.invalidJSON) {
            _ = try await self.fetch(body: Data("not-json".utf8))
        }
        await #expect(throws: CodexRadarIntelligenceError.invalidJSON) {
            _ = try await self.fetch(body: Data("[]".utf8))
        }
    }

    @Test
    func `wrong schema is unexpectedPayload`() async throws {
        try await self.expectUnexpectedPayload(Self.replacing(#""schema": 3"#, with: #""schema": 2"#))
    }

    @Test
    func `wrong mode is unexpectedPayload`() async throws {
        try await self.expectUnexpectedPayload(
            Self.replacing(#""mode": "equal_latest_3""#, with: #""mode": "latest_1""#))
    }

    @Test
    func `wrong benchmark is unexpectedPayload`() async throws {
        try await self.expectUnexpectedPayload(
            Self.replacing(#""benchmark_id": "deep-swe""#, with: #""benchmark_id": "pompeii-adjacency""#))
    }

    @Test
    func `missing schema is unexpectedPayload`() async throws {
        try await self.expectUnexpectedPayload(Self.replacing(#""schema": 3,"#, with: ""))
    }

    @Test
    func `empty points is unexpectedPayload`() async throws {
        try await self.expectUnexpectedPayload(Self.withPoints([]))
    }

    @Test
    func `only unknown targets is unexpectedPayload`() async throws {
        try await self.expectUnexpectedPayload(Self.onlyUnknownTargets())
    }

    @Test
    func `duplicate allowlist target is unexpectedPayload`() async throws {
        try await self.expectUnexpectedPayload(Self.duplicatingAllowlistPoint(
            model: "gpt-5.6-sol",
            effort: "xhigh"))
    }

    @Test
    func `present missing iq is unexpectedPayload`() async throws {
        try await self.expectUnexpectedPayload(Self.removingMetric(
            "iq",
            model: "gpt-5.6-sol",
            effort: "high"))
    }

    @Test
    func `present missing average_minutes is unexpectedPayload`() async throws {
        try await self.expectUnexpectedPayload(Self.removingMetric(
            "average_minutes",
            model: "gpt-5.6-sol",
            effort: "high"))
    }

    @Test
    func `present null iq is unexpectedPayload`() async throws {
        try await self.expectUnexpectedPayload(Self.settingMetric(
            NSNull(),
            key: "iq",
            model: "gpt-5.6-sol",
            effort: "high"))
    }

    @Test
    func `negative minutes is unexpectedPayload`() async throws {
        try await self.expectUnexpectedPayload(Self.settingMetric(
            -1,
            key: "average_minutes",
            model: "gpt-5.6-sol",
            effort: "high"))
    }

    @Test
    func `negative iq is unexpectedPayload`() async throws {
        try await self.expectUnexpectedPayload(Self.settingMetric(
            -0.1,
            key: "iq",
            model: "deepseek-v4-flash",
            effort: "max"))
    }

    @Test
    func `1e300 unrepresentable metric is unexpectedPayload`() async throws {
        try await self.expectUnexpectedPayload(Self.settingMetric(
            1e300,
            key: "iq",
            model: "gpt-5.6-sol",
            effort: "medium"))
    }

    @Test
    func `cancellation is not rewritten as invalidResponse`() async {
        let transport = ProviderHTTPTransportHandler { _ in
            try await Task.sleep(nanoseconds: 60_000_000_000)
            return try (Data(), Self.http(CodexRadarIntelligence.endpointURL, status: 200))
        }
        let task = Task {
            try await CodexRadarIntelligence.fetch(transport: transport)
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            return
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    private func expectUnexpectedPayload(_ body: Data) async {
        await #expect(throws: CodexRadarIntelligenceError.unexpectedPayload) {
            _ = try await self.fetch(body: body)
        }
    }

    private func fetch(body: Data) async throws -> CodexRadarIntelligenceSnapshot {
        let transport = ProviderHTTPTransportHandler { request in
            try (body, Self.http(request.url, status: 200))
        }
        return try await CodexRadarIntelligence.fetch(transport: transport)
    }

    private static func fixtureData() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "codexradar-intelligence-efficiency-schema3",
            withExtension: "json",
            subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private static func fixtureJSON() throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: self.fixtureData()) as? [String: Any])
    }

    private static func replacing(_ needle: String, with replacement: String) throws -> Data {
        let text = try #require(String(data: self.fixtureData(), encoding: .utf8))
        return try #require(text.replacingOccurrences(of: needle, with: replacement).data(using: .utf8))
    }

    private static func withPoints(_ points: [[String: Any]]) throws -> Data {
        var json = try self.fixtureJSON()
        json["points"] = points
        return try JSONSerialization.data(withJSONObject: json)
    }

    private static func onlyUnknownTargets() throws -> Data {
        try self.mutatingPoints { points in
            points.removeAll { Self.isAllowlisted($0) }
        }
    }

    private static func withoutAllowlistPoint(model: String, effort: String) throws -> Data {
        try self.mutatingPoints { points in
            points.removeAll { Self.matches($0, model: model, effort: effort) }
        }
    }

    private static func duplicatingAllowlistPoint(model: String, effort: String) throws -> Data {
        try self.mutatingPoints { points in
            if let first = points.first(where: { Self.matches($0, model: model, effort: effort) }) {
                points.append(first)
            }
        }
    }

    private static func removingMetric(_ key: String, model: String, effort: String) throws -> Data {
        try self.mutatingPoints { points in
            guard let index = points.firstIndex(where: { Self.matches($0, model: model, effort: effort) }) else {
                return
            }
            points[index].removeValue(forKey: key)
        }
    }

    private static func settingMetric(
        _ value: Any,
        key: String,
        model: String,
        effort: String) throws -> Data
    {
        try self.mutatingPoints { points in
            guard let index = points.firstIndex(where: { Self.matches($0, model: model, effort: effort) }) else {
                return
            }
            points[index][key] = value
        }
    }

    private static func mutatingPoints(_ mutate: (inout [[String: Any]]) -> Void) throws -> Data {
        var json = try self.fixtureJSON()
        var points = try #require(json["points"] as? [[String: Any]])
        mutate(&points)
        json["points"] = points
        return try JSONSerialization.data(withJSONObject: json)
    }

    private static func isAllowlisted(_ point: [String: Any]) -> Bool {
        CodexRadarIntelligenceTarget.allCases.contains {
            $0.model == point["model"] as? String && $0.effort == point["effort"] as? String
        }
    }

    private static func matches(_ point: [String: Any], model: String, effort: String) -> Bool {
        point["model"] as? String == model && point["effort"] as? String == effort
    }

    private static func http(
        _ url: URL?,
        status: Int,
        headers: [String: String] = ["Content-Type": "application/json"]) throws -> HTTPURLResponse
    {
        try #require(HTTPURLResponse(
            url: url ?? CodexRadarIntelligence.endpointURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers))
    }

    private static func sourceUpdatedAt(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}
