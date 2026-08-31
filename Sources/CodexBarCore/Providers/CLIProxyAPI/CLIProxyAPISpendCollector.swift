import Foundation

public struct CLIProxyAPISpendCollectorTick: Sendable, Equatable {
    public let popped: Int
    public let inserted: Int
    public let duplicates: Int
    public let skipped: Int
    public let dropped: Int
    public let pages: Int

    public init(popped: Int, inserted: Int, duplicates: Int, skipped: Int, dropped: Int, pages: Int) {
        self.popped = popped
        self.inserted = inserted
        self.duplicates = duplicates
        self.skipped = skipped
        self.dropped = dropped
        self.pages = pages
    }
}

public struct CLIProxyAPISpendCollector: Sendable {
    public static let defaultPageSize = 200
    public static let defaultMaxPagesPerTick = 50
    public static let defaultMaxEventsPerTick = 10000
    public static let tickInterval: Duration = .seconds(5)

    private let client: CLIProxyAPIManagementClient
    private let store: CLIProxyAPISpendStore
    private let pageSize: Int
    private let maxPagesPerTick: Int
    private let maxEventsPerTick: Int

    public init(
        client: CLIProxyAPIManagementClient,
        store: CLIProxyAPISpendStore,
        pageSize: Int = Self.defaultPageSize,
        maxPagesPerTick: Int = Self.defaultMaxPagesPerTick,
        maxEventsPerTick: Int = Self.defaultMaxEventsPerTick)
    {
        self.client = client
        self.store = store
        self.pageSize = max(2, pageSize)
        self.maxPagesPerTick = max(1, maxPagesPerTick)
        self.maxEventsPerTick = max(self.pageSize, maxEventsPerTick)
    }

    @discardableResult
    public func drainUntilEmpty() async throws -> CLIProxyAPISpendCollectorTick {
        guard try await self.client.usageStatisticsEnabled() else {
            throw CLIProxyAPISpendError.usageStatisticsDisabled
        }

        var popped = 0
        var inserted = 0
        var duplicates = 0
        var skipped = 0
        var dropped = 0
        var pages = 0

        while pages < self.maxPagesPerTick, popped < self.maxEventsPerTick {
            let remaining = self.maxEventsPerTick - popped
            let count = min(self.pageSize, remaining)
            let page = try await self.client.popUsageQueue(count: count)
            pages += 1
            skipped += page.skipped
            guard !page.events.isEmpty else { break }
            popped += page.events.count
            do {
                let result = try self.store.insert(
                    page.events,
                    fingerprint: CLIProxyAPISpendSnapshot.fingerprint(settings: self.client.settings))
                inserted += result.inserted
                duplicates += result.duplicates
                dropped += result.dropped
            } catch {
                dropped += page.events.count
                throw CLIProxyAPISpendError.persistFailed(error.localizedDescription)
            }
            if page.events.count < count {
                break
            }
        }

        return CLIProxyAPISpendCollectorTick(
            popped: popped,
            inserted: inserted,
            duplicates: duplicates,
            skipped: skipped,
            dropped: dropped,
            pages: pages)
    }
}
