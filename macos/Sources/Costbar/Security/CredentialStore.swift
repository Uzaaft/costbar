import CostbarKit
import Foundation
import Security

struct ProviderCredentials: Equatable, Sendable {
    var digitalOceanToken: String?
    var ovhEndpoint: String?
    var ovhApplicationKey: String?
    var ovhApplicationSecret: String?
    var ovhConsumerKey: String?
    var ovhProjectID: String?
    var hetznerToken: String?
    var cloudflareToken: String?
    var cloudflareAccountID: String?
    var runpodAPIKey: String?
    var vercelToken: String?
    var vercelTeamIDOrSlug: String?
    var openRouterAPIKey: String?
    var openRouterManagementKey: String?
    var openAIAdminKey: String?
    var anthropicAdminKey: String?
    var xAIManagementKey: String?
    var xAITeamID: String?
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

/// A macOS Keychain adapter only. Each setting is an independent UTF-8 item;
/// provider serialization and interpretation stay in Zig.
@MainActor
final class CredentialStore {
    private struct Field {
        let account: String
        let keyPath: WritableKeyPath<ProviderCredentials, String?>
    }

    private static let fields: [Field] = [
        .init(account: "digitalocean.token", keyPath: \.digitalOceanToken),
        .init(account: "ovh.endpoint", keyPath: \.ovhEndpoint),
        .init(account: "ovh.application-key", keyPath: \.ovhApplicationKey),
        .init(account: "ovh.application-secret", keyPath: \.ovhApplicationSecret),
        .init(account: "ovh.consumer-key", keyPath: \.ovhConsumerKey),
        .init(account: "ovh.project-id", keyPath: \.ovhProjectID),
        .init(account: "hetzner.token", keyPath: \.hetznerToken),
        .init(account: "cloudflare.token", keyPath: \.cloudflareToken),
        .init(account: "cloudflare.account-id", keyPath: \.cloudflareAccountID),
        .init(account: "runpod.api-key", keyPath: \.runpodAPIKey),
        .init(account: "vercel.token", keyPath: \.vercelToken),
        .init(account: "vercel.team", keyPath: \.vercelTeamIDOrSlug),
        .init(account: "openrouter.api-key", keyPath: \.openRouterAPIKey),
        .init(account: "openrouter.management-key", keyPath: \.openRouterManagementKey),
        .init(account: "openai.admin-key", keyPath: \.openAIAdminKey),
        .init(account: "anthropic.admin-key", keyPath: \.anthropicAdminKey),
        .init(account: "xai.management-key", keyPath: \.xAIManagementKey),
        .init(account: "xai.team-id", keyPath: \.xAITeamID),
        .init(account: "github.token", keyPath: \.githubToken),
        .init(account: "github.organization", keyPath: \.githubOrganization),
        .init(account: "cursor.admin-key", keyPath: \.cursorAdminKey),
    ]

    private let service: String
    private let packedAccount = "providers"
    private var cached: ProviderCredentials?

    init(service: String = "com.costbar.provider-credentials") {
        self.service = service
    }

    func load() throws -> ProviderCredentials {
        if let cached { return cached }
        let packed = try loadData(account: packedAccount)
        var credentials = if let packed {
            try decodeLegacyPacked(packed)
        } else {
            ProviderCredentials.empty
        }
        for field in Self.fields {
            guard let data = try loadData(account: field.account),
                  let value = String(data: data, encoding: .utf8)
            else { continue }
            credentials[keyPath: field.keyPath] = value
        }

        if packed != nil {
            try writeFields(credentials)
            try remove(account: packedAccount)
        }
        cached = credentials
        return credentials
    }

    func save(_ credentials: ProviderCredentials) throws {
        try writeFields(credentials)
        cached = credentials
    }

    private func loadData(account: String) throws -> Data? {
        var query = matchQuery(account: account)
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
        return data
    }

    private func decodeLegacyPacked(_ data: Data) throws -> ProviderCredentials {
        var credentials = ProviderCredentials.empty
        for field in Self.fields {
            var value = costbar_bytes_t(ptr: nil, len: 0)
            let key = Data(field.account.utf8)
            let status = data.withUnsafeBytes { jsonBuffer in
                key.withUnsafeBytes { keyBuffer in
                    costbar_decode_credential_json_field(
                        jsonBuffer.costbarBytes,
                        keyBuffer.costbarBytes,
                        &value
                    )
                }
            }
            guard status == COSTBAR_STATUS_OK else {
                throw CredentialStoreError.invalidData
            }
            defer { costbar_bytes_free(value) }
            if let pointer = value.ptr {
                guard let decoded = String(
                    bytes: UnsafeBufferPointer(start: pointer, count: value.len),
                    encoding: .utf8
                ) else {
                    throw CredentialStoreError.invalidData
                }
                credentials[keyPath: field.keyPath] = decoded
            }
        }
        return credentials
    }

    private func writeFields(_ credentials: ProviderCredentials) throws {
        for field in Self.fields {
            let value = credentials[keyPath: field.keyPath]
            if let value, !value.isEmpty {
                try upsert(Data(value.utf8), account: field.account)
            } else {
                try remove(account: field.account)
            }
        }
    }

    private func upsert(_ data: Data, account: String) throws {
        let query = matchQuery(account: account)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
        var insertion = query
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        insertion[kSecValueData as String] = data
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.unexpectedStatus(addStatus)
        }
    }

    private func remove(account: String) throws {
        let status = SecItemDelete(matchQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    private func matchQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

private extension UnsafeRawBufferPointer {
    var costbarBytes: costbar_bytes_t {
        .init(ptr: bindMemory(to: UInt8.self).baseAddress, len: count)
    }
}
