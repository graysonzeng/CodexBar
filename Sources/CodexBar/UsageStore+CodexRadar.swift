import CodexBarCore
import Foundation

@MainActor
extension UsageStore {
    private static let codexRadarSuccessTTL: TimeInterval = 5 * 60
    private static let codexRadarFailureRetryInterval: TimeInterval = 60

    func scheduleCodexRadarIntelligenceRefresh(force: Bool = false, now: Date = Date()) {
        _ = self.startCodexRadarIntelligenceRefresh(force: force, now: now)
    }

    func refreshCodexRadarIntelligence(force: Bool = false, now: Date = Date()) async {
        if let task = self.startCodexRadarIntelligenceRefresh(force: force, now: now) {
            await task.value
        }
    }

    func cancelCodexRadarIntelligence() {
        self.codexRadarGeneration &+= 1
        self.codexRadarTask?.cancel()
        self.codexRadarTask = nil
    }

    private func startCodexRadarIntelligenceRefresh(force: Bool, now: Date) -> Task<Void, Never>? {
        if let inFlight = self.codexRadarTask {
            return inFlight
        }
        if !force, self.shouldSkipCodexRadarRefresh(now: now) {
            return nil
        }

        self.codexRadarGeneration &+= 1
        let generation = self.codexRadarGeneration
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performCodexRadarIntelligenceRefresh(generation: generation, now: now)
        }
        self.codexRadarTask = task
        return task
    }

    private func shouldSkipCodexRadarRefresh(now: Date) -> Bool {
        if let successAt = self.codexRadarLastSuccessfulFetchAt,
           now.timeIntervalSince(successAt) < Self.codexRadarSuccessTTL
        {
            return true
        }
        if let failureAt = self.codexRadarLastFailureAt,
           now.timeIntervalSince(failureAt) < Self.codexRadarFailureRetryInterval
        {
            return true
        }
        return false
    }

    private func performCodexRadarIntelligenceRefresh(generation: UInt64, now: Date) async {
        defer {
            if self.codexRadarGeneration == generation {
                self.codexRadarTask = nil
            }
        }

        let transport = self._test_codexRadarTransportOverride ?? ProviderHTTPClient.shared
        do {
            let fetched = try await CodexRadarIntelligence.fetch(transport: transport)
            guard !Task.isCancelled, self.codexRadarGeneration == generation else { return }
            let merged = Self.mergingCodexRadarSnapshot(fetched, lastGood: self.codexRadarSnapshot)
            if self.codexRadarSnapshot != merged {
                self.codexRadarSnapshot = merged
                self.codexRadarRevision += 1
            }
            self.codexRadarLastSuccessfulFetchAt = now
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, self.codexRadarGeneration == generation else { return }
            self.codexRadarLastFailureAt = now
        }
    }

    private static func mergingCodexRadarSnapshot(
        _ incoming: CodexRadarIntelligenceSnapshot,
        lastGood: CodexRadarIntelligenceSnapshot?) -> CodexRadarIntelligenceSnapshot
    {
        guard let lastGood else { return incoming }
        return CodexRadarIntelligenceSnapshot(
            points: CodexRadarIntelligenceTarget.allCases.map { target in
                let point = incoming.point(for: target)
                if point.iq != nil {
                    return point
                }
                return lastGood.point(for: target)
            })
    }
}
