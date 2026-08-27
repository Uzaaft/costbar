import Foundation

// The Codex CLI owns these accounts; Costbar only reads their auth.json and
// keeps its own managed profiles beside the system login.

struct ManagedCodexAccount: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let email: String
    let accountID: String?
    let workspaceLabel: String?
    let homePath: String
    let createdAt: Date
    let lastAuthenticatedAt: Date

    var displayName: String {
        guard let workspaceLabel, !workspaceLabel.isEmpty else { return email }
        return "\(email) — \(workspaceLabel)"
    }
}

struct VisibleCodexAccount: Equatable, Identifiable, Sendable {
    let id: String
    let email: String
    let accountID: String?
    let workspaceLabel: String?
    let homePath: String
    let managedAccountID: UUID?
    let isSystem: Bool
    let isActive: Bool

    var displayName: String {
        guard let workspaceLabel, !workspaceLabel.isEmpty else { return email }
        return "\(email) — \(workspaceLabel)"
    }

    var cacheKey: String {
        managedAccountID.map { "codex-\($0.uuidString.lowercased())" } ?? "codex-system"
    }
}

struct CodexAccountSnapshot: Equatable, Sendable {
    let accounts: [VisibleCodexAccount]
    let activeAccountID: String?
    let systemAccountID: String?
    let ambientHomePath: String

    var activeAccount: VisibleCodexAccount? {
        guard let activeAccountID else { return nil }
        return accounts.first { $0.id == activeAccountID }
    }

    var refreshHomePath: String {
        activeAccount?.homePath ?? ambientHomePath
    }

    var refreshCacheKey: String {
        activeAccount?.cacheKey ?? "codex-system"
    }
}

enum CodexAccountManagerError: Error, LocalizedError, Equatable {
    case codexCLINotFound
    case loginInProgress
    case loginTimedOut
    case loginFailed(Int32, String)
    case authFileMissing
    case authFileInvalid
    case accountIdentityMissing
    case accountNotFound
    case systemAccountCannotBePreserved
    case unsafeManagedHome
    case workspaceSelectionCancelled

    var errorDescription: String? {
        switch self {
        case .codexCLINotFound:
            "The Codex CLI is not installed or could not be found."
        case .loginInProgress:
            "A Codex login is already in progress."
        case .loginTimedOut:
            "Codex login timed out. Try again and finish the browser sign-in within two minutes."
        case let .loginFailed(status, output):
            output.isEmpty
                ? "Codex login failed with status \(status)."
                : "Codex login failed with status \(status): \(output)"
        case .authFileMissing:
            "Codex login completed without creating auth.json."
        case .authFileInvalid:
            "The Codex OAuth credential file is invalid."
        case .accountIdentityMissing:
            "The Codex OAuth credential does not contain an account email."
        case .accountNotFound:
            "That Codex account is no longer available."
        case .systemAccountCannotBePreserved:
            "The current system Codex account could not be identified, so Costbar left it unchanged."
        case .unsafeManagedHome:
            "Costbar refused to modify a Codex profile outside its managed account directory."
        case .workspaceSelectionCancelled:
            "Codex workspace selection was cancelled."
        }
    }
}

struct CodexAuthIdentity: Equatable, Sendable {
    let email: String
    let accountID: String?
    let workspaceLabel: String?
    let fingerprint: String

    var matchingKey: String {
        if let accountID { return "account:\(accountID.lowercased())" }
        return "email:\(email.lowercased())"
    }
}

struct CodexWorkspace: Decodable, Equatable, Sendable {
    let id: String
    let name: String?

    var normalizedID: String {
        id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var displayName: String {
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Personal" : value
    }
}

/// CodexBar-style Codex account management. OAuth remains owned by the Codex
/// CLI: each added account gets an isolated CODEX_HOME, and Costbar only reads
/// or atomically copies the CLI's auth.json file.
