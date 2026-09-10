import Testing
@testable import Costbar

@Test
func typedSnapshotBridgeHasNoProviderDataBeforeRefresh() throws {
    let core = try CostbarCore()
    let dashboard = try core.snapshot(period: .init(startUnix: 1, endExclusiveUnix: 2))

    #expect(dashboard.providers.map(\.summary.id) == [
        "digitalocean", "hetzner", "cloudflare", "runpod", "vercel",
        "openrouter", "codex", "claude", "openai-api", "anthropic-api", "xai-api",
        "github", "cursor", "cursor-local", "opencode",
    ])
    #expect(dashboard.providers.allSatisfy { $0.summary.status == .notConfigured })
    #expect(dashboard.providers.allSatisfy { $0.summary.errorMessage == nil })
    #expect(dashboard.providers.allSatisfy { $0.resources.isEmpty })
    #expect(dashboard.providers.allSatisfy { $0.tokenUsageWindows.isEmpty })
    #expect(dashboard.providers.allSatisfy { $0.tokenUsageSeries.isEmpty })
    #expect(dashboard.providers.allSatisfy { $0.spendSeries.isEmpty })
    #expect(dashboard.totals.isEmpty)
}

@MainActor
@Test
func accountCoreKeepsDuplicateProviderTypesAsSeparateReports() async throws {
    let core = try ProviderAccountDashboardCore()
    let period = Dashboard.Period(startUnix: 1, endExclusiveUnix: 2)
    let accounts = [
        ProviderAccount(id: "personal", label: "Personal"),
        ProviderAccount(id: "work", label: "Work"),
    ]

    let refresh = try await core.refresh(.init(
        accountData: [ProviderAccountData(
            type: .digitalOcean,
            accounts: accounts,
            activeIndex: 1
        )],
        period: period,
        trackedLocalSources: [],
        sourceIDs: nil
    ))
    let dashboard = try core.snapshot(period: period)

    #expect(refresh.configuredCount == 0)
    #expect(dashboard.providers.prefix(2).map(\.id) == ["work", "personal"])
    #expect(dashboard.providers.prefix(2).map(\.summary.displayName) == ["Work", "Personal"])
    #expect(dashboard.providers.prefix(2).map(\.summary.providerTypeID) == [
        "digitalocean", "digitalocean",
    ])
    #expect(dashboard.providers.prefix(2).allSatisfy {
        $0.summary.status == .notConfigured
    })
}

@MainActor
@Test
func accountCoreFansOutCloudflareVercelAndOpenRouterAccounts() async throws {
    let core = try ProviderAccountDashboardCore()
    let period = Dashboard.Period(startUnix: 1, endExclusiveUnix: 2)
    let accountData = [
        ProviderAccountData(
            type: .cloudflare,
            accounts: [
                ProviderAccount(id: "cloudflare-personal", label: "Cloudflare Personal"),
                ProviderAccount(id: "cloudflare-work", label: "Cloudflare Work"),
            ],
            activeIndex: 1
        ),
        ProviderAccountData(
            type: .vercel,
            accounts: [
                ProviderAccount(id: "vercel-personal", label: "Vercel Personal"),
                ProviderAccount(id: "vercel-work", label: "Vercel Work"),
            ]
        ),
        ProviderAccountData(
            type: .openRouter,
            accounts: [
                ProviderAccount(id: "openrouter-personal", label: "OpenRouter Personal"),
                ProviderAccount(id: "openrouter-work", label: "OpenRouter Work"),
            ],
            activeIndex: 1
        ),
    ]

    let refresh = try await core.refresh(.init(
        accountData: accountData,
        period: period,
        trackedLocalSources: [],
        sourceIDs: nil
    ))
    let dashboard = try core.snapshot(period: period)
    let requestedProviders = Array(dashboard.providers.prefix(6))

    #expect(refresh.configuredCount == 0)
    #expect(requestedProviders.map(\.id) == [
        "cloudflare-work", "cloudflare-personal",
        "vercel-personal", "vercel-work",
        "openrouter-work", "openrouter-personal",
    ])
    #expect(requestedProviders.map(\.summary.providerTypeID) == [
        "cloudflare", "cloudflare",
        "vercel", "vercel",
        "openrouter", "openrouter",
    ])
    #expect(requestedProviders.allSatisfy {
        $0.summary.status == .notConfigured
    })
}
