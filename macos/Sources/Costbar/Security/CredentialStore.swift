import Foundation
import Security

struct ProviderCredentials: Codable, Equatable, Sendable {
    var digitalOceanToken: String?
    var cloudflareToken: String?
    var cloudflareAccountID: String?
    var runpodAPIKey: String?
    var vercelToken: String?
    var vercelTeamIDOrSlug: String?
    var openRouterAPIKey: String?
    var openRouterManagementKey: String?
    var openAIAdminKey: String?
    var anthropicAdminKey: String?
    var githubToken: String?
    var githubOrganization: String?
    var cursorAdminKey: String?

    static let empty = ProviderCredentials()
}

enum CredentialStoreError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatus(status):
            SecCopyErrorMessageString(status, nil) as String? ??
                "Keychain returned status \(status)."
        case .invalidData:
            "The saved provider credentials are invalid."
        }
    }
}

/// Keeps all provider settings in one login-Keychain item. The decoded value is
/// cached for the process lifetime so refreshes do not repeatedly ask Keychain
/// for each individual field.
@MainActor
final class CredentialStore {
    private enum LegacyAccount: String, CaseIterable {
        case digitalOceanToken = "digitalocean.token"
        case cloudflareToken = "cloudflare.token"
        case cloudflareAccountID = "cloudflare.account-id"
    }

    private let service = "com.costbar.provider-credentials"
    private let account = "providers"
    private var cached: ProviderCredentials?

    func load() throws -> ProviderCredentials {
        if let cached { return cached }

        if let stored = try loadPacked() {
            cached = stored
            return stored
        }

        let migrated = try loadLegacy()
        if migrated != .empty {
            try writePacked(migrated)
        }
        cached = migrated
        return migrated
    }

    func save(_ credentials: ProviderCredentials) throws {
        try writePacked(credentials)
        cached = credentials
    }

    private func loadPacked() throws -> ProviderCredentials? {
        var query = packedQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
        guard let data = result as? Data else {
            throw CredentialStoreError.invalidData
        }
        do {
            return try JSONDecoder().decode(ProviderCredentials.self, from: data)
        } catch {
            throw CredentialStoreError.invalidData
        }
    }

    /// Imports the original one-item-per-field layout with one Keychain query.
    /// Old records are left untouched; the packed record takes precedence on
    /// every subsequent launch.
    private func loadLegacy() throws -> ProviderCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .empty }
        guard status == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
        guard let items = result as? [[String: Any]] else {
            throw CredentialStoreError.invalidData
        }

        var credentials = ProviderCredentials.empty
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data,
                  let value = String(data: data, encoding: .utf8)
            else {
                continue
            }
            switch LegacyAccount(rawValue: account) {
            case .digitalOceanToken:
                credentials.digitalOceanToken = value
            case .cloudflareToken:
                credentials.cloudflareToken = value
            case .cloudflareAccountID:
                credentials.cloudflareAccountID = value
            case nil:
                continue
            }
        }
        return credentials
    }

    private func writePacked(_ credentials: ProviderCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            packedQuery as CFDictionary,
            update as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(updateStatus)
        }

        var insertion = packedQuery
        insertion[kSecValueData as String] = data
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(addStatus)
        }
    }

    private var packedQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
    }
}
