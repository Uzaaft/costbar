import Foundation

enum AgentActivityState: String, Codable, Sendable {
    case busy
    case waiting
    case success
    case idle
}

enum AgentActivitySummaryState: String, Codable, Sendable {
    case working
    case waiting
    case success
    case idle
}

struct AgentSession: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let name: String
    let detail: String
    let state: AgentActivityState
    let waitingFor: String?
    let sinceUnix: Int64
    let pid: Int32?
}

struct AgentProviderActivity: Identifiable, Equatable, Sendable, Codable {
    let providerId: String
    let profileId: String
    let summary: AgentActivitySummaryState
    let sessions: [AgentSession]

    var id: String { "\(providerId)/\(profileId)" }
}

struct AgentSessionSnapshot: Equatable, Sendable, Codable {
    let generatedAtUnix: Int64
    let anyBusy: Bool
    let anyWaiting: Bool
    let providers: [AgentProviderActivity]
}

struct AgentSessionTransition: Equatable, Sendable, Codable {
    enum Kind: String, Codable, Sendable {
        case finished
        case waiting
    }

    let id: String
    let providerId: String
    let kind: Kind
    let name: String
    let pid: Int32?
}

extension AgentProviderActivity {
    func matches(providerTypeID: String) -> Bool {
        providerId == providerTypeID ||
            (providerTypeID.hasPrefix("codex/") && providerId == "codex")
    }
}
