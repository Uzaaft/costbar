import Foundation

/// The credential values for a single account, keyed by ``ProviderSetting``.
struct ProviderCredentials: Equatable, Sendable {
    var digitalOceanToken: String?
    var hetznerToken: String?
    var cloudflareToken: String?
    var cloudflareAccountID: String?
    var runpodAPIKey: String?
    var vercelToken: String?
    var vercelTeamIDOrSlug: String?
    var openRouterAPIKey: String?
    var openRouterManagementKey: String?
    var openAIAdminKey: String?
    var anthropicAdminKey: String?
    var xAIManagementKey: String?
    var xAITeamID: String?
    var githubToken: String?
    var githubOrganization: String?
    var cursorAdminKey: String?

    static let empty = ProviderCredentials()

    subscript(setting setting: ProviderSetting) -> String? {
        get { self[keyPath: setting.keyPath] }
        set { self[keyPath: setting.keyPath] = newValue }
    }

    /// Every credential as a `(key, value)` pair for the Zig core.
    var coreSettings: [(String, String?)] {
        ProviderSetting.allCases.map { ($0.key, self[setting: $0]) }
    }
}

enum ProviderAccountType: String, CaseIterable, Codable, Identifiable, Sendable {
    case digitalOcean = "digitalocean"
    case hetzner
    case cloudflare
    case runpod
    case vercel
    case openRouter = "openrouter"
    case openAIAPI = "openai-api"
    case anthropicAPI = "anthropic-api"
    case xAIAPI = "xai-api"
    case github
    case cursor

    var id: String { rawValue }
    var sourceID: String { rawValue }

    var displayName: String {
        switch self {
        case .digitalOcean: "DigitalOcean"
        case .hetzner: "Hetzner Cloud"
        case .cloudflare: "Cloudflare"
        case .runpod: "Runpod"
        case .vercel: "Vercel"
        case .openRouter: "OpenRouter"
        case .openAIAPI: "OpenAI API"
        case .anthropicAPI: "Anthropic API"
        case .xAIAPI: "xAI (Grok) API"
        case .github: "GitHub"
        case .cursor: "Cursor"
        }
    }

    var settings: [ProviderSetting] {
        switch self {
        case .digitalOcean: [.digitalOceanToken]
        case .hetzner: [.hetznerToken]
        case .cloudflare: [.cloudflareToken, .cloudflareAccountID]
        case .runpod: [.runpodAPIKey]
        case .vercel: [.vercelToken, .vercelTeamIDOrSlug]
        case .openRouter: [.openRouterAPIKey, .openRouterManagementKey]
        case .openAIAPI: [.openAIAdminKey]
        case .anthropicAPI: [.anthropicAdminKey]
        case .xAIAPI: [.xAIManagementKey, .xAITeamID]
        case .github: [.githubToken, .githubOrganization]
        case .cursor: [.cursorAdminKey]
        }
    }

    var settingKeys: [String] { settings.map(\.key) }

    var dashboardKind: String {
        switch self {
        case .digitalOcean, .hetzner, .cloudflare, .runpod, .vercel:
            "cloud"
        case .openRouter, .openAIAPI, .anthropicAPI, .xAIAPI, .cursor:
            "ai"
        case .github:
            "developer_tool"
        }
    }
}

struct ProviderAccount: Identifiable, Equatable, Sendable {
    let id: String
    var label: String
    var values: [String: String]
    var usesGitHubCLI: Bool

    init(
        id: String = UUID().uuidString.lowercased(),
        label: String,
        values: [String: String] = [:],
        usesGitHubCLI: Bool = false
    ) {
        self.id = id
        self.label = label
        self.values = values
        self.usesGitHubCLI = usesGitHubCLI
    }

    var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Account" : trimmed
    }

    func credentials(for type: ProviderAccountType) -> ProviderCredentials {
        var result = ProviderCredentials.empty
        for setting in type.settings {
            result[setting: setting] = values[setting.key]
        }
        return result
    }
}

/// The account list belongs to a provider configuration. This mirrors the
/// provider-owned token-account model: one provider, many credential records,
/// and one stable active selection.
struct ProviderAccountData: Identifiable, Equatable, Sendable {
    static let currentVersion = 1

    let type: ProviderAccountType
    var version: Int
    var accounts: [ProviderAccount]
    var activeIndex: Int

    init(
        type: ProviderAccountType,
        version: Int = Self.currentVersion,
        accounts: [ProviderAccount],
        activeIndex: Int = 0
    ) {
        self.type = type
        self.version = version
        self.accounts = accounts
        self.activeIndex = activeIndex
    }

    var id: ProviderAccountType { type }

    var clampedActiveIndex: Int {
        guard !accounts.isEmpty else { return 0 }
        return min(max(activeIndex, 0), accounts.count - 1)
    }

    var activeAccount: ProviderAccount? {
        guard !accounts.isEmpty else { return nil }
        return accounts[clampedActiveIndex]
    }
}
