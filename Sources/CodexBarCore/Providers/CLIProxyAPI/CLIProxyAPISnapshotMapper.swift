import Foundation

enum CLIProxyAPISnapshotMapper {
    static func usageSnapshot(
        accounts: [CLIProxyAPIAccountUsage],
        updatedAt: Date) -> UsageSnapshot?
    {
        guard !accounts.isEmpty else { return nil }
        let extras = accounts.map { account in
            NamedRateWindow(
                id: account.auth.authIndex,
                title: account.title,
                window: account.primary)
        }
        let primary = accounts.map(\.primary).max { lhs, rhs in
            lhs.usedPercent < rhs.usedPercent
        }
        let secondary = accounts.compactMap(\.secondary).max { lhs, rhs in
            lhs.usedPercent < rhs.usedPercent
        }
        let emails = accounts.compactMap(\.auth.email)
        return UsageSnapshot(
            primary: primary,
            secondary: secondary,
            extraRateWindows: extras,
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: UsageProvider.cliproxyapi.instanceID,
                accountEmail: emails.count == 1 ? emails.first : nil,
                accountOrganization: "\(accounts.count) account\(accounts.count == 1 ? "" : "s")",
                loginMethod: "cliproxy-api"))
            .scoped(to: .cliproxyapi)
    }

    static func accountUsage(
        auth: CLIProxyAPIResolvedAuth,
        codex: CodexUsageResponse) -> CLIProxyAPIAccountUsage?
    {
        let primary = self.codexWindow(codex.rateLimit?.primaryWindow)
        let secondary = self.codexWindow(codex.rateLimit?.secondaryWindow)
        let normalized = CodexRateWindowNormalizer.normalize(primary: primary, secondary: secondary)
        guard let session = normalized.primary ?? normalized.secondary else { return nil }
        return CLIProxyAPIAccountUsage(
            auth: auth,
            title: self.title(for: auth),
            primary: session,
            secondary: normalized.primary == nil ? nil : normalized.secondary)
    }

    static func accountUsage(
        auth: CLIProxyAPIResolvedAuth,
        gemini: CLIProxyAPIGeminiQuotaResponse) -> CLIProxyAPIAccountUsage?
    {
        let modelBuckets = self.reduceByModel(gemini.buckets)
        let proBucket = self.lowestBucket(matching: "pro", from: modelBuckets)
        let flashBucket = self.lowestBucket(matching: "flash", from: modelBuckets)
        let fallback = modelBuckets.min { $0.remainingFraction < $1.remainingFraction }
        guard let primary = self.geminiWindow(proBucket ?? fallback) else { return nil }
        return CLIProxyAPIAccountUsage(
            auth: auth,
            title: self.title(for: auth),
            primary: primary,
            secondary: self.geminiWindow(flashBucket))
    }

    static func accountUsage(
        auth: CLIProxyAPIResolvedAuth,
        grok: GrokWebBillingSnapshot) -> CLIProxyAPIAccountUsage?
    {
        guard let usedPercent = grok.usedPercent else { return nil }
        return CLIProxyAPIAccountUsage(
            auth: auth,
            title: self.title(for: auth),
            primary: RateWindow(
                usedPercent: usedPercent,
                windowMinutes: 7 * 24 * 60,
                resetsAt: grok.resetsAt,
                resetDescription: grok.resetsAt.map { UsageFormatter.resetDescription(from: $0) }),
            secondary: nil)
    }

    private static func title(for auth: CLIProxyAPIResolvedAuth) -> String {
        auth.kind.displayName
    }

    private static func codexWindow(_ window: CodexUsageResponse.WindowSnapshot?) -> RateWindow? {
        guard let window else { return nil }
        let resetDate = Date(timeIntervalSince1970: TimeInterval(window.resetAt))
        return RateWindow(
            usedPercent: Double(window.usedPercent),
            windowMinutes: window.limitWindowSeconds / 60,
            resetsAt: resetDate,
            resetDescription: UsageFormatter.resetDescription(from: resetDate))
    }

    private static func geminiWindow(_ bucket: CLIProxyAPIGeminiQuotaBucket?) -> RateWindow? {
        guard let bucket else { return nil }
        let usedPercent = max(0, min(100, (1 - bucket.remainingFraction) * 100))
        return RateWindow(
            usedPercent: usedPercent,
            windowMinutes: 1440,
            resetsAt: bucket.resetTime,
            resetDescription: bucket.resetTime.map { UsageFormatter.resetDescription(from: $0) })
    }

    private static func reduceByModel(_ buckets: [CLIProxyAPIGeminiQuotaBucket]) -> [CLIProxyAPIGeminiQuotaBucket] {
        var byModel: [String: CLIProxyAPIGeminiQuotaBucket] = [:]
        for bucket in buckets {
            guard !bucket.modelID.isEmpty else { continue }
            if let existing = byModel[bucket.modelID], existing.remainingFraction <= bucket.remainingFraction {
                continue
            }
            byModel[bucket.modelID] = bucket
        }
        return Array(byModel.values)
    }

    private static func lowestBucket(
        matching token: String,
        from buckets: [CLIProxyAPIGeminiQuotaBucket]) -> CLIProxyAPIGeminiQuotaBucket?
    {
        buckets
            .filter { $0.modelID.localizedCaseInsensitiveContains(token) }
            .min { $0.remainingFraction < $1.remainingFraction }
    }
}

struct CLIProxyAPIAccountUsage: Sendable {
    let auth: CLIProxyAPIResolvedAuth
    let title: String
    let primary: RateWindow
    let secondary: RateWindow?
}
