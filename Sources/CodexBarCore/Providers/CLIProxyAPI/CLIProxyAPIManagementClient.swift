import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CLIProxyAPIError: LocalizedError, Sendable {
    case invalidURL
    case missingAuth(String?)
    case managementRequestFailed(Int, String?)
    case apiCallFailed(Int, String?)
    case decodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "CLIProxyAPI management URL is invalid."
        case let .missingAuth(authIndex):
            if let authIndex, !authIndex.isEmpty {
                "CLIProxyAPI did not find auth_index \(authIndex) among Codex/Gemini/Antigravity/Grok credentials."
            } else {
                "CLIProxyAPI has no available Codex, Gemini, Antigravity, or Grok auth entry."
            }
        case let .managementRequestFailed(status, message):
            if let message, !message.isEmpty {
                "CLIProxyAPI management API failed (\(status)): \(message)"
            } else {
                "CLIProxyAPI management API failed (\(status))."
            }
        case let .apiCallFailed(status, message):
            if let message, !message.isEmpty {
                "CLIProxyAPI api-call failed (\(status)): \(message)"
            } else {
                "CLIProxyAPI api-call failed (\(status))."
            }
        case let .decodeFailed(message):
            "Failed to decode CLIProxyAPI response: \(message)"
        }
    }
}

public enum CLIProxyAPIAuthKind: String, Sendable {
    case codex
    case gemini
    case antigravity
    case grok

    var displayName: String {
        // Provider-specific by design: these cases are CLIProxyAPI auth kinds, not CodexBar provider IDs.
        switch self {
        case .codex: "Codex"
        case .gemini: "Gemini"
        case .antigravity: "Antigravity"
        case .grok: "Grok"
        }
    }

    fileprivate var matchingValues: Set<String> {
        // Provider-specific by design: CLIProxyAPI oauth aliases reuse Codex/Gemini/Antigravity/Grok/xAI names.
        switch self {
        case .codex: ["codex"]
        case .gemini: ["gemini", "gemini-cli"]
        case .antigravity: ["antigravity"]
        case .grok: ["xai", "grok", "x-ai", "x.ai"]
        }
    }

    fileprivate func matches(provider: String?, type: String?) -> Bool {
        let normalizedProvider = provider?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedType = type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return self.matchingValues.contains(normalizedProvider) || self.matchingValues.contains(normalizedType)
    }
}

public struct CLIProxyAPIResolvedAuth: Sendable, Equatable {
    public let kind: CLIProxyAPIAuthKind
    public let authIndex: String
    public let email: String?
    public let chatGPTAccountID: String?
    public let planType: String?
}

public struct CLIProxyAPIGeminiQuotaBucket: Sendable, Equatable {
    public let modelID: String
    public let remainingFraction: Double
    public let resetTime: Date?
}

public struct CLIProxyAPIGeminiQuotaResponse: Sendable, Equatable {
    public let buckets: [CLIProxyAPIGeminiQuotaBucket]
}

public struct CLIProxyAPIManagementClient: Sendable {
    public static let maxAccountsPerRefresh = 12
    private static let geminiQuotaURL = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
    private static let geminiLoadCodeAssistURL = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private static let geminiFallbackProjectID = "just-well-nxk81"
    private static let geminiHeaders = [
        "Authorization": "Bearer $TOKEN$",
        "Content-Type": "application/json",
        "User-Agent": "google-api-nodejs-client/9.15.1",
        "X-Goog-Api-Client": "gl-node/22.17.0",
        "Client-Metadata": "ideType=IDE_UNSPECIFIED,platform=PLATFORM_UNSPECIFIED,pluginType=GEMINI",
    ]
    private static let codexUsageURL = "https://chatgpt.com/backend-api/wham/usage"
    private static let codexUserAgent =
        "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal"
    private static let grokHeaders = [
        "Authorization": "Bearer $TOKEN$",
        "x-xai-token-auth": "xai-grok-cli",
        "x-grok-client-version": "0.2.91",
        "Accept": "*/*",
        "User-Agent": "grok-pager/0.2.91 grok-shell/0.2.91 (macos; aarch64)",
    ]

    public let settings: CLIProxyAPISettings
    private let transport: any ProviderHTTPTransport

    public init(
        settings: CLIProxyAPISettings,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared)
    {
        self.settings = settings
        self.transport = transport
    }

    public struct UsageQueuePage: Sendable, Equatable {
        public let events: [CLIProxyAPISpendEvent]
        public let skipped: Int
        public let rawBody: Data

        public init(events: [CLIProxyAPISpendEvent], skipped: Int, rawBody: Data) {
            self.events = events
            self.skipped = skipped
            self.rawBody = rawBody
        }
    }

    public func usageStatisticsEnabled() async throws -> Bool {
        let (data, statusCode) = try await self.request(
            path: "usage-statistics-enabled",
            method: "GET",
            body: nil)
        try self.throwIfManagementFailed(statusCode: statusCode, data: data)
        return try CLIProxyAPIUsageStatisticsFlagDecoder.enabled(from: data)
    }

    public func popUsageQueue(count: Int = CLIProxyAPISpendCollector.defaultPageSize) async throws -> UsageQueuePage {
        let clamped = max(2, count)
        let (data, statusCode) = try await self.request(
            path: "usage-queue",
            method: "GET",
            queryItems: [URLQueryItem(name: "count", value: String(clamped))],
            body: nil)
        try self.throwIfManagementFailed(statusCode: statusCode, data: data)
        let decoded = try CLIProxyAPISpendQueueDecoder.events(from: data)
        return UsageQueuePage(events: decoded.events, skipped: decoded.skipped, rawBody: data)
    }

    public func listAuths() async throws -> [CLIProxyAPIResolvedAuth] {
        let response = try await self.fetchAuthFiles()
        let mapped = response.files.compactMap { self.mapResolvedAuth($0) }
        let enabled = mapped.filter { auth in
            response.files.first { $0.authIndex == auth.authIndex }?.disabled != true
        }
        let pool = enabled.isEmpty ? mapped : enabled
        let preferred = self.settings.authIndex
        if let preferred, !preferred.isEmpty {
            let matched = pool.filter { $0.authIndex == preferred }
            guard !matched.isEmpty else { throw CLIProxyAPIError.missingAuth(preferred) }
            return matched
        }
        let sorted = pool.sorted { lhs, rhs in
            let left = lhs.email?.lowercased() ?? lhs.authIndex.lowercased()
            let right = rhs.email?.lowercased() ?? rhs.authIndex.lowercased()
            if left == right { return lhs.authIndex < rhs.authIndex }
            return left < right
        }
        return Array(sorted.prefix(Self.maxAccountsPerRefresh))
    }

    public func fetchCodexUsage(auth: CLIProxyAPIResolvedAuth) async throws -> CodexUsageResponse {
        var headers = [
            "Authorization": "Bearer $TOKEN$",
            "Accept": "application/json",
            "User-Agent": Self.codexUserAgent,
        ]
        if let accountID = auth.chatGPTAccountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }
        let payload = try await self.apiCall(
            authIndex: auth.authIndex,
            method: "GET",
            url: Self.codexUsageURL,
            header: headers,
            data: nil)
        do {
            return try JSONDecoder().decode(CodexUsageResponse.self, from: payload)
        } catch {
            throw CLIProxyAPIError.decodeFailed(error.localizedDescription)
        }
    }

    public func fetchGeminiLikeQuota(auth: CLIProxyAPIResolvedAuth) async throws -> CLIProxyAPIGeminiQuotaResponse {
        let projectID = await self.resolveGeminiProjectID(auth: auth) ?? Self.geminiFallbackProjectID
        let payload = try await self.fetchGeminiLikeQuota(auth: auth, projectID: projectID)
        if !payload.buckets.isEmpty { return payload }
        if projectID != Self.geminiFallbackProjectID {
            return try await self.fetchGeminiLikeQuota(auth: auth, projectID: Self.geminiFallbackProjectID)
        }
        return payload
    }

    public func fetchGrokUsage(auth: CLIProxyAPIResolvedAuth) async throws -> GrokWebBillingSnapshot {
        let payload = try await self.apiCall(
            authIndex: auth.authIndex,
            method: "GET",
            url: GrokCreditsProxyFetcher.defaultEndpoint.absoluteString,
            header: Self.grokHeaders,
            data: nil)
        do {
            return try GrokCreditsProxyFetcher.parseSnapshot(payload)
        } catch {
            throw CLIProxyAPIError.decodeFailed(error.localizedDescription)
        }
    }

    public static func managementURL(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem] = []) -> URL?
    {
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        var normalized = baseURL
        let existing = normalized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        if !existing.hasSuffix("v0/management") {
            normalized.appendPathComponent("v0", isDirectory: false)
            normalized.appendPathComponent("management", isDirectory: false)
        }
        let withPath = normalized.appendingPathComponent(trimmedPath)
        guard !queryItems.isEmpty else { return withPath }
        guard var components = URLComponents(url: withPath, resolvingAgainstBaseURL: false) else {
            return withPath
        }
        components.queryItems = queryItems
        return components.url
    }

    private func fetchGeminiLikeQuota(
        auth: CLIProxyAPIResolvedAuth,
        projectID: String) async throws -> CLIProxyAPIGeminiQuotaResponse
    {
        let requestData = try JSONEncoder().encode(GeminiQuotaRequestPayload(project: projectID))
        guard let requestString = String(data: requestData, encoding: .utf8) else {
            throw CLIProxyAPIError.decodeFailed("Could not encode Gemini quota request.")
        }
        let payload = try await self.apiCall(
            authIndex: auth.authIndex,
            method: "POST",
            url: Self.geminiQuotaURL,
            header: Self.geminiHeaders,
            data: requestString)
        do {
            let decoded = try JSONDecoder().decode(GeminiQuotaResponsePayload.self, from: payload)
            let buckets = decoded.buckets.compactMap { bucket -> CLIProxyAPIGeminiQuotaBucket? in
                guard let modelID = bucket.modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !modelID.isEmpty,
                      let remainingFraction = bucket.remainingFraction
                else {
                    return nil
                }
                return CLIProxyAPIGeminiQuotaBucket(
                    modelID: modelID,
                    remainingFraction: remainingFraction,
                    resetTime: Self.parseGeminiResetDate(bucket.resetTime))
            }
            return CLIProxyAPIGeminiQuotaResponse(buckets: buckets)
        } catch {
            throw CLIProxyAPIError.decodeFailed(error.localizedDescription)
        }
    }

    private func resolveGeminiProjectID(auth: CLIProxyAPIResolvedAuth) async -> String? {
        guard let payload = try? await self.apiCall(
            authIndex: auth.authIndex,
            method: "POST",
            url: Self.geminiLoadCodeAssistURL,
            header: Self.geminiHeaders,
            data: "{}"),
            let raw = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else {
            return nil
        }

        if let project = raw["cloudaicompanionProject"] as? String {
            let normalized = project.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
        if let project = raw["cloudaicompanionProject"] as? [String: Any] {
            for key in ["id", "projectId"] {
                if let value = project[key] as? String {
                    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !normalized.isEmpty { return normalized }
                }
            }
        }
        return nil
    }

    private func fetchAuthFiles() async throws -> AuthFilesResponse {
        let (data, statusCode) = try await self.request(path: "auth-files", method: "GET", body: nil)
        guard (200..<300).contains(statusCode) else {
            throw CLIProxyAPIError.managementRequestFailed(
                statusCode,
                String(data: data, encoding: .utf8))
        }
        do {
            return try JSONDecoder().decode(AuthFilesResponse.self, from: data)
        } catch {
            throw CLIProxyAPIError.decodeFailed(error.localizedDescription)
        }
    }

    private func apiCall(
        authIndex: String,
        method: String,
        url: String,
        header: [String: String],
        data: String?) async throws -> Data
    {
        let body = APICallRequest(
            authIndex: authIndex,
            method: method,
            url: url,
            header: header,
            data: data)
        let encoded = try JSONEncoder().encode(body)
        let (responseData, statusCode) = try await self.request(path: "api-call", method: "POST", body: encoded)
        guard (200..<300).contains(statusCode) else {
            throw CLIProxyAPIError.managementRequestFailed(
                statusCode,
                String(data: responseData, encoding: .utf8))
        }
        let callResponse: APICallResponse
        do {
            callResponse = try JSONDecoder().decode(APICallResponse.self, from: responseData)
        } catch {
            throw CLIProxyAPIError.decodeFailed(error.localizedDescription)
        }
        guard (200..<300).contains(callResponse.statusCode) else {
            throw CLIProxyAPIError.apiCallFailed(callResponse.statusCode, callResponse.compactBody)
        }
        guard let bodyString = callResponse.body else {
            throw CLIProxyAPIError.decodeFailed("api-call returned an empty body.")
        }
        return Data(bodyString.utf8)
    }

    private func request(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        body: Data?) async throws -> (Data, Int)
    {
        guard let url = Self.managementURL(baseURL: self.settings.baseURL, path: path, queryItems: queryItems) else {
            throw CLIProxyAPIError.invalidURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(self.settings.managementKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let response = try await self.transport.response(for: request)
        return (response.data, response.statusCode)
    }

    private func throwIfManagementFailed(statusCode: Int, data: Data) throws {
        if statusCode == 401 || statusCode == 403 {
            throw CLIProxyAPISpendError.unauthorized
        }
        guard (200..<300).contains(statusCode) else {
            throw CLIProxyAPIError.managementRequestFailed(
                statusCode,
                String(data: data, encoding: .utf8))
        }
    }

    private func mapResolvedAuth(_ auth: AuthFileEntry) -> CLIProxyAPIResolvedAuth? {
        let authIndex = auth.authIndex?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !authIndex.isEmpty else { return nil }
        let kind: CLIProxyAPIAuthKind
        // Provider-specific by design: CLIProxyAPI auth types share Codex/Gemini/Antigravity/Grok names.
        if CLIProxyAPIAuthKind.codex.matches(provider: auth.provider, type: auth.type) {
            kind = .codex
        } else if CLIProxyAPIAuthKind.gemini.matches(provider: auth.provider, type: auth.type) {
            kind = .gemini
        } else if CLIProxyAPIAuthKind.antigravity.matches(provider: auth.provider, type: auth.type) {
            kind = .antigravity
        } else if CLIProxyAPIAuthKind.grok.matches(provider: auth.provider, type: auth.type) {
            kind = .grok
        } else {
            return nil
        }
        return CLIProxyAPIResolvedAuth(
            kind: kind,
            authIndex: authIndex,
            email: Self.cleaned(auth.email),
            chatGPTAccountID: Self.cleaned(auth.idToken?.chatGPTAccountID),
            planType: Self.cleaned(auth.idToken?.planType))
    }

    private static func parseGeminiResetDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }

    private static func cleaned(_ raw: String?) -> String? {
        CLIProxyAPISettingsReader.cleaned(raw)
    }
}

private struct AuthFilesResponse: Decodable {
    let files: [AuthFileEntry]
}

private struct AuthFileEntry: Decodable {
    let authIndex: String?
    let type: String?
    let provider: String?
    let email: String?
    let disabled: Bool?
    let idToken: IDTokenClaims?

    enum CodingKeys: String, CodingKey {
        case authIndex = "auth_index"
        case type
        case provider
        case email
        case disabled
        case idToken = "id_token"
    }
}

private struct IDTokenClaims: Decodable {
    let chatGPTAccountID: String?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case chatGPTAccountID = "chatgpt_account_id"
        case planType = "plan_type"
    }
}

private struct APICallRequest: Encodable {
    let authIndex: String
    let method: String
    let url: String
    let header: [String: String]
    let data: String?

    enum CodingKeys: String, CodingKey {
        case authIndex = "auth_index"
        case method
        case url
        case header
        case data
    }
}

private struct APICallResponse: Decodable {
    let statusCode: Int
    let body: String?

    enum CodingKeys: String, CodingKey {
        case statusCode = "status_code"
        case body
    }

    var compactBody: String? {
        guard let body else { return nil }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 320 ? String(trimmed.prefix(320)) + "…" : trimmed
    }
}

private struct GeminiQuotaRequestPayload: Encodable {
    let project: String
}

private struct GeminiQuotaResponsePayload: Decodable {
    let buckets: [GeminiQuotaBucketPayload]
}

private struct GeminiQuotaBucketPayload: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
    let modelID: String?

    enum CodingKeys: String, CodingKey {
        case remainingFraction
        case resetTime
        case modelID = "modelId"
    }
}
