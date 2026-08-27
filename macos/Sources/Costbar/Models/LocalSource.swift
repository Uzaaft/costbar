import Foundation

/// A coding agent installed on this Mac whose usage Costbar reads locally.
///
/// Unlike ``ProviderAccountType`` these have no stored credentials — the only
/// setting is whether Costbar tracks them. The raw value is the source ID
/// shared with the Zig core.
enum LocalSource: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case opencode

    var id: String { rawValue }

    /// The source ID the Zig core reports this agent under.
    var sourceID: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .opencode: "OpenCode"
        }
    }

    /// What Costbar reads, shown under the tracking toggle.
    var trackingDescription: String {
        switch self {
        case .codex:
            "Uses the active Codex CLI OAuth profile for quota and counts tokens from that profile's local session logs."
        case .claude:
            "Counts Claude Code tokens locally. Subscription quota comes from Claude's status-line rate-limit feed."
        case .opencode:
            "Queries exact cost and token metadata from the installed OpenCode CLI. Prompt and response content is never read."
        }
    }

    static let allSourceIDs = Set(allCases.map(\.sourceID))

    init?(sourceID: String) {
        self.init(rawValue: sourceID)
    }
}
