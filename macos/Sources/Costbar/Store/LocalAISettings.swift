import Foundation

/// UI preference only. Zig performs the actual local discovery and parsing.
enum LocalAISettings {
    static func trackedSources(defaults: UserDefaults = .standard) -> Set<LocalSource> {
        Set(LocalSource.allCases.filter { defaults.bool(forKey: key(for: $0)) })
    }

    static func save(trackedSources: Set<LocalSource>, defaults: UserDefaults = .standard) {
        for source in LocalSource.allCases {
            defaults.set(trackedSources.contains(source), forKey: key(for: source))
        }
    }

    private static func key(for source: LocalSource) -> String {
        switch source {
        case .codex: "track-codex-local-usage-v1"
        case .claude: "track-claude-local-usage-v1"
        case .opencode: "track-opencode-local-usage-v1"
        }
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
