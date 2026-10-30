import Foundation

public enum CLIProxyAPIProviderDescriptor {
    public static let descriptor: ProviderDescriptor = Self.makeDescriptor()
    private static let credentials = ProviderCredentialAdapter.apiKey(
        environmentKey: CLIProxyAPISettingsReader.apiKeyEnvironmentKey,
        additionalProjections: [
            .enterpriseHost(CLIProxyAPISettingsReader.baseURLEnvironmentKey),
            .workspaceID(CLIProxyAPISettingsReader.authIndexEnvironmentKey),
            ProviderCredentialEnvironmentProjection(
                key: CLIProxyAPISettingsReader.spendTrackingEnvironmentKey,
                value: { config in
                    guard let extrasEnabled = config.extrasEnabled else { return nil }
                    return extrasEnabled ? "1" : "0"
                }),
        ],
        resolve: CLIProxyAPISettingsReader.apiKey,
        configValidator: { config in
            guard let raw = config.sanitizedEnterpriseHost else { return [] }
            let environment = [CLIProxyAPISettingsReader.baseURLEnvironmentKey: raw]
            guard CLIProxyAPISettingsReader.baseURL(environment: environment) != nil else {
                return [CodexBarConfigIssue(
                    severity: .error,
                    provider: .cliproxyapi,
                    field: "enterpriseHost",
                    code: "invalid_enterprise_host",
                    message: CLIProxyAPISettingsError.invalidEndpointOverride(
                        CLIProxyAPISettingsReader.baseURLEnvironmentKey).errorDescription
                        ?? "Invalid CLIProxyAPI base URL.")]
            }
            return []
        },
        missingCredentialMessage: { _ in
            CLIProxyAPISettingsError.missingManagementKey.errorDescription
                ?? "Missing CLIProxyAPI management key."
        })

    static func makeDescriptor() -> ProviderDescriptor {
        ProviderDescriptor(
            id: .cliproxyapi,
            credentials: self.credentials,
            config: ProviderConfigCapabilities(
                workspaceIDValidationOrder: 7,
                supportsEnterpriseHost: true),
            metadata: ProviderMetadata(
                id: .cliproxyapi,
                displayName: "CLIProxyAPI",
                sessionLabel: "Session",
                weeklyLabel: "Weekly",
                opusLabel: nil,
                supportsOpus: false,
                supportsCredits: false,
                creditsHint: "Reads Codex, Gemini, Antigravity, and Grok quota through CLIProxyAPI api-call.",
                toggleTitle: "Show CLIProxyAPI usage",
                cliName: "cliproxyapi",
                defaultEnabled: false,
                widgetSelectable: false,
                isPrimaryProvider: false,
                usesAccountFallback: false,
                debugLogUnavailableMessage: "CLIProxyAPI debug log not yet implemented",
                dashboardURL: "http://127.0.0.1:8317/management.html",
                statusPageURL: nil),
            branding: ProviderBranding(
                iconStyle: .init(provider: .cliproxyapi),
                iconResourceName: "ProviderIcon-cliproxyapi",
                color: ProviderColor(red: 73 / 255, green: 163 / 255, blue: 176 / 255),
                confettiPalette: [
                    ProviderColor(hex: 0x49A3B0),
                    ProviderColor(hex: 0x60BA7E),
                    ProviderColor(hex: 0x4285F4),
                ]),
            tokenCost: ProviderTokenCostConfig(
                supportsTokenCost: true,
                noDataMessage: {
                    "No CLIProxyAPI spend data yet. Enable Track CLIProxyAPI spend, and set "
                        + "usage-statistics-enabled: true in CLIProxyAPI (it defaults to false)."
                },
                menuHintLines: [.literal("Observed by CLIProxyAPI, not a bill")],
                supportsTokenSnapshot: true,
                estimateDisclaimer: "Observed by CLIProxyAPI, not a bill"),
            fetchPlan: ProviderFetchPlan(
                sourceModes: [.auto, .api],
                pipeline: ProviderFetchPipeline(resolveStrategies: { _ in [CLIProxyAPIFetchStrategy()] })),
            cli: ProviderCLIConfig(
                name: "cliproxyapi",
                aliases: ["cliproxy", "cli-proxy-api", "codex-proxy"],
                versionDetector: nil))
    }
}

struct CLIProxyAPIFetchStrategy: ProviderFetchStrategy {
    let id: String = "cliproxyapi.api"
    let kind: ProviderFetchKind = .apiToken

    func isAvailable(_ context: ProviderFetchContext) async -> Bool {
        CLIProxyAPISettingsReader.apiKey(environment: context.env) != nil
    }

    func fetch(_ context: ProviderFetchContext) async throws -> ProviderFetchResult {
        try CLIProxyAPISettingsReader.validateEndpointOverride(environment: context.env)
        let settings = try CLIProxyAPISettingsReader.resolve(environment: context.env)
        let usage = try await CLIProxyAPIUsageFetcher.fetchUsage(settings: settings)
        return self.makeResult(usage: usage, sourceLabel: "cliproxy-api")
    }

    func shouldFallback(on _: Error, context _: ProviderFetchContext) -> Bool {
        false
    }
}
