import Foundation

/// Deep links to each provider's credential-creation page, prefilled with the
/// least privilege Costbar needs.
enum ProviderSetupLinks {
    static let digitalOceanToken = requiredURL(
        "https://cloud.digitalocean.com/account/api/tokens/new"
    )
    static let hetznerProjects = requiredURL(
        "https://console.hetzner.cloud/projects"
    )
    static let cloudflareToken = requiredURL(
        "https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=%5B%7B%22key%22%3A%22billing%22%2C%22type%22%3A%22read%22%7D%2C%7B%22key%22%3A%22zone%22%2C%22type%22%3A%22read%22%7D%5D&accountId=%2A&zoneId=all&name=Costbar%20Billing%20Read"
    )
    static let runpodAPIKeys = requiredURL(
        "https://www.console.runpod.io/user/credentials?tab=api-key"
    )
    static let vercelTokens = requiredURL(
        "https://vercel.com/account/settings/tokens"
    )
    static let openRouterAPIKeys = requiredURL(
        "https://openrouter.ai/settings/keys"
    )
    static let openRouterManagementKeys = requiredURL(
        "https://openrouter.ai/settings/management-keys"
    )
    static let openAIAdminKeys = requiredURL(
        "https://platform.openai.com/settings/organization/admin-keys"
    )
    static let anthropicAdminKeys = requiredURL(
        "https://platform.claude.com/settings/admin-keys"
    )
    static let xAIManagementKeys = requiredURL(
        "https://console.x.ai/team/default/settings/management-keys"
    )
    static let cursorDashboard = requiredURL(
        "https://cursor.com/dashboard"
    )

    static func githubToken(organization: String) -> URL {
        var components = requiredComponents(
            "https://github.com/settings/personal-access-tokens/new"
        )
        var queryItems = [
            URLQueryItem(name: "name", value: "Costbar Billing Read"),
            URLQueryItem(
                name: "description",
                value: "Read organization billing data in Costbar"
            ),
            URLQueryItem(name: "expires_in", value: "90"),
        ]
        let organization = organization.trimmingCharacters(in: .whitespacesAndNewlines)
        if !organization.isEmpty {
            queryItems.append(URLQueryItem(name: "target_name", value: organization))
            queryItems.append(
                URLQueryItem(name: "organization_administration", value: "read")
            )
        }
        components.queryItems = queryItems
        return requiredURL(components)
    }

    private static func requiredURL(_ value: String) -> URL {
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid provider setup URL: \(value)")
        }
        return url
    }

    private static func requiredComponents(_ value: String) -> URLComponents {
        guard let components = URLComponents(string: value) else {
            preconditionFailure("Invalid provider setup URL components: \(value)")
        }
        return components
    }

    private static func requiredURL(_ components: URLComponents) -> URL {
        guard let url = components.url else {
            preconditionFailure("Invalid provider setup URL components: \(components)")
        }
        return url
    }
}
