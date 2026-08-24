import Foundation

@MainActor
final class DashboardStore: ObservableObject {
    @Published private(set) var dashboard: Dashboard?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var dataSourceLabel = "not configured"
    @Published private(set) var lastUpdatedAt: Date?

    private let core: CostbarCore?
    private let credentials: CredentialStore
    private let apiClient: ProviderAPIClient
    private var refreshTask: Task<Void, Never>?

    init(
        credentials: CredentialStore = CredentialStore(),
        apiClient: ProviderAPIClient = ProviderAPIClient()
    ) {
        self.credentials = credentials
        self.apiClient = apiClient
        do {
            core = try CostbarCore()
            refresh()
        } catch {
            core = nil
            errorMessage = error.localizedDescription
        }
    }

    var menuBarTitle: String {
        guard let total = dashboard?.primaryTotal else { return "Costbar" }
        return total.currentCostMicros.currencyText(code: total.currency)
    }

    func refresh() {
        guard let core, !isRefreshing else { return }
        refreshTask?.cancel()
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await refresh(core: core)
        }
    }

    private func refresh(core: CostbarCore) async {
        defer { isRefreshing = false }
        let period = Dashboard.Period.currentMonth()
        var configuredProviderCount = 0
        var refreshedProviderCount = 0
        var errors: [String] = []

        do {
            let saved = try credentials.load()
            if let token = saved.digitalOceanToken,
               !token.isEmpty {
                configuredProviderCount += 1
                do {
                    try await apiClient.refreshDigitalOcean(token: token, core: core)
                    refreshedProviderCount += 1
                } catch {
                    errors.append(error.localizedDescription)
                }
            }

            let cloudflareToken = saved.cloudflareToken
            let cloudflareAccountID = saved.cloudflareAccountID
            if let token = cloudflareToken, !token.isEmpty,
               let accountID = cloudflareAccountID, !accountID.isEmpty {
                configuredProviderCount += 1
                do {
                    try await apiClient.refreshCloudflare(
                        token: token,
                        accountID: accountID,
                        core: core
                    )
                    refreshedProviderCount += 1
                } catch {
                    errors.append(error.localizedDescription)
                }
            }

            if let apiKey = saved.runpodAPIKey,
               !apiKey.isEmpty {
                configuredProviderCount += 1
                do {
                    try await apiClient.refreshRunpod(
                        apiKey: apiKey,
                        period: period,
                        core: core
                    )
                    refreshedProviderCount += 1
                } catch {
                    errors.append(error.localizedDescription)
                }
            }

            if let token = saved.vercelToken,
               !token.isEmpty {
                configuredProviderCount += 1
                do {
                    try await apiClient.refreshVercel(
                        token: token,
                        teamIDOrSlug: saved.vercelTeamIDOrSlug,
                        period: period,
                        core: core
                    )
                    refreshedProviderCount += 1
                } catch {
                    errors.append(error.localizedDescription)
                }
            }

            if let apiKey = saved.openRouterAPIKey,
               !apiKey.isEmpty {
                configuredProviderCount += 1
                do {
                    try await apiClient.refreshOpenRouter(
                        apiKey: apiKey,
                        managementKey: saved.openRouterManagementKey,
                        period: period,
                        core: core
                    )
                    refreshedProviderCount += 1
                } catch {
                    errors.append(error.localizedDescription)
                }
            }

            if let adminKey = saved.openAIAdminKey, !adminKey.isEmpty {
                configuredProviderCount += 1
                do {
                    try await apiClient.refreshOpenAIOrganization(
                        adminKey: adminKey,
                        period: period,
                        core: core
                    )
                    refreshedProviderCount += 1
                } catch {
                    errors.append(error.localizedDescription)
                }
            }

            if let adminKey = saved.anthropicAdminKey, !adminKey.isEmpty {
                configuredProviderCount += 1
                do {
                    try await apiClient.refreshAnthropicOrganization(
                        adminKey: adminKey,
                        period: period,
                        core: core
                    )
                    refreshedProviderCount += 1
                } catch {
                    errors.append(error.localizedDescription)
                }
            }

            if let token = saved.githubToken, !token.isEmpty,
               let organization = saved.githubOrganization, !organization.isEmpty {
                configuredProviderCount += 1
                do {
                    try await apiClient.refreshGitHub(
                        token: token,
                        organization: organization,
                        period: period,
                        core: core
                    )
                    refreshedProviderCount += 1
                } catch {
                    errors.append(error.localizedDescription)
                }
            }

            if let adminKey = saved.cursorAdminKey, !adminKey.isEmpty {
                configuredProviderCount += 1
                do {
                    try await apiClient.refreshCursor(
                        adminKey: adminKey,
                        period: period,
                        core: core
                    )
                    refreshedProviderCount += 1
                } catch {
                    errors.append(error.localizedDescription)
                }
            }
        } catch {
            errors.append(error.localizedDescription)
        }

        let subscriptions = SubscriptionSettings.load()
        do {
            let payload = try SubscriptionSettings.snapshotData(from: subscriptions)
            try core.ingest(
                providerID: "subscriptions",
                documentID: "subscriptions",
                data: payload
            )
            if !subscriptions.isEmpty {
                configuredProviderCount += 1
                refreshedProviderCount += 1
            }
        } catch where !subscriptions.isEmpty {
            configuredProviderCount += 1
            errors.append(error.localizedDescription)
        } catch {
            // An empty subscription list deliberately leaves the provider unavailable.
        }

        if LocalAISettings.tracksCodex() {
            configuredProviderCount += 1
            do {
                let payload = try await LocalAIUsageCollector.codex(period: period)
                try core.ingest(providerID: "codex", documentID: "usage", data: payload)
                refreshedProviderCount += 1
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        if LocalAISettings.tracksClaude() {
            configuredProviderCount += 1
            do {
                let payload = try await LocalAIUsageCollector.claude(period: period)
                try core.ingest(providerID: "claude", documentID: "usage", data: payload)
                refreshedProviderCount += 1
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        do {
            dashboard = try core.snapshot(period: period)
        } catch {
            errors.append(error.localizedDescription)
        }

        dataSourceLabel = if configuredProviderCount == 0 {
            "not configured"
        } else if refreshedProviderCount == configuredProviderCount {
            "live"
        } else {
            "stale"
        }
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        lastUpdatedAt = .now
    }
}
