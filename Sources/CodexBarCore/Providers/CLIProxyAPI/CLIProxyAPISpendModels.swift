import Foundation

public enum CLIProxyAPISpendError: LocalizedError, Sendable, Equatable {
    case trackingDisabled
    case usageStatisticsDisabled
    case unreachable(String)
    case unauthorized
    case persistFailed(String)

    public var errorDescription: String? {
        switch self {
        case .trackingDisabled:
            "Spend tracking is off. Enable Track CLIProxyAPI spend in Providers. "
                + "This pops CLIProxyAPI usage-queue; do not also run CPA-Manager as a consumer."
        case .usageStatisticsDisabled:
            "CLIProxyAPI usage statistics are disabled. Set usage-statistics-enabled: true in the "
                + "CLIProxyAPI config (it defaults to false) and restart the proxy."
        case let .unreachable(base):
            "CLIProxyAPI is not reachable at \(base)."
        case .unauthorized:
            "CLIProxyAPI management key was rejected. Update the management key and retry."
        case let .persistFailed(message):
            "CLIProxyAPI spend store failed: \(message)"
        }
    }
}

public struct CLIProxyAPISpendTokenMix: Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheCreationTokens: Int?
    public var totalTokens: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheCreationTokens: Int? = nil,
        totalTokens: Int? = nil)
    {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.totalTokens = totalTokens
    }
}

public struct CLIProxyAPISpendEvent: Sendable, Equatable {
    public let requestID: String
    public let occurredAt: Date
    public let authIndex: String
    public let upstreamProvider: String
    public let model: String
    public let alias: String
    public let tokens: CLIProxyAPISpendTokenMix
    public let failed: Bool
    public let statusCode: Int?

    public init(
        requestID: String,
        occurredAt: Date,
        authIndex: String,
        upstreamProvider: String,
        model: String,
        alias: String,
        tokens: CLIProxyAPISpendTokenMix,
        failed: Bool,
        statusCode: Int?)
    {
        self.requestID = requestID
        self.occurredAt = occurredAt
        self.authIndex = authIndex
        self.upstreamProvider = upstreamProvider
        self.model = model
        self.alias = alias
        self.tokens = tokens
        self.failed = failed
        self.statusCode = statusCode
    }

    public var dedupeKey: String {
        let trimmed = self.requestID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return "\(self.occurredAt.timeIntervalSince1970)|\(self.authIndex)|\(self.model)"
    }
}

public enum CLIProxyAPISpendQueueDecoder {
    public static func events(from data: Data) throws -> (events: [CLIProxyAPISpendEvent], skipped: Int) {
        let root = try JSONSerialization.jsonObject(with: data)
        let records: [[String: Any]]
        if let array = root as? [[String: Any]] {
            records = array
        } else if let array = root as? [Any] {
            records = array.compactMap { $0 as? [String: Any] }
        } else {
            throw CLIProxyAPIError.decodeFailed("usage-queue did not return a JSON array.")
        }

        var events: [CLIProxyAPISpendEvent] = []
        var skipped = 0
        for record in records {
            if let event = self.event(from: record) {
                events.append(event)
            } else {
                skipped += 1
            }
        }
        return (events, skipped)
    }

    public static func containsRawAPIKey(_ data: Data, secret: String) -> Bool {
        guard !secret.isEmpty, let body = String(data: data, encoding: .utf8) else { return false }
        return body.contains(secret)
    }

    private static func event(from record: [String: Any]) -> CLIProxyAPISpendEvent? {
        let timestamp = self.date(record["timestamp"])
        guard let occurredAt = timestamp else { return nil }
        let requestID = self.string(record["request_id"]) ?? ""
        let authIndex = self.string(record["auth_index"]) ?? ""
        let provider = self.nonEmpty(self.string(record["provider"])) ?? "unknown"
        let model = self.nonEmpty(self.string(record["model"])) ?? "unknown"
        let alias = self.nonEmpty(self.string(record["alias"])) ?? model
        let tokensObject = record["tokens"] as? [String: Any] ?? [:]
        let failObject = record["fail"] as? [String: Any] ?? [:]
        let tokens = CLIProxyAPISpendTokenMix(
            inputTokens: self.int(tokensObject["input_tokens"]),
            outputTokens: self.int(tokensObject["output_tokens"]),
            reasoningTokens: self.int(tokensObject["reasoning_tokens"]),
            cacheReadTokens: self.int(tokensObject["cache_read_tokens"]) ?? self.int(tokensObject["cached_tokens"]),
            cacheCreationTokens: self.int(tokensObject["cache_creation_tokens"]),
            totalTokens: self.int(tokensObject["total_tokens"]))
        return CLIProxyAPISpendEvent(
            requestID: requestID,
            occurredAt: occurredAt,
            authIndex: authIndex,
            upstreamProvider: provider,
            model: model,
            alias: alias,
            tokens: tokens,
            failed: self.bool(record["failed"]),
            statusCode: self.int(failObject["status_code"]))
    }

    private static func string(_ raw: Any?) -> String? {
        if let value = raw as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    private static func bool(_ raw: Any?) -> Bool {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        if let value = raw as? String { return ["1", "true", "yes"].contains(value.lowercased()) }
        return false
    }

    private static func int(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Int64 { return Int(value) }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String, let parsed = Int(value) { return parsed }
        return nil
    }

    private static func date(_ raw: Any?) -> Date? {
        if let value = raw as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) { return date }
            let basic = ISO8601DateFormatter()
            basic.formatOptions = [.withInternetDateTime]
            if let date = basic.date(from: value) { return date }
            if let interval = Double(value) {
                return Date(timeIntervalSince1970: interval > 10_000_000_000 ? interval / 1_000 : interval)
            }
            return nil
        }
        if let value = raw as? Double {
            return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
        }
        if let value = raw as? Int {
            let interval = Double(value)
            return Date(timeIntervalSince1970: interval > 10_000_000_000 ? interval / 1_000 : interval)
        }
        if let value = raw as? NSNumber {
            let interval = value.doubleValue
            return Date(timeIntervalSince1970: interval > 10_000_000_000 ? interval / 1_000 : interval)
        }
        return nil
    }
}

public enum CLIProxyAPIUsageStatisticsFlagDecoder {
    public static func enabled(from data: Data) throws -> Bool {
        let root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        if let value = root as? Bool {
            return value
        }
        if let value = root as? NSNumber {
            return value.boolValue
        }
        if let object = root as? [String: Any] {
            for key in ["enabled", "usage-statistics-enabled", "usage_statistics_enabled", "value"] {
                if let value = object[key] as? Bool { return value }
                if let value = object[key] as? NSNumber { return value.boolValue }
            }
        }
        throw CLIProxyAPIError.decodeFailed("usage-statistics-enabled response was not a boolean.")
    }
}
