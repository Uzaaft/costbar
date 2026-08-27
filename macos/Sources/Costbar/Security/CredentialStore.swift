import CostbarKit
import Foundation
import Security

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
    private struct LegacyStoredAccount: Codable {
        let id: String
        let type: ProviderAccountType
        let name: String
        let usesGitHubCLI: Bool
    }

    private struct StoredAccount: Codable {
        let id: String
        let label: String
        let usesGitHubCLI: Bool
    }

    private struct StoredProviderAccountData: Codable {
        let version: Int
        let accounts: [StoredAccount]
        let activeIndex: Int
    }

    private struct StoredAccountFile: Codable {
        let version: Int
        let providers: [String: StoredProviderAccountData]
    }

    private struct StoredAccountReference {
        let id: String
        let type: ProviderAccountType
    }

    private let service: String
    private let packedAccount = "providers"
    private let legacyAccountIndex = "accounts.v2"
    private let accountIndex = "accounts.v3"
    private let accountPrefix = "account.v2."
    private let deletionMarkerSuffix = ".deleted"
    private var cached: ProviderCredentials?
    private var cachedAccountData: [ProviderAccountData]?

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
        for setting in ProviderSetting.allCases {
            if let data = try loadData(account: setting.key) {
                guard let value = String(data: data, encoding: .utf8) else {
                    throw CredentialStoreError.invalidData
                }
                credentials[setting: setting] = value
            } else if try loadData(account: deletionMarker(for: setting)) != nil {
                credentials[setting: setting] = nil
            }
        }
        cached = credentials
        return credentials
    }

    func save(_ credentials: ProviderCredentials) throws {
        try writeFields(credentials)
        cached = credentials
        cachedAccountData = nil
    }

    func loadAccountData() throws -> [ProviderAccountData] {
        if let cachedAccountData { return cachedAccountData }

        let loaded: [ProviderAccountData]
        if let indexData = try loadData(account: accountIndex) {
            loaded = try decodeAccountData(indexData)
        } else if let legacyData = try loadData(account: legacyAccountIndex) {
            loaded = try decodeLegacyAccounts(legacyData)
        } else {
            let credentials = try load()
            loaded = ProviderAccountType.allCases.compactMap { type in
                let values = Dictionary(uniqueKeysWithValues: type.settings.compactMap { setting in
                    credentials[setting: setting].map { (setting.key, $0) }
                })
                guard !values.isEmpty else { return nil }
                return ProviderAccountData(
                    type: type,
                    accounts: [ProviderAccount(label: type.displayName, values: values)]
                )
            }
        }
        try validate(loaded)
        cachedAccountData = loaded
        return loaded
    }

    func saveAccountData(_ providerData: [ProviderAccountData]) throws {
        try validate(providerData)
        let previous = try storedAccountReferences()
        let encoded: Data
        do {
            let providers = Dictionary(uniqueKeysWithValues: providerData.map { data in
                (
                    data.type.rawValue,
                    StoredProviderAccountData(
                        version: data.version,
                        accounts: data.accounts.map {
                            StoredAccount(
                                id: $0.id,
                                label: $0.displayName,
                                usesGitHubCLI: $0.usesGitHubCLI
                            )
                        },
                        activeIndex: data.clampedActiveIndex
                    )
                )
            })
            encoded = try JSONEncoder().encode(StoredAccountFile(version: 1, providers: providers))
        } catch {
            throw CredentialStoreError.invalidData
        }

        for data in providerData {
            for account in data.accounts {
                for setting in data.type.settings {
                    let item = accountKey(account.id, setting)
                    if let value = account.values[setting.key], !value.isEmpty {
                        try upsert(Data(value.utf8), account: item)
                    } else {
                        try remove(account: item)
                    }
                }
            }
        }
        // Publish the new index before deleting fields it no longer references.
        // If cleanup fails, the worst case is an unreachable Keychain item,
        // never an index that points at a credential already removed.
        try upsert(encoded, account: accountIndex)
        let current = Dictionary(uniqueKeysWithValues: providerData.flatMap { data in
            data.accounts.map { ($0.id, data.type) }
        })
        for account in previous {
            let retained = Set(current[account.id]?.settings ?? [])
            for setting in account.type.settings where !retained.contains(setting) {
                try remove(account: accountKey(account.id, setting))
            }
        }
        cachedAccountData = providerData
    }

    private func decodeAccountData(_ data: Data) throws -> [ProviderAccountData] {
        let stored: StoredAccountFile
        do {
            stored = try JSONDecoder().decode(StoredAccountFile.self, from: data)
        } catch {
            throw CredentialStoreError.invalidData
        }
        guard stored.version == 1 else { throw CredentialStoreError.invalidData }
        return try ProviderAccountType.allCases.compactMap { type in
            guard let provider = stored.providers[type.rawValue] else { return nil }
            let accounts = try provider.accounts.map { account in
                ProviderAccount(
                    id: account.id,
                    label: account.label,
                    values: try loadValues(accountID: account.id, type: type),
                    usesGitHubCLI: account.usesGitHubCLI
                )
            }
            return ProviderAccountData(
                type: type,
                version: provider.version,
                accounts: accounts,
                activeIndex: provider.activeIndex
            )
        }
    }

    private func decodeLegacyAccounts(_ data: Data) throws -> [ProviderAccountData] {
        let legacy: [LegacyStoredAccount]
        do {
            legacy = try JSONDecoder().decode([LegacyStoredAccount].self, from: data)
        } catch {
            throw CredentialStoreError.invalidData
        }
        return try ProviderAccountType.allCases.compactMap { type in
            let accounts = try legacy.filter { $0.type == type }.map { account in
                ProviderAccount(
                    id: account.id,
                    label: account.name,
                    values: try loadValues(accountID: account.id, type: type),
                    usesGitHubCLI: account.usesGitHubCLI
                )
            }
            guard !accounts.isEmpty else { return nil }
            return ProviderAccountData(type: type, accounts: accounts)
        }
    }

    private func loadValues(
        accountID: String,
        type: ProviderAccountType
    ) throws -> [String: String] {
        var values: [String: String] = [:]
        for setting in type.settings {
            guard let data = try loadData(account: accountKey(accountID, setting)) else { continue }
            guard let value = String(data: data, encoding: .utf8) else {
                throw CredentialStoreError.invalidData
            }
            values[setting.key] = value
        }
        return values
    }

    private func storedAccountReferences() throws -> [StoredAccountReference] {
        if let data = try loadData(account: accountIndex) {
            let stored: StoredAccountFile
            do {
                stored = try JSONDecoder().decode(StoredAccountFile.self, from: data)
            } catch {
                throw CredentialStoreError.invalidData
            }
            return try stored.providers.flatMap { rawType, provider in
                guard let type = ProviderAccountType(rawValue: rawType) else {
                    throw CredentialStoreError.invalidData
                }
                return provider.accounts.map { StoredAccountReference(id: $0.id, type: type) }
            }
        }
        guard let data = try loadData(account: legacyAccountIndex) else { return [] }
        do {
            return try JSONDecoder().decode([LegacyStoredAccount].self, from: data).map {
                StoredAccountReference(id: $0.id, type: $0.type)
            }
        } catch {
            throw CredentialStoreError.invalidData
        }
    }

    private func validate(_ providerData: [ProviderAccountData]) throws {
        guard Set(providerData.map(\.type)).count == providerData.count else {
            throw CredentialStoreError.invalidData
        }
        let accounts = providerData.flatMap(\.accounts)
        guard Set(accounts.map(\.id)).count == accounts.count else {
            throw CredentialStoreError.invalidData
        }
    }

    private func accountKey(_ id: String, _ setting: ProviderSetting) -> String {
        accountPrefix + id + "." + setting.key
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
        for setting in ProviderSetting.allCases {
            var value = costbar_bytes_t(ptr: nil, len: 0)
            let key = Data(setting.key.utf8)
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
                credentials[setting: setting] = decoded
            }
        }
        return credentials
    }

    private func writeFields(_ credentials: ProviderCredentials) throws {
        // Keep the original packed record as a read-only recovery source. A
        // tombstone distinguishes an intentional deletion from a field that
        // has not yet been migrated, without Swift re-encoding provider JSON.
        let hasLegacyFallback = try loadData(account: packedAccount) != nil
        for setting in ProviderSetting.allCases {
            let value = credentials[setting: setting]
            if let value, !value.isEmpty {
                try upsert(Data(value.utf8), account: setting.key)
                try remove(account: deletionMarker(for: setting))
            } else {
                try remove(account: setting.key)
                if hasLegacyFallback {
                    try upsert(Data([1]), account: deletionMarker(for: setting))
                } else {
                    try remove(account: deletionMarker(for: setting))
                }
            }
        }
    }

    private func deletionMarker(for setting: ProviderSetting) -> String {
        setting.key + deletionMarkerSuffix
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
