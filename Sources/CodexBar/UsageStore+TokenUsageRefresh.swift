import CodexBarCore
import Foundation

/// Token-usage refresh for `UsageStore.refreshTokenUsage(_:force:)`: eligibility, in-flight
/// caching, fetch, publication, failure gates, and cancellation. Split out of UsageStore.swift
/// to keep that file and this function under the lint line limits.
extension UsageStore {
    func refreshTokenUsage(_ provider: UsageProvider, force: Bool) async {
        if self.completeTokenUsageRefreshWithoutFetchIfNeeded(for: provider) {
            return
        }

        guard !self.tokenRefreshInFlight.contains(provider.instanceID) else { return }

        let now = Date()
        let historyDays = self.settings.costUsageHistoryDays
        // Cursor cost reuses the status cookie policy: a Manual source forwards the manual header so
        // cost and status share the same session; other sources fall back to auto resolution.
        guard case let .proceed(cursorCookieHeaderOverride) = self.prepareCursorCostCookie(for: provider) else {
            return
        }
        let costScope = self.tokenCostScope(for: provider)
        let costScopeSignature = self.tokenSnapshotScopeSignature(for: provider)
        let publicationRevision = self.providerPublicationRevision(for: provider)
        let providerConfigRevision = self.settings.providerConfigRevision(for: provider)
        if !force, self.tokenRefreshCanReuseCurrentSnapshot(
            provider: provider,
            now: now,
            costScopeSignature: costScopeSignature)
        {
            return
        }
        self.lastTokenFetchAt[provider.instanceID] = now
        self.lastTokenFetchScope[provider.instanceID] = costScopeSignature
        self.tokenRefreshInFlight.insert(provider.instanceID)
        defer { self.tokenRefreshInFlight.remove(provider.instanceID) }

        if let override = self._test_tokenUsageRefreshOverride {
            await override(provider, force)
            if Task.isCancelled {
                self.lastTokenFetchAt.removeValue(forKey: provider.instanceID)
                self.lastTokenFetchScope.removeValue(forKey: provider.instanceID)
            }
            return
        }

        await self.fetchAndPublishTokenUsage(TokenUsageRefreshRequest(
            provider: provider,
            force: force,
            now: now,
            historyDays: historyDays,
            cursorCookieHeaderOverride: cursorCookieHeaderOverride,
            codexHomePath: costScope.codexHomePath,
            costScopeSignature: costScopeSignature,
            publicationRevision: publicationRevision,
            providerConfigRevision: providerConfigRevision))
    }

    /// Completes refreshes that must not hit the network. Returns true when
    /// `refreshTokenUsage` should return immediately.
    private func completeTokenUsageRefreshWithoutFetchIfNeeded(for provider: UsageProvider) -> Bool {
        guard ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost else {
            self.resetTokenUsageState(for: provider)
            return true
        }

        if Self.tokenCostRequiresProviderSnapshot(provider) {
            if self.tokenSnapshotPublicationForCurrentProviderConfig(for: provider) != nil {
                self.tokenErrors[provider.instanceID] = nil
                self.tokenFailureGates[provider.instanceID]?.recordSuccess()
                self.persistWidgetSnapshot(reason: "token-usage")
            } else {
                self.clearTokenSnapshot(for: provider)
                self.tokenErrors[provider.instanceID] = nil
                self.tokenFailureGates[provider.instanceID]?.reset()
            }
            return true
        }

        guard self.settings.isCostUsageEffectivelyEnabled(for: provider) else {
            self.resetTokenUsageState(for: provider)
            return true
        }

        guard self.isEnabled(provider) else {
            self.resetTokenUsageState(for: provider)
            return true
        }

        // Provider-specific by design: Cursor cost shares the dashboard-cookie source policy with status fetching.
        // Cursor cost honors the same cookie policy as status: when the user set the cookie source
        // to Off, skip the network fetch entirely (mirrors CursorProviderDescriptor.checkStatus).
        if provider == .cursor, self.settings.cursorCookieSource == .off {
            self.resetTokenUsageState(for: provider)
            return true
        }

        return false
    }

    private struct TokenUsageRefreshRequest {
        let provider: UsageProvider
        let force: Bool
        let now: Date
        let historyDays: Int
        let cursorCookieHeaderOverride: String?
        let codexHomePath: String?
        let costScopeSignature: String
        let publicationRevision: ProviderPublicationRevision
        let providerConfigRevision: UInt64
    }

    private func fetchAndPublishTokenUsage(_ request: TokenUsageRefreshRequest) async {
        let provider = request.provider
        let force = request.force
        let now = request.now
        let historyDays = request.historyDays
        let cursorCookieHeaderOverride = request.cursorCookieHeaderOverride
        let codexHomePath = request.codexHomePath
        let costScopeSignature = request.costScopeSignature
        let publicationRevision = request.publicationRevision
        let providerConfigRevision = request.providerConfigRevision
        let startedAt = Date()
        self.tokenCostLogger
            .debug("cost usage start provider=\(provider.rawValue) force=\(force)")

        do {
            // Codex cost usage scans the explicit token-cost scope: selected managed account by
            // default, or this Mac's ambient Codex home when the local ledger is enabled.
            let snapshot = try await self.loadTokenUsageSnapshot(
                provider: provider,
                force: force,
                now: now,
                codexHomePath: codexHomePath,
                historyDays: historyDays,
                cursorCookieHeaderOverride: cursorCookieHeaderOverride)
            try Task.checkCancellation()
            let completedCostScopeSignature = self.completedTokenCostScopeSignature(
                provider: provider,
                historyDays: historyDays,
                initialSignature: costScopeSignature,
                snapshot: snapshot)
            guard self.tokenRefreshPublicationIsCurrent(
                provider: provider,
                publicationRevision: publicationRevision,
                providerConfigRevision: providerConfigRevision,
                historyDays: historyDays,
                costScopeSignature: costScopeSignature,
                fetchedCredentialScopeFingerprint: snapshot.credentialScopeFingerprint)
            else {
                self.clearTokenFetchMetadataIfMatching(
                    provider: provider,
                    attemptedAt: now,
                    costScopeSignature: costScopeSignature)
                self.requestTokenRefreshAfterStaleCompletion(for: provider)
                return
            }
            self.lastTokenFetchScope[provider.instanceID] = completedCostScopeSignature
            self.startCodexCostCatchUpIfNeeded(afterRefreshing: provider)

            // Provider-specific by design: CLIProxyAPI publishes cost even when history is empty and
            // maps the snapshot history disclaimer onto the token-error lane.
            if provider == .cliproxyapi {
                self.publishTokenSnapshot(snapshot, for: provider)
                self.tokenErrors[provider.instanceID] = Self.cliproxyapiTokenError(from: snapshot)
                self.tokenFailureGates[provider.instanceID]?.recordSuccess()
                self.persistWidgetSnapshot(reason: "token-usage")
                return
            }

            if try self.regularTokenSnapshotIsConfirmedEmpty(snapshot, for: provider) {
                self.publishConfirmedEmptyTokenSnapshot(for: provider)
                self.tokenErrors[provider.instanceID] = Self.tokenCostNoDataMessage(for: provider)
                self.tokenFailureGates[provider.instanceID]?.recordSuccess()
                return
            }
            self.logTokenUsageSuccess(
                provider: provider,
                snapshot: snapshot,
                historyDays: historyDays,
                startedAt: startedAt)
            self.publishTokenSnapshot(snapshot, for: provider)
            self.tokenErrors[provider.instanceID] = nil
            self.tokenFailureGates[provider.instanceID]?.recordSuccess()
            self.persistWidgetSnapshot(reason: "token-usage")
        } catch {
            guard self.tokenRefreshPublicationIsCurrent(
                provider: provider,
                publicationRevision: publicationRevision,
                providerConfigRevision: providerConfigRevision,
                historyDays: historyDays,
                costScopeSignature: costScopeSignature)
            else {
                self.clearTokenFetchMetadataIfMatching(
                    provider: provider,
                    attemptedAt: now,
                    costScopeSignature: costScopeSignature)
                self.requestTokenRefreshAfterStaleCompletion(for: provider)
                return
            }
            if error is CancellationError {
                self.clearTokenFetchMetadataIfMatching(
                    provider: provider,
                    attemptedAt: now,
                    costScopeSignature: costScopeSignature)
                return
            }
            let duration = Date().timeIntervalSince(startedAt)
            let msg = error.localizedDescription
            let durationText = String(format: "%.2f", duration)
            let message = "cost usage failed provider=\(provider.rawValue) duration=\(durationText)s error=\(msg)"
            self.tokenCostLogger.error(message)
            if Self.tokenFetchFailureAllowsEarlyRetry(error) {
                self.clearTokenFetchMetadataIfMatching(
                    provider: provider,
                    attemptedAt: now,
                    costScopeSignature: costScopeSignature)
            }
            let hadPriorData = self.tokenSnapshots[provider.instanceID] != nil
            let shouldSurface = self.tokenFailureGates[provider.instanceID]?
                .shouldSurfaceError(onFailureWithPriorData: hadPriorData) ?? true
            if shouldSurface {
                self.tokenErrors[provider.instanceID] = error.localizedDescription
                self.clearTokenSnapshot(for: provider)
            } else {
                self.tokenErrors[provider.instanceID] = nil
            }
        }
    }

    private func resetTokenUsageState(for provider: UsageProvider) {
        // Provider-specific by design: resetting Codex token state also cancels its two ledger catch-up workflows.
        if provider == .codex {
            self.cancelCodexCostCatchUp()
            self.cancelSpendDashboardCodexCostCatchUp()
        }
        self.clearTokenSnapshot(for: provider)
        self.clearSpendDashboardTokenSnapshot(for: provider)
        self.tokenErrors[provider.instanceID] = nil
        self.tokenFailureGates[provider.instanceID]?.reset()
        self.lastTokenFetchAt.removeValue(forKey: provider.instanceID)
        self.lastTokenFetchScope.removeValue(forKey: provider.instanceID)
        self.lastSpendDashboardTokenFetchAt.removeValue(forKey: provider.instanceID)
        self.lastSpendDashboardTokenFetchScope.removeValue(forKey: provider.instanceID)
    }

    private func logTokenUsageSuccess(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot,
        historyDays: Int,
        startedAt: Date)
    {
        let durationText = String(format: "%.2f", Date().timeIntervalSince(startedAt))
        let sessionCost = snapshot.sessionCostUSD
            .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
        let monthCost = snapshot.last30DaysCostUSD
            .map { UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode) } ?? "—"
        let message =
            "cost usage success provider=\(provider.rawValue) " +
            "duration=\(durationText)s " +
            "today=\(sessionCost) " +
            "historyDays=\(historyDays) windowCost=\(monthCost)"
        self.tokenCostLogger.info(message)
    }

    private func clearTokenFetchMetadataIfMatching(
        provider: UsageProvider,
        attemptedAt: Date,
        costScopeSignature: String)
    {
        guard self.lastTokenFetchAt[provider.instanceID] == attemptedAt,
              self.lastTokenFetchScope[provider.instanceID] == costScopeSignature
        else {
            return
        }
        self.lastTokenFetchAt.removeValue(forKey: provider.instanceID)
        self.lastTokenFetchScope.removeValue(forKey: provider.instanceID)
    }

    /// Fast failures may retry on the next scheduled pass instead of waiting out the fetch
    /// TTL; timed-out scans keep the TTL so a slow corpus cannot thrash back-to-back rescans.
    nonisolated static func tokenFetchFailureAllowsEarlyRetry(_ error: Error) -> Bool {
        if case CostUsageError.timedOut = error {
            return false
        }
        return true
    }
}
