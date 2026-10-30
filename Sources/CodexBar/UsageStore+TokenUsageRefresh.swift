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

        guard await self.refreshPiHistoryScope(for: provider) else { return }

        guard !self.tokenRefreshInFlight.contains(provider.instanceID) else { return }

        let now = Date()
        let historyDays = self.settings.costReportingPeriod.days(
            now: now,
            calendar: self.settings.costUsageBucketCalendar)
        // Cursor cost reuses the status cookie policy: a Manual source forwards the manual header so
        // cost and status share the same session; other sources fall back to auto resolution.
        guard case let .proceed(cursorCookieHeaderOverride) = self.prepareCursorCostCookie(for: provider) else {
            return
        }
        let costScope = self.tokenCostScope(for: provider)
        let costScopeSignature = self.tokenSnapshotScopeSignature(for: provider)
        let publicationScope = self.tokenRefreshPublicationScope(
            for: provider, historyDays: historyDays, costScopeSignature: costScopeSignature)
        if !force, self.tokenRefreshFailureIsCoolingDown(provider: provider, now: now) {
            return
        }
        if !force, self.tokenRefreshCanReuseCurrentSnapshot(
            provider: provider,
            now: now,
            costScopeSignature: costScopeSignature)
        {
            return
        }
        self.tokenFetchFailureCooldowns.removeValue(forKey: provider.instanceID)
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

        let startedAt = Date()
        self.tokenCostLogger
            .debug("cost usage start provider=\(provider.rawValue) force=\(force)")
        let refreshContext = TokenUsageRefreshContext(
            provider: provider,
            now: now,
            historyDays: historyDays,
            costScopeSignature: costScopeSignature,
            publicationScope: publicationScope,
            startedAt: startedAt)

        do {
            // Codex cost usage scans the explicit token-cost scope: selected managed account by
            // default, or this Mac's ambient Codex home when the local ledger is enabled.
            let result = try await self.loadTokenUsageSnapshot(
                provider: provider,
                force: force,
                now: now,
                codexHomePath: costScope.codexHomePath,
                historyDays: historyDays,
                cursorCookieHeaderOverride: cursorCookieHeaderOverride,
                includePiSessions: self.shouldIncludePiSessionsInTokenSnapshot(for: provider))
            try self.commitTokenUsageResult(result, context: refreshContext)
        } catch {
            guard self.tokenRefreshPublicationDisposition(
                provider: provider,
                scope: publicationScope) == .current
            else {
                self.clearTokenFetchMetadataIfMatching(
                    provider: provider,
                    attemptedAt: now,
                    costScopeSignature: costScopeSignature)
                self.requestTokenRefreshAfterStaleCompletion(for: provider)
                return
            }
            let cancelled = Task.isCancelled || error is CancellationError
            let retryDelay = Self.tokenFetchFailureRetryDelay(error, ttl: self.tokenFetchTTL)
            if cancelled || retryDelay == nil {
                self.clearTokenFetchMetadataIfMatching(
                    provider: provider,
                    attemptedAt: now,
                    costScopeSignature: costScopeSignature)
            } else if let retryDelay {
                self.tokenFetchFailureCooldowns[provider.instanceID] = TokenFetchFailureCooldown(
                    attemptedAt: now, retryAfter: now.addingTimeInterval(retryDelay), scope: publicationScope)
            }
            if cancelled { return }
            let duration = Date().timeIntervalSince(startedAt)
            let msg = error.localizedDescription
            let durationText = String(format: "%.2f", duration)
            let message = "cost usage failed provider=\(provider.rawValue) duration=\(durationText)s error=\(msg)"
            self.tokenCostLogger.error(message)
            let hadPriorData = self.tokenSnapshotPublications[provider.instanceID]?.snapshot != nil
            let shouldSurface = self.tokenFailureGates[provider.instanceID]?
                .shouldSurfaceError(onFailureWithPriorData: hadPriorData) ?? true
            // Provider-specific by design: collection failures remain visible independently of read retry gates.
            if provider == .cliproxyapi, let failure = self.currentCLIProxyAPICollectionFailure(for: provider) {
                self.tokenErrors[provider.instanceID] = failure.error.errorDescription
            } else if shouldSurface {
                self.tokenErrors[provider.instanceID] = error.localizedDescription
                self.clearTokenSnapshot(for: provider)
            } else {
                self.tokenErrors[provider.instanceID] = nil
            }
        }
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
}
