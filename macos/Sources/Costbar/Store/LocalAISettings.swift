import Foundation

/// UI preference only. Zig performs the actual local discovery and parsing.
enum LocalAISettings {
    private static let codexKey = "track-codex-local-usage-v1"
    private static let claudeKey = "track-claude-local-usage-v1"
    private static let openCodeKey = "track-opencode-local-usage-v1"

    static func tracksCodex(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: codexKey)
    }

    static func tracksClaude(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: claudeKey)
    }

    static func tracksOpenCode(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: openCodeKey)
    }

    static func save(
        tracksCodex: Bool,
        tracksClaude: Bool,
        tracksOpenCode: Bool,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(tracksCodex, forKey: codexKey)
        defaults.set(tracksClaude, forKey: claudeKey)
        defaults.set(tracksOpenCode, forKey: openCodeKey)
    }
}

/// UI preference only. Zig owns CLI discovery, execution, and API decoding.
enum CLIAuthSettings {
    private static let githubKey = "use-github-cli-auth-v1"

    static func usesGitHubCLI(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: githubKey)
    }

    static func saveGitHubCLI(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: githubKey)
    }
}
