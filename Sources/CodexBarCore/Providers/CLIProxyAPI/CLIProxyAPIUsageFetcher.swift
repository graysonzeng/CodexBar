import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CLIProxyAPIUsageFetcher {
    public static func fetchUsage(
        settings: CLIProxyAPISettings,
        transport: any ProviderHTTPTransport = ProviderHTTPClient.shared,
        updatedAt: Date = Date()) async throws -> UsageSnapshot
    {
        let client = CLIProxyAPIManagementClient(settings: settings, transport: transport)
        let auths = try await client.listAuths()
        guard !auths.isEmpty else { throw CLIProxyAPIError.missingAuth(settings.authIndex) }

        var accounts: [CLIProxyAPIAccountUsage] = []
        var lastError: Error?
        for auth in auths {
            do {
                if let account = try await self.fetchAccount(auth: auth, client: client) {
                    accounts.append(account)
                }
            } catch {
                lastError = error
            }
        }
        if let snapshot = CLIProxyAPISnapshotMapper.usageSnapshot(accounts: accounts, updatedAt: updatedAt) {
            return snapshot
        }
        throw lastError ?? CLIProxyAPIError.missingAuth(settings.authIndex)
    }

    private static func fetchAccount(
        auth: CLIProxyAPIResolvedAuth,
        client: CLIProxyAPIManagementClient) async throws -> CLIProxyAPIAccountUsage?
    {
        // Provider-specific by design: CLIProxyAPI quota fetch is keyed by CPA auth kind, including Grok/xAI.
        switch auth.kind {
        case .codex:
            let usage = try await client.fetchCodexUsage(auth: auth)
            return CLIProxyAPISnapshotMapper.accountUsage(auth: auth, codex: usage)
        case .gemini, .antigravity:
            let quota = try await client.fetchGeminiLikeQuota(auth: auth)
            return CLIProxyAPISnapshotMapper.accountUsage(auth: auth, gemini: quota)
        case .grok:
            let usage = try await client.fetchGrokUsage(auth: auth)
            return CLIProxyAPISnapshotMapper.accountUsage(auth: auth, grok: usage)
        }
    }
}
