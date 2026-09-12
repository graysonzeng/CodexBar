import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CodexRadarIntelligenceTarget: CaseIterable, Hashable, Sendable {
    case gpt56SolXhigh
    case gpt56SolHigh
    case gpt56SolMedium
    case deepseekV4FlashMax
    case deepseekV4ProMax

    public var model: String {
        switch self {
        case .gpt56SolXhigh, .gpt56SolHigh, .gpt56SolMedium:
            "gpt-5.6-sol"
        case .deepseekV4FlashMax:
            "deepseek-v4-flash"
        case .deepseekV4ProMax:
            "deepseek-v4-pro"
        }
    }

    public var effort: String {
        switch self {
        case .gpt56SolXhigh:
            "xhigh"
        case .gpt56SolHigh:
            "high"
        case .gpt56SolMedium:
            "medium"
        case .deepseekV4FlashMax, .deepseekV4ProMax:
            "max"
        }
    }

    static func allowlisted(model: String, effort: String) -> Self? {
        self.allCases.first { $0.model == model && $0.effort == effort }
    }
}

public struct CodexRadarIntelligencePoint: Equatable, Sendable {
    public let target: CodexRadarIntelligenceTarget
    public let iq: Double?
    public let averageMinutes: Double?

    public init(target: CodexRadarIntelligenceTarget, iq: Double?, averageMinutes: Double?) {
        self.target = target
        self.iq = iq
        self.averageMinutes = averageMinutes
    }
}

public struct CodexRadarIntelligenceSnapshot: Equatable, Sendable {
    public let points: [CodexRadarIntelligencePoint]
    public let sourceUpdatedAt: Date?

    public init(points: [CodexRadarIntelligencePoint], sourceUpdatedAt: Date? = nil) {
        let byTarget = Dictionary(points.map { ($0.target, $0) }, uniquingKeysWith: { _, last in last })
        self.points = CodexRadarIntelligenceTarget.allCases.map { target in
            byTarget[target] ?? CodexRadarIntelligencePoint(target: target, iq: nil, averageMinutes: nil)
        }
        self.sourceUpdatedAt = sourceUpdatedAt
    }

    public func point(for target: CodexRadarIntelligenceTarget) -> CodexRadarIntelligencePoint {
        self.points.first { $0.target == target }
            ?? CodexRadarIntelligencePoint(target: target, iq: nil, averageMinutes: nil)
    }
}

public enum CodexRadarIntelligenceError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case invalidJSON
    case unexpectedPayload
}

public enum CodexRadarIntelligence {
    public static let endpointURL = URL(
        string: "https://api.codexradar.com/api/v1/intelligence-efficiency?benchmark=deep-swe")!

    public static func roundedDisplayInt(_ value: Double) -> Int? {
        let rounded = floor(value + 0.5)
        guard rounded.isFinite,
              rounded >= Double(Int.min),
              rounded < Double(Int.max)
        else { return nil }
        return Int(rounded)
    }

    public static func fetch(
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared)
        async throws -> CodexRadarIntelligenceSnapshot
    {
        var request = URLRequest(url: self.endpointURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: ProviderHTTPResponse
        do {
            response = try await transport.response(
                for: request,
                retryPolicy: .transientIdempotent)
        } catch {
            if error is CancellationError { throw error }
            if (error as? URLError)?.code == .cancelled { throw error }
            throw CodexRadarIntelligenceError.invalidResponse
        }

        guard (200..<300).contains(response.statusCode) else {
            throw CodexRadarIntelligenceError.httpStatus(response.statusCode)
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: response.data)
        } catch {
            throw CodexRadarIntelligenceError.invalidJSON
        }

        return try self.snapshot(from: payload)
    }

    private static func snapshot(from payload: Payload) throws -> CodexRadarIntelligenceSnapshot {
        guard payload.schema == 3,
              payload.mode == "equal_latest_3",
              payload.benchmarkId == "deep-swe"
        else {
            throw CodexRadarIntelligenceError.unexpectedPayload
        }

        var present: [CodexRadarIntelligenceTarget: Payload.Point] = [:]
        for point in payload.points ?? [] {
            guard let model = point.model,
                  let effort = point.effort,
                  let target = CodexRadarIntelligenceTarget.allowlisted(model: model, effort: effort)
            else {
                continue
            }
            if present[target] != nil {
                throw CodexRadarIntelligenceError.unexpectedPayload
            }
            present[target] = point
        }

        guard !present.isEmpty else {
            throw CodexRadarIntelligenceError.unexpectedPayload
        }

        return try CodexRadarIntelligenceSnapshot(
            points: CodexRadarIntelligenceTarget.allCases.map { target in
                guard let point = present[target] else {
                    return CodexRadarIntelligencePoint(target: target, iq: nil, averageMinutes: nil)
                }
                return try self.validatedPoint(target: target, point: point)
            },
            sourceUpdatedAt: self.parseSourceUpdatedAt(payload.sourceUpdatedAt))
    }

    private static func parseSourceUpdatedAt(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    private static func validatedPoint(
        target: CodexRadarIntelligenceTarget,
        point: Payload.Point) throws -> CodexRadarIntelligencePoint
    {
        guard let iq = point.iq, let averageMinutes = point.averageMinutes else {
            throw CodexRadarIntelligenceError.unexpectedPayload
        }
        guard self.isRepresentableMetric(iq), self.isRepresentableMetric(averageMinutes) else {
            throw CodexRadarIntelligenceError.unexpectedPayload
        }
        return CodexRadarIntelligencePoint(target: target, iq: iq, averageMinutes: averageMinutes)
    }

    private static func isRepresentableMetric(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && self.roundedDisplayInt(value) != nil
    }

    private struct Payload: Decodable {
        struct Point: Decodable {
            let model: String?
            let effort: String?
            let iq: Double?
            let averageMinutes: Double?
            let sourceUpdatedAt: String?

            enum CodingKeys: String, CodingKey {
                case model
                case effort
                case iq
                case averageMinutes = "average_minutes"
                case sourceUpdatedAt = "source_updated_at"
            }
        }

        let schema: Int?
        let mode: String?
        let benchmarkId: String?
        let sourceUpdatedAt: String?
        let points: [Point]?

        enum CodingKeys: String, CodingKey {
            case schema
            case mode
            case benchmarkId = "benchmark_id"
            case sourceUpdatedAt = "source_updated_at"
            case points
        }
    }
}
