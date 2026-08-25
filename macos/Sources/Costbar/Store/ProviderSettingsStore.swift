import Foundation

@MainActor
final class ProviderSettingsStore: ObservableObject {
    @Published var digitalOceanToken = ""
    @Published var ovhEndpoint = "ovh-eu"
    @Published var ovhApplicationKey = ""
    @Published var ovhApplicationSecret = ""
    @Published var ovhConsumerKey = ""
    @Published var ovhProjectID = ""
    @Published var hetznerToken = ""
    @Published var cloudflareToken = ""
    @Published var cloudflareAccountID = ""
    @Published var runpodAPIKey = ""
    @Published var vercelToken = ""
    @Published var vercelTeamIDOrSlug = ""
    @Published var openRouterAPIKey = ""
    @Published var openRouterManagementKey = ""
    @Published var openAIAdminKey = ""
    @Published var anthropicAdminKey = ""
    @Published var xAIManagementKey = ""
    @Published var xAITeamID = ""
    @Published var githubToken = ""
    @Published var githubOrganization = ""
    @Published var usesGitHubCLI = false
    @Published var cursorAdminKey = ""
    @Published var tracksCodexUsage = false
    @Published var tracksClaudeUsage = false
    @Published var tracksOpenCodeUsage = false
    @Published private(set) var hasClaudeStatusBridge = false
    @Published private(set) var message: String?

    private let credentials: CredentialStore

    init(credentials: CredentialStore) {
        self.credentials = credentials
        reload()
    }

    func save() -> Bool {
        do {
            try credentials.save(.init(
                digitalOceanToken: digitalOceanToken.trimmedOrNil,
                ovhEndpoint: ovhEndpoint.trimmedOrNil,
                ovhApplicationKey: ovhApplicationKey.trimmedOrNil,
                ovhApplicationSecret: ovhApplicationSecret.trimmedOrNil,
                ovhConsumerKey: ovhConsumerKey.trimmedOrNil,
                ovhProjectID: ovhProjectID.trimmedOrNil,
                hetznerToken: hetznerToken.trimmedOrNil,
                cloudflareToken: cloudflareToken.trimmedOrNil,
                cloudflareAccountID: cloudflareAccountID.trimmedOrNil,
                runpodAPIKey: runpodAPIKey.trimmedOrNil,
                vercelToken: vercelToken.trimmedOrNil,
                vercelTeamIDOrSlug: vercelTeamIDOrSlug.trimmedOrNil,
                openRouterAPIKey: openRouterAPIKey.trimmedOrNil,
                openRouterManagementKey: openRouterManagementKey.trimmedOrNil,
                openAIAdminKey: openAIAdminKey.trimmedOrNil,
                anthropicAdminKey: anthropicAdminKey.trimmedOrNil,
                xAIManagementKey: xAIManagementKey.trimmedOrNil,
                xAITeamID: xAITeamID.trimmedOrNil,
                githubToken: githubToken.trimmedOrNil,
                githubOrganization: githubOrganization.trimmedOrNil,
                cursorAdminKey: cursorAdminKey.trimmedOrNil
            ))
            LocalAISettings.save(
                tracksCodex: tracksCodexUsage,
                tracksClaude: tracksClaudeUsage,
                tracksOpenCode: tracksOpenCodeUsage
            )
            CLIAuthSettings.saveGitHubCLI(usesGitHubCLI)
            message = "Settings saved. Credentials remain in Keychain."
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    private func reload() {
        do {
            let saved = try credentials.load()
            digitalOceanToken = saved.digitalOceanToken ?? ""
            ovhEndpoint = saved.ovhEndpoint ?? "ovh-eu"
            ovhApplicationKey = saved.ovhApplicationKey ?? ""
            ovhApplicationSecret = saved.ovhApplicationSecret ?? ""
            ovhConsumerKey = saved.ovhConsumerKey ?? ""
            ovhProjectID = saved.ovhProjectID ?? ""
            hetznerToken = saved.hetznerToken ?? ""
            cloudflareToken = saved.cloudflareToken ?? ""
            cloudflareAccountID = saved.cloudflareAccountID ?? ""
            runpodAPIKey = saved.runpodAPIKey ?? ""
            vercelToken = saved.vercelToken ?? ""
            vercelTeamIDOrSlug = saved.vercelTeamIDOrSlug ?? ""
            openRouterAPIKey = saved.openRouterAPIKey ?? ""
            openRouterManagementKey = saved.openRouterManagementKey ?? ""
            openAIAdminKey = saved.openAIAdminKey ?? ""
            anthropicAdminKey = saved.anthropicAdminKey ?? ""
            xAIManagementKey = saved.xAIManagementKey ?? ""
            xAITeamID = saved.xAITeamID ?? ""
            githubToken = saved.githubToken ?? ""
            githubOrganization = saved.githubOrganization ?? ""
            cursorAdminKey = saved.cursorAdminKey ?? ""
        } catch {
            message = error.localizedDescription
        }
        tracksCodexUsage = LocalAISettings.tracksCodex()
        tracksClaudeUsage = LocalAISettings.tracksClaude()
        tracksOpenCodeUsage = LocalAISettings.tracksOpenCode()
        usesGitHubCLI = CLIAuthSettings.usesGitHubCLI()
        hasClaudeStatusBridge = ClaudeStatusLineBridge.isInstalled
    }

    func installClaudeStatusBridge() {
        do {
            try ClaudeStatusLineBridge.install()
            hasClaudeStatusBridge = true
            message = "Claude subscription quota bridge installed."
        } catch {
            message = error.localizedDescription
        }
    }

    func restoreClaudeStatusLine() {
        do {
            try ClaudeStatusLineBridge.restore()
            hasClaudeStatusBridge = false
            message = "Previous Claude status line restored."
        } catch {
            message = error.localizedDescription
        }
    }
}

private extension String {
    var trimmedOrNil: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
