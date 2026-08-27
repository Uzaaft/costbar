import Foundation

/// One credential field belonging to a provider.
///
/// The raw value is the settings key shared with the Zig core and used as the
/// Keychain account suffix, so it has to stay stable across releases. Every
/// other credential table — the storage field list, the per-provider key list,
/// and the editor bindings — is derived from these cases.
enum ProviderSetting: String, CaseIterable, Identifiable, Sendable {
    case digitalOceanToken = "digitalocean.token"
    case hetznerToken = "hetzner.token"
    case cloudflareToken = "cloudflare.token"
    case cloudflareAccountID = "cloudflare.account-id"
    case runpodAPIKey = "runpod.api-key"
    case vercelToken = "vercel.token"
    case vercelTeamIDOrSlug = "vercel.team"
    case openRouterAPIKey = "openrouter.api-key"
    case openRouterManagementKey = "openrouter.management-key"
    case openAIAdminKey = "openai.admin-key"
    case anthropicAdminKey = "anthropic.admin-key"
    case xAIManagementKey = "xai.management-key"
    case xAITeamID = "xai.team-id"
    case githubToken = "github.token"
    case githubOrganization = "github.organization"
    case cursorAdminKey = "cursor.admin-key"

    var id: String { rawValue }

    /// The settings key understood by the Zig core.
    var key: String { rawValue }

    var keyPath: WritableKeyPath<ProviderCredentials, String?> {
        switch self {
        case .digitalOceanToken: \.digitalOceanToken
        case .hetznerToken: \.hetznerToken
        case .cloudflareToken: \.cloudflareToken
        case .cloudflareAccountID: \.cloudflareAccountID
        case .runpodAPIKey: \.runpodAPIKey
        case .vercelToken: \.vercelToken
        case .vercelTeamIDOrSlug: \.vercelTeamIDOrSlug
        case .openRouterAPIKey: \.openRouterAPIKey
        case .openRouterManagementKey: \.openRouterManagementKey
        case .openAIAdminKey: \.openAIAdminKey
        case .anthropicAdminKey: \.anthropicAdminKey
        case .xAIManagementKey: \.xAIManagementKey
        case .xAITeamID: \.xAITeamID
        case .githubToken: \.githubToken
        case .githubOrganization: \.githubOrganization
        case .cursorAdminKey: \.cursorAdminKey
        }
    }
}
