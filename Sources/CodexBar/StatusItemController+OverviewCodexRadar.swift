import AppKit
import CodexBarCore

extension StatusItemController {
    func includesOverviewTab(enabledProviders: [UsageProvider]) -> Bool {
        !self.settings.resolvedMergedOverviewProviders(
            activeProviders: enabledProviders,
            maxVisibleProviders: SettingsStore.mergedOverviewProviderLimit).isEmpty
    }

    func resolvedSwitcherSelection(
        enabledProviders: [UsageProvider],
        includesOverview: Bool) -> ProviderSwitcherSelection
    {
        if includesOverview, self.settings.mergedMenuLastSelectedWasOverview {
            return .overview
        }
        // Provider-specific by design: Codex remains the persisted fallback when Overview has no resolved provider.
        return .provider((self.resolvedMenuProvider(enabledProviders: enabledProviders) ?? .codex).instanceID)
    }

    func scheduleCodexRadarIntelligenceRefreshIfOverviewSelected() {
        guard self.isMenuRefreshEnabled, self.shouldMergeIcons else { return }
        let enabledProviders = self.store.enabledFirstPartyProvidersForDisplay()
        let includesOverview = self.includesOverviewTab(enabledProviders: enabledProviders)
        guard includesOverview,
              self.resolvedSwitcherSelection(
                  enabledProviders: enabledProviders,
                  includesOverview: includesOverview) == .overview
        else { return }
        self.store.scheduleCodexRadarIntelligenceRefresh()
    }

    @discardableResult
    func addOverviewCodexRadarCard(to menu: NSMenu, width: CGFloat, separated: Bool) -> Bool {
        guard let snapshot = self.store.codexRadarSnapshot else { return false }
        let summary = OverviewCodexRadarSummary(snapshot: snapshot)
        if separated {
            menu.addItem(.separator())
        }
        menu.addItem(self.makeMenuCardItem(
            OverviewCodexRadarCardView(summary: summary, width: width),
            id: "overviewCodexRadar",
            width: width,
            heightCacheScope: "overviewCodexRadar",
            heightCacheFingerprint: summary.visibleFingerprint))
        return true
    }
}
