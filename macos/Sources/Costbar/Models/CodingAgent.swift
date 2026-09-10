import Foundation

/// The coding agents whose subscription quota the notch shows, in rail order.
///
/// These are the tools people glance at while working. The question is "how
/// much of my session is left", not "what did this cost", so they get rings
/// rather than dollar rows.
enum CodingAgent: String, CaseIterable, Identifiable, Sendable {
    case claude
    case cursor
    case codex

    var id: String { rawValue }

    /// Matches `Dashboard.ProviderSummary.providerTypeID`.
    var providerTypeID: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .cursor: "Cursor"
        case .codex: "Codex"
        }
    }

    /// What clicking the ring opens, phrased for an "Open …" toggle.
    var launchLabel: String {
        switch self {
        case .claude: "claude.ai"
        case .cursor: "Cursor"
        case .codex: "Codex"
        }
    }

    /// Installed apps to prefer over the web fallback.
    var bundleIdentifiers: [String] {
        switch self {
        case .claude: ["com.anthropic.claudefordesktop"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        case .codex: ["com.openai.codex"]
        }
    }

    /// Opened when none of `bundleIdentifiers` is installed.
    var fallbackURL: URL {
        switch self {
        case .claude: Self.requiredURL("https://claude.ai")
        case .cursor: ProviderSetupLinks.cursorDashboard
        case .codex: Self.requiredURL("https://chatgpt.com/codex")
        }
    }

    init?(providerTypeID: String) {
        if providerTypeID == "cursor-local" {
            self = .cursor
            return
        }
        self.init(rawValue: providerTypeID)
    }

    static let providerTypeIDs = Set(allCases.map(\.providerTypeID))

    /// The agent reports worth a ring, in rail order. Accounts that were never
    /// configured are left out; a configured one that failed to refresh keeps
    /// its place so the gap is visible.
    /// IDs that belong on the quota rail, including Cursor's local allowance
    /// provider which is distinct from team-admin billing.
    static let ringTypeIDs: Set<String> = ["claude", "codex", "cursor", "cursor-local"]

    static func reports(in dashboard: Dashboard?) -> [Dashboard.ProviderReport] {
        guard let providers = dashboard?.providers else { return [] }
        let hasCursorLocal = providers.contains {
            $0.summary.providerTypeID == "cursor-local" && $0.summary.status != .notConfigured
        }
        return allCases.flatMap { agent in
            providers.filter { report in
                let typeID = report.summary.providerTypeID
                let matches = switch agent {
                case .cursor:
                    typeID == "cursor-local" || (!hasCursorLocal && typeID == "cursor")
                default:
                    typeID == agent.providerTypeID
                }
                return matches && report.summary.status != .notConfigured
            }
        }
    }

    private static func requiredURL(_ value: String) -> URL {
        guard let url = URL(string: value) else {
            preconditionFailure("Invalid agent URL: \(value)")
        }
        return url
    }
}
