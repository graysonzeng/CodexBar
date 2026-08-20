import CodexBarCore
import Foundation

struct CLIProxyAPIProviderImplementation: ProviderImplementation {
    let id: UsageProvider = .cliproxyapi

    @MainActor
    func presentation(context _: ProviderPresentationContext) -> ProviderPresentation {
        ProviderPresentation { _ in "cliproxy-api" }
    }

    @MainActor
    func observeSettings(_ settings: SettingsStore) {
        _ = settings[providerConfig: .cliproxyapi, field: .apiKey]
        _ = settings[providerConfig: .cliproxyapi, field: .endpoint]
        _ = settings[providerConfig: .cliproxyapi, field: .workspace]
    }

    @MainActor
    func isAvailable(context: ProviderAvailabilityContext) -> Bool {
        CLIProxyAPISettingsReader.apiKey(environment: context.environment) != nil
    }

    @MainActor
    func settingsFields(context: ProviderSettingsContext) -> [ProviderSettingsFieldDescriptor] {
        [
            ProviderSettingsFieldDescriptor(
                id: "cliproxyapi-management-key",
                title: "Management key",
                subtitle: "CLIProxyAPI remote-management secret-key. Also CLIPROXYAPI_MANAGEMENT_KEY.",
                kind: .secure,
                placeholder: "management key…",
                binding: context.providerConfigBinding(.apiKey),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "cliproxyapi-base-url",
                title: "Base URL",
                subtitle: "Defaults to http://127.0.0.1:8317. HTTPS required except loopback/private-network HTTP.",
                kind: .plain,
                placeholder: "http://127.0.0.1:8317",
                binding: context.providerConfigBinding(.endpoint),
                actions: [],
                isVisible: nil,
                onActivate: nil),
            ProviderSettingsFieldDescriptor(
                id: "cliproxyapi-auth-index",
                title: "auth_index (optional)",
                subtitle: "Limit refresh to one credential. Empty scans Codex, Gemini, Antigravity, and Grok.",
                kind: .plain,
                placeholder: "auth_index…",
                binding: context.providerConfigBinding(.workspace),
                actions: [],
                isVisible: nil,
                onActivate: nil),
        ]
    }
}
