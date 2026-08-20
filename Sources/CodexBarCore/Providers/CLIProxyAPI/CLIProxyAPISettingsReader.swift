import Foundation

public enum CLIProxyAPISettingsError: LocalizedError, Equatable, Sendable {
    case missingManagementKey
    case invalidEndpointOverride(String)

    public var errorDescription: String? {
        switch self {
        case .missingManagementKey:
            "Missing CLIProxyAPI management key. Set apiKey in ~/.codexbar/config.json or CLIPROXYAPI_MANAGEMENT_KEY."
        case let .invalidEndpointOverride(key):
            "CLIProxyAPI base URL override \(key) is invalid. Use an HTTPS URL, or plain HTTP for "
                + "loopback or private-network addresses and .local hosts, without embedded credentials."
        }
    }
}

public struct CLIProxyAPISettings: Sendable, Equatable {
    public let baseURL: URL
    public let managementKey: String
    public let authIndex: String?

    public init(baseURL: URL, managementKey: String, authIndex: String?) {
        self.baseURL = baseURL
        self.managementKey = managementKey
        self.authIndex = authIndex
    }
}

public enum CLIProxyAPISettingsReader {
    public static let apiKeyEnvironmentKey = "CLIPROXYAPI_MANAGEMENT_KEY"
    public static let baseURLEnvironmentKey = "CLIPROXYAPI_BASE_URL"
    public static let authIndexEnvironmentKey = "CLIPROXYAPI_AUTH_INDEX"
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:8317")!

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.apiKeyEnvironmentKey])
    }

    public static func authIndex(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String?
    {
        self.cleaned(environment[self.authIndexEnvironmentKey])
    }

    public static func hasBaseURLOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool
    {
        self.cleaned(environment[self.baseURLEnvironmentKey]) != nil
    }

    public static func baseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL?
    {
        guard let raw = self.cleaned(environment[self.baseURLEnvironmentKey]) else {
            return self.defaultBaseURL
        }
        return ProviderEndpointOverrideValidator().validatedURLAllowingPrivateNetworkHTTP(raw)
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> CLIProxyAPISettings
    {
        guard let managementKey = self.apiKey(environment: environment) else {
            throw CLIProxyAPISettingsError.missingManagementKey
        }
        guard let baseURL = self.baseURL(environment: environment) else {
            throw CLIProxyAPISettingsError.invalidEndpointOverride(self.baseURLEnvironmentKey)
        }
        return CLIProxyAPISettings(
            baseURL: baseURL,
            managementKey: managementKey,
            authIndex: self.authIndex(environment: environment))
    }

    public static func validateEndpointOverride(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws
    {
        guard self.hasBaseURLOverride(environment: environment) else { return }
        guard self.baseURL(environment: environment) != nil else {
            throw CLIProxyAPISettingsError.invalidEndpointOverride(self.baseURLEnvironmentKey)
        }
    }

    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
