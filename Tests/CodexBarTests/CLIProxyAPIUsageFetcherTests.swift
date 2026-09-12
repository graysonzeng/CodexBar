import CodexBarCore
import Foundation
import Testing

struct CLIProxyAPIUsageFetcherTests {
    @Test
    func `management URL accepts root or already-versioned bases`() throws {
        #expect(
            try CLIProxyAPIManagementClient.managementURL(
                baseURL: #require(URL(string: "http://127.0.0.1:8317")),
                path: "auth-files")?
                .absoluteString == "http://127.0.0.1:8317/v0/management/auth-files")
        #expect(
            try CLIProxyAPIManagementClient.managementURL(
                baseURL: #require(URL(string: "http://127.0.0.1:8317/v0/management")),
                path: "api-call")?
                .absoluteString == "http://127.0.0.1:8317/v0/management/api-call")
    }

    @Test
    func `settings default to loopback and require a management key`() throws {
        #expect(CLIProxyAPISettingsReader.apiKey(environment: [:]) == nil)
        #expect(CLIProxyAPISettingsReader.baseURL(environment: [:]) == CLIProxyAPISettingsReader.defaultBaseURL)
        #expect(throws: CLIProxyAPISettingsError.missingManagementKey) {
            try CLIProxyAPISettingsReader.resolve(environment: [:])
        }
        let settings = try CLIProxyAPISettingsReader.resolve(environment: [
            "CLIPROXYAPI_MANAGEMENT_KEY": "secret",
            "CLIPROXYAPI_AUTH_INDEX": "idx-1",
        ])
        #expect(settings.managementKey == "secret")
        #expect(settings.authIndex == "idx-1")
        #expect(settings.baseURL == CLIProxyAPISettingsReader.defaultBaseURL)
    }

    @Test
    func `aggregates Codex Antigravity and Grok quota from management api-call`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            try Self.response(for: request)
        }
        let settings = try CLIProxyAPISettings(
            baseURL: #require(URL(string: "http://127.0.0.1:8317")),
            managementKey: "secret",
            authIndex: nil)
        let snapshot = try await CLIProxyAPIUsageFetcher.fetchUsage(
            settings: settings,
            transport: transport,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(snapshot.identity?.providerID == UsageProvider.cliproxyapi.instanceID)
        #expect(snapshot.identity?.accountOrganization == "3 accounts")
        #expect(snapshot.primary?.usedPercent == 80)
        #expect(snapshot.extraRateWindows?.count == 3)
        #expect(snapshot.extraRateWindows?.map(\.title) == [
            "Antigravity",
            "Codex",
            "Grok",
        ])
        #expect(snapshot.extraRateWindows?.last?.window.usedPercent == 25)
    }

    @Test
    func `auth_index filter keeps a single credential`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            try Self.response(for: request)
        }
        let settings = try CLIProxyAPISettings(
            baseURL: #require(URL(string: "http://127.0.0.1:8317")),
            managementKey: "secret",
            authIndex: "idx-codex")
        let snapshot = try await CLIProxyAPIUsageFetcher.fetchUsage(
            settings: settings,
            transport: transport,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(snapshot.identity?.accountEmail == "codex@example.com")
        #expect(snapshot.extraRateWindows?.count == 1)
        #expect(snapshot.primary?.usedPercent == 40)
    }

    @Test
    func `maps xAI auth files onto Grok weekly credits`() async throws {
        let transport = ProviderHTTPTransportHandler { request in
            try Self.response(for: request)
        }
        let settings = try CLIProxyAPISettings(
            baseURL: #require(URL(string: "http://127.0.0.1:8317")),
            managementKey: "secret",
            authIndex: "idx-grok")
        let snapshot = try await CLIProxyAPIUsageFetcher.fetchUsage(
            settings: settings,
            transport: transport,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(snapshot.identity?.accountEmail == "grok@example.com")
        #expect(snapshot.extraRateWindows?.map(\.title) == ["Grok"])
        #expect(snapshot.primary?.usedPercent == 25)
        #expect(snapshot.primary?.windowMinutes == 7 * 24 * 60)
    }

    private static func response(for request: URLRequest) throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        let path = url.path
        if path.hasSuffix("/auth-files") {
            return try self.http(Self.authFilesJSON)
        }
        if path.hasSuffix("/api-call") {
            let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if body.contains("chatgpt.com") {
                return try self.http(Self.apiCallJSON(Self.codexUsageJSON))
            }
            if body.contains("cli-chat-proxy.grok.com") {
                return try self.http(Self.apiCallJSON(Self.grokCreditsJSON))
            }
            if body.contains("retrieveUserQuota") {
                return try self.http(Self.apiCallJSON(Self.geminiQuotaJSON))
            }
            if body.contains("loadCodeAssist") {
                return try self.http(Self.apiCallJSON(#"{"cloudaicompanionProject":"proj-1"}"#))
            }
            return try self.http(#"{"status_code":404,"body":"missing"}"#)
        }
        throw URLError(.badURL)
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

    private static func apiCallJSON(_ upstream: String) throws -> String {
        let payload: [String: Any] = ["status_code": 200, "body": upstream]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try #require(String(bytes: data, encoding: .utf8))
    }

    private static let authFilesJSON = """
    {
      "files": [
        {
          "auth_index": "idx-codex",
          "type": "codex",
          "provider": "codex",
          "email": "codex@example.com",
          "disabled": false,
          "id_token": { "chatgpt_account_id": "acct-1", "plan_type": "plus" }
        },
        {
          "auth_index": "idx-ag",
          "type": "antigravity",
          "provider": "antigravity",
          "email": "ag@example.com",
          "disabled": false
        },
        {
          "auth_index": "idx-grok",
          "type": "xai",
          "provider": "xai",
          "email": "grok@example.com",
          "disabled": false
        },
        {
          "auth_index": "idx-copilot",
          "type": "github-copilot",
          "provider": "github-copilot",
          "email": "skip@example.com",
          "disabled": false
        }
      ]
    }
    """

    private static let codexUsageJSON = """
    {
      "plan_type": "plus",
      "rate_limit": {
        "primary_window": {
          "used_percent": 40,
          "reset_at": 1800000000,
          "limit_window_seconds": 18000
        },
        "secondary_window": {
          "used_percent": 10,
          "reset_at": 1800500000,
          "limit_window_seconds": 604800
        }
      }
    }
    """

    private static let grokCreditsJSON = """
    {
      "config": {
        "creditUsagePercent": 25,
        "currentPeriod": {
          "type": "USAGE_PERIOD_TYPE_WEEKLY",
          "end": "2026-08-25T00:00:00Z"
        }
      }
    }
    """

    private static let geminiQuotaJSON = """
    {
      "buckets": [
        { "modelId": "gemini-3-pro", "remainingFraction": 0.2, "resetTime": "2026-08-19T00:00:00Z" },
        { "modelId": "gemini-3-flash", "remainingFraction": 0.9, "resetTime": "2026-08-19T12:00:00Z" }
      ]
    }
    """
}
