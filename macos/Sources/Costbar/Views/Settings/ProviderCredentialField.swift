import SwiftUI

/// One editable row in a provider's Credentials section.
struct ProviderCredentialField: Identifiable {
  /// A button next to the field that opens the provider's own creation page.
  struct SetupLink {
    let destination: URL
    let actionLabel: String
  }

  enum Entry {
    /// A visible field for non-secret values such as account or team IDs.
    case plain
    case secret(SetupLink?)
  }

  let setting: ProviderSetting
  let title: String
  let entry: Entry

  var id: ProviderSetting { setting }

  static func plain(_ setting: ProviderSetting, _ title: String) -> Self {
    .init(setting: setting, title: title, entry: .plain)
  }

  static func secret(
    _ setting: ProviderSetting,
    _ title: String,
    link destination: URL,
    action actionLabel: String
  ) -> Self {
    .init(
      setting: setting,
      title: title,
      entry: .secret(SetupLink(destination: destination, actionLabel: actionLabel))
    )
  }
}

extension ProviderAccountType {
  /// The credential rows for this provider, in display order.
  ///
  /// GitHub is deliberately empty: it picks between CLI and token auth, so
  /// ``GitHubCredentialSection`` renders it instead.
  var credentialFields: [ProviderCredentialField] {
    switch self {
    case .digitalOcean:
      [.secret(
        .digitalOceanToken,
        "Personal access token",
        link: ProviderSetupLinks.digitalOceanToken,
        action: "Create token"
      )]
    case .hetzner:
      [.secret(
        .hetznerToken,
        "Project API token",
        link: ProviderSetupLinks.hetznerProjects,
        action: "Open projects"
      )]
    case .cloudflare:
      [
        .plain(.cloudflareAccountID, "Account ID"),
        .secret(
          .cloudflareToken,
          "API token",
          link: ProviderSetupLinks.cloudflareToken,
          action: "Create token"
        ),
      ]
    case .runpod:
      [.secret(
        .runpodAPIKey,
        "API key",
        link: ProviderSetupLinks.runpodAPIKeys,
        action: "Create API key"
      )]
    case .vercel:
      [
        .plain(.vercelTeamIDOrSlug, "Team ID or slug (optional)"),
        .secret(
          .vercelToken,
          "Access token",
          link: ProviderSetupLinks.vercelTokens,
          action: "Create token"
        ),
      ]
    case .openRouter:
      [
        .secret(
          .openRouterAPIKey,
          "API key",
          link: ProviderSetupLinks.openRouterAPIKeys,
          action: "Create API key"
        ),
        .secret(
          .openRouterManagementKey,
          "Management key (optional)",
          link: ProviderSetupLinks.openRouterManagementKeys,
          action: "Create management key"
        ),
      ]
    case .openAIAPI:
      [.secret(
        .openAIAdminKey,
        "OpenAI Admin API key",
        link: ProviderSetupLinks.openAIAdminKeys,
        action: "Create admin key"
      )]
    case .anthropicAPI:
      [.secret(
        .anthropicAdminKey,
        "Anthropic Admin API key",
        link: ProviderSetupLinks.anthropicAdminKeys,
        action: "Create admin key"
      )]
    case .xAIAPI:
      [
        .plain(.xAITeamID, "xAI team ID"),
        .secret(
          .xAIManagementKey,
          "xAI Management API key",
          link: ProviderSetupLinks.xAIManagementKeys,
          action: "Create management key"
        ),
      ]
    case .cursor:
      [.secret(
        .cursorAdminKey,
        "Cursor Team Admin API key",
        link: ProviderSetupLinks.cursorDashboard,
        action: "Open dashboard"
      )]
    case .github:
      []
    }
  }

  /// Sits below the credential rows and says where the values come from.
  var credentialHelp: String {
    switch self {
    case .digitalOcean:
      "Choose Custom Scopes with billing:read and droplet:read. The token is shown once."
    case .hetzner:
      "Choose the project, then Security > API Tokens and create a Read token."
    case .cloudflare:
      "The setup link prefills Billing Read and Zone Read permissions."
    case .runpod:
      "Create a read-capable key in Runpod Settings > API Keys."
    case .vercel:
      "Billing exports are available for Pro and Enterprise teams."
    case .openRouter:
      "The management key adds credits, model activity, and daily spend history."
    case .openAIAPI:
      "Use an organization owner Admin key for Costs and Completions usage."
    case .anthropicAPI:
      "Use an organization Admin key for Cost and Messages usage."
    case .xAIAPI:
      "Costbar reads billing usage and prepaid balance; SuperGrok has no public usage API."
    case .cursor:
      "Open Settings > Cursor Admin API Keys in the team dashboard."
    case .github:
      "Select one or more enhanced-billing organizations to include."
    }
  }
}
