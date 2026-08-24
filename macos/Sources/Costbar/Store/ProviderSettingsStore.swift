import Foundation

@MainActor
final class ProviderSettingsStore: ObservableObject {
    @Published var digitalOceanToken = ""
    @Published var cloudflareToken = ""
    @Published var cloudflareAccountID = ""
    @Published var runpodAPIKey = ""
    @Published var vercelToken = ""
    @Published var vercelTeamIDOrSlug = ""
    @Published var openRouterAPIKey = ""
    @Published var openRouterManagementKey = ""
    @Published var openAIAdminKey = ""
    @Published var anthropicAdminKey = ""
    @Published var githubToken = ""
    @Published var githubOrganization = ""
    @Published var cursorAdminKey = ""
    @Published var subscriptions: [RecurringSubscription] = []
    @Published var tracksCodexUsage = false
    @Published var tracksClaudeUsage = false
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
                cloudflareToken: cloudflareToken.trimmedOrNil,
                cloudflareAccountID: cloudflareAccountID.trimmedOrNil,
                runpodAPIKey: runpodAPIKey.trimmedOrNil,
                vercelToken: vercelToken.trimmedOrNil,
                vercelTeamIDOrSlug: vercelTeamIDOrSlug.trimmedOrNil,
                openRouterAPIKey: openRouterAPIKey.trimmedOrNil,
                openRouterManagementKey: openRouterManagementKey.trimmedOrNil,
                openAIAdminKey: openAIAdminKey.trimmedOrNil,
                anthropicAdminKey: anthropicAdminKey.trimmedOrNil,
                githubToken: githubToken.trimmedOrNil,
                githubOrganization: githubOrganization.trimmedOrNil,
                cursorAdminKey: cursorAdminKey.trimmedOrNil
            ))
            SubscriptionSettings.save(subscriptions)
            LocalAISettings.save(
                tracksCodex: tracksCodexUsage,
                tracksClaude: tracksClaudeUsage
            )
            message = "Credentials saved in Keychain."
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
            cloudflareToken = saved.cloudflareToken ?? ""
            cloudflareAccountID = saved.cloudflareAccountID ?? ""
            runpodAPIKey = saved.runpodAPIKey ?? ""
            vercelToken = saved.vercelToken ?? ""
            vercelTeamIDOrSlug = saved.vercelTeamIDOrSlug ?? ""
            openRouterAPIKey = saved.openRouterAPIKey ?? ""
            openRouterManagementKey = saved.openRouterManagementKey ?? ""
            openAIAdminKey = saved.openAIAdminKey ?? ""
            anthropicAdminKey = saved.anthropicAdminKey ?? ""
            githubToken = saved.githubToken ?? ""
            githubOrganization = saved.githubOrganization ?? ""
            cursorAdminKey = saved.cursorAdminKey ?? ""
        } catch {
            message = error.localizedDescription
        }
        subscriptions = SubscriptionSettings.load()
        tracksCodexUsage = LocalAISettings.tracksCodex()
        tracksClaudeUsage = LocalAISettings.tracksClaude()
        hasClaudeStatusBridge = ClaudeStatusLineBridge.isInstalled
    }

    func addSubscription() {
        subscriptions.append(.empty())
    }

    func removeSubscription(id: String) {
        subscriptions.removeAll { $0.id == id }
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
