#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

public enum CLIProxyAPISpendSnapshot {
    public static let observedDisclaimer = "Observed by CLIProxyAPI, not a bill"

    public static func load(
        environment: [String: String],
        now: Date,
        historyDays: Int,
        calendar: Calendar,
        store: CLIProxyAPISpendStore? = nil,
        customPricing: CostUsageCustomPricing = CostUsageCustomPricing.load(),
        client: CLIProxyAPIManagementClient? = nil) async throws -> CostUsageTokenSnapshot
    {
        let resolvedStore = store ?? CLIProxyAPISpendStore(cacheRoot: CLIProxyAPISpendStore.defaultRootURL())
        let fingerprint: String?
        if let resolvedSettings = try? CLIProxyAPISettingsReader.resolve(environment: environment) {
            fingerprint = Self.fingerprint(settings: resolvedSettings)
        } else {
            fingerprint = nil
        }
        let events: [CLIProxyAPISpendEvent]
        do {
            if let fingerprint {
                events = try resolvedStore.loadEvents(fingerprint: fingerprint)
            } else {
                events = []
            }
        } catch {
            throw CLIProxyAPISpendError.persistFailed(error.localizedDescription)
        }

        if !CLIProxyAPISettingsReader.spendTrackingEnabled(environment: environment) {
            return self.emptySnapshot(
                now: now,
                historyDays: historyDays,
                calendar: calendar,
                label: CLIProxyAPISpendError.trackingDisabled.errorDescription,
                fingerprint: nil,
                historyCoverageIsEstablished: false)
        }

        let settings: CLIProxyAPISettings
        do {
            settings = try CLIProxyAPISettingsReader.resolve(environment: environment)
        } catch is CLIProxyAPISettingsError {
            if events.isEmpty {
                throw CLIProxyAPISpendError.unreachable(CLIProxyAPISettingsReader.defaultBaseURL.absoluteString)
            }
            return CLIProxyAPISpendAggregator.snapshot(
                events: events,
                now: now,
                historyDays: historyDays,
                calendar: calendar,
                customPricing: customPricing,
                historyLabel: CLIProxyAPISpendError.unreachable(
                    CLIProxyAPISettingsReader.defaultBaseURL.absoluteString).errorDescription,
                historyCoverageIsEstablished: true)
        }

        let resolvedFingerprint = fingerprint ?? Self.fingerprint(settings: settings)
        let management = client ?? CLIProxyAPIManagementClient(settings: settings)
        do {
            let statisticsEnabled = try await management.usageStatisticsEnabled()
            if !statisticsEnabled {
                if events.isEmpty {
                    throw CLIProxyAPISpendError.usageStatisticsDisabled
                }
                return CLIProxyAPISpendAggregator.snapshot(
                    events: events,
                    now: now,
                    historyDays: historyDays,
                    calendar: calendar,
                    customPricing: customPricing,
                    credentialScopeFingerprint: resolvedFingerprint,
                    historyLabel: CLIProxyAPISpendError.usageStatisticsDisabled.errorDescription,
                    historyCoverageIsEstablished: true)
            }
        } catch let error as CLIProxyAPISpendError {
            throw error
        } catch {
            if events.isEmpty {
                throw CLIProxyAPISpendError.unreachable(settings.baseURL.absoluteString)
            }
            return CLIProxyAPISpendAggregator.snapshot(
                events: events,
                now: now,
                historyDays: historyDays,
                calendar: calendar,
                customPricing: customPricing,
                credentialScopeFingerprint: resolvedFingerprint,
                historyLabel: CLIProxyAPISpendError.unreachable(settings.baseURL.absoluteString).errorDescription,
                historyCoverageIsEstablished: true)
        }

        return CLIProxyAPISpendAggregator.snapshot(
            events: events,
            now: now,
            historyDays: historyDays,
            calendar: calendar,
            customPricing: customPricing,
            credentialScopeFingerprint: resolvedFingerprint,
            historyLabel: Self.observedDisclaimer,
            historyCoverageIsEstablished: true)
    }

    public static func emptySnapshot(
        now: Date,
        historyDays: Int,
        calendar: Calendar,
        label: String?,
        fingerprint: String?,
        historyCoverageIsEstablished: Bool = true) -> CostUsageTokenSnapshot
    {
        CLIProxyAPISpendAggregator.snapshot(
            events: [],
            now: now,
            historyDays: historyDays,
            calendar: calendar,
            credentialScopeFingerprint: fingerprint,
            historyLabel: label,
            historyCoverageIsEstablished: historyCoverageIsEstablished)
    }

    public static func fingerprint(settings: CLIProxyAPISettings) -> String {
        let raw = "\(settings.baseURL.absoluteString)|\(settings.managementKey)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
