import Foundation
import Testing
@testable import Costbar

private struct SetupLinkExpectation {
    let url: URL
    let host: String
    let path: String
    var query: String?
}

@Test
func directProviderSetupLinksOpenExactCredentialPages() {
    let links: [SetupLinkExpectation] = [
        .init(
            url: ProviderSetupLinks.digitalOceanToken,
            host: "cloud.digitalocean.com",
            path: "/account/api/tokens/new"
        ),
        .init(
            url: ProviderSetupLinks.hetznerProjects,
            host: "console.hetzner.cloud",
            path: "/projects"
        ),
        .init(
            url: ProviderSetupLinks.runpodAPIKeys,
            host: "www.console.runpod.io",
            path: "/user/credentials",
            query: "tab=api-key"
        ),
        .init(
            url: ProviderSetupLinks.vercelTokens,
            host: "vercel.com",
            path: "/account/settings/tokens"
        ),
        .init(
            url: ProviderSetupLinks.openRouterAPIKeys,
            host: "openrouter.ai",
            path: "/settings/keys"
        ),
        .init(
            url: ProviderSetupLinks.openRouterManagementKeys,
            host: "openrouter.ai",
            path: "/settings/management-keys"
        ),
        .init(
            url: ProviderSetupLinks.openAIAdminKeys,
            host: "platform.openai.com",
            path: "/settings/organization/admin-keys"
        ),
        .init(
            url: ProviderSetupLinks.anthropicAdminKeys,
            host: "platform.claude.com",
            path: "/settings/admin-keys"
        ),
        .init(
            url: ProviderSetupLinks.xAIManagementKeys,
            host: "console.x.ai",
            path: "/team/default/settings/management-keys"
        ),
        .init(
            url: ProviderSetupLinks.cursorDashboard,
            host: "cursor.com",
            path: "/dashboard"
        ),
    ]

    for link in links {
        #expect(link.url.scheme == "https")
        #expect(link.url.host == link.host)
        #expect(link.url.path == link.path)
        #expect(link.url.query == link.query)
    }
}

@Test
func cloudflareSetupLinkUsesTheCostbarReadOnlyTemplate() throws {
    let url = ProviderSetupLinks.cloudflareToken
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(
        uniqueKeysWithValues: try #require(components.queryItems).map { item in
            (item.name, item.value)
        }
    )

    #expect(url.scheme == "https")
    #expect(url.host == "dash.cloudflare.com")
    #expect(url.path == "/profile/api-tokens")
    #expect(query["accountId"] == "*")
    #expect(query["zoneId"] == "all")
    #expect(query["name"] == "Costbar Billing Read")
    #expect(
        query["permissionGroupKeys"]
            == #"[{"key":"billing","type":"read"},{"key":"zone","type":"read"}]"#
    )
}

@Test
func githubSetupLinkPrefillsOnlyOrganizationAdministrationRead() throws {
    let url = ProviderSetupLinks.githubToken(organization: "uzaaft")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let query = Dictionary(
        uniqueKeysWithValues: try #require(components.queryItems).map { item in
            (item.name, item.value)
        }
    )

    #expect(url.scheme == "https")
    #expect(url.host == "github.com")
    #expect(url.path == "/settings/personal-access-tokens/new")
    #expect(query["name"] == "Costbar Billing Read")
    #expect(query["description"] == "Read organization billing data in Costbar")
    #expect(query["target_name"] == "uzaaft")
    #expect(query["expires_in"] == "90")
    #expect(query["organization_administration"] == "read")
    #expect(query.count == 5)
}

@Test
func githubSetupLinkDoesNotRequestOrganizationAccessWithoutAnOrganization() throws {
    let url = ProviderSetupLinks.githubToken(organization: "")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let queryNames = Set(try #require(components.queryItems).map(\.name))

    #expect(!queryNames.contains("target_name"))
    #expect(!queryNames.contains("organization_administration"))
}
