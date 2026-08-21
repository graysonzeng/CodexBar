import CodexBarCore
import Foundation

@MainActor
final class CLIProxyAPIProviderRuntime: ProviderRuntime {
    let id: UsageProvider = .cliproxyapi
    private var collectorTask: Task<Void, Never>?

    func start(context: ProviderRuntimeContext) {
        self.reconcile(context: context)
    }

    func stop(context _: ProviderRuntimeContext) {
        self.collectorTask?.cancel()
        self.collectorTask = nil
    }

    func settingsDidChange(context: ProviderRuntimeContext) {
        self.reconcile(context: context)
    }

    private func reconcile(context: ProviderRuntimeContext) {
        let environment = ProviderRegistry.makeEnvironment(
            base: context.store.environmentBase,
            provider: .cliproxyapi,
            settings: context.settings,
            tokenOverride: nil)
        let shouldRun = context.store.isEnabled(.cliproxyapi)
            && CLIProxyAPISettingsReader.spendTrackingEnabled(environment: environment)
        if shouldRun {
            self.startCollector(context: context)
        } else {
            let wasRunning = self.collectorTask != nil
            self.stop(context: context)
            if wasRunning {
                Task { await context.store.refreshSpendDashboardTokenUsageNow(for: .cliproxyapi, force: true) }
            }
        }
    }

    private func startCollector(context: ProviderRuntimeContext) {
        guard self.collectorTask == nil else { return }
        self.collectorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.drainOnce(context: context)
                try? await Task.sleep(for: CLIProxyAPISpendCollector.tickInterval)
            }
        }
    }

    private func drainOnce(context: ProviderRuntimeContext) async {
        let environment = ProviderRegistry.makeEnvironment(
            base: context.store.environmentBase,
            provider: .cliproxyapi,
            settings: context.settings,
            tokenOverride: nil)
        guard CLIProxyAPISettingsReader.spendTrackingEnabled(environment: environment) else { return }
        do {
            let settings = try CLIProxyAPISettingsReader.resolve(environment: environment)
            let collector = CLIProxyAPISpendCollector(
                client: CLIProxyAPIManagementClient(settings: settings),
                store: CLIProxyAPISpendStore(cacheRoot: CLIProxyAPISpendStore.defaultRootURL()))
            let tick = try await collector.drainUntilEmpty()
            if tick.inserted > 0 {
                await context.store.refreshSpendDashboardTokenUsageNow(for: .cliproxyapi, force: true)
            }
        } catch is CancellationError {
            return
        } catch {
            await context.store.refreshSpendDashboardTokenUsageNow(for: .cliproxyapi, force: true)
        }
    }
}
