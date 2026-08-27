import Foundation
import Security
import Testing
@testable import Costbar

@MainActor
@Test
func credentialStoreUsesAccountScopedKeychainQueries() throws {
    let service = "com.costbar.tests.credentials.\(UUID().uuidString)"
    defer {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    var expected = ProviderCredentials.empty
    expected.cloudflareToken = "test-token"
    expected.cloudflareAccountID = "test-account"
    expected.hetznerToken = "hetzner-token"
    expected.xAIManagementKey = "xai-management-key"
    expected.xAITeamID = "team_123"

    try CredentialStore(service: service).save(expected)
    let actual = try CredentialStore(service: service).load()

    #expect(actual == expected)
}

@MainActor
@Test
func credentialStoreKeepsMultipleAccountsOfTheSameTypeIsolated() throws {
    let service = "com.costbar.tests.multiple-accounts.\(UUID().uuidString)"
    defer {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    let personal = ProviderAccount(
        id: "personal",
        label: "Personal",
        values: ["openai.admin-key": "personal-key"]
    )
    let work = ProviderAccount(
        id: "work",
        label: "Work",
        values: ["openai.admin-key": "work-key"]
    )
    let accountData = ProviderAccountData(
        type: .openAIAPI,
        accounts: [personal, work],
        activeIndex: 1
    )
    let store = CredentialStore(service: service)
    try store.saveAccountData([accountData])

    #expect(try CredentialStore(service: service).loadAccountData() == [accountData])

    let remaining = ProviderAccountData(type: .openAIAPI, accounts: [work])
    try store.saveAccountData([remaining])
    #expect(try CredentialStore(service: service).loadAccountData() == [remaining])

    let removedSecretStatus = SecItemCopyMatching([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "account.v2.personal.openai.admin-key",
    ] as CFDictionary, nil)
    #expect(removedSecretStatus == errSecItemNotFound)
}

@MainActor
@Test
func credentialStoreKeepsCloudflareVercelAndOpenRouterAccountsIsolated() throws {
    let service = "com.costbar.tests.requested-multiple-accounts.\(UUID().uuidString)"
    defer {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    let accountData = [
        ProviderAccountData(
            type: .cloudflare,
            accounts: [
                ProviderAccount(
                    id: "cloudflare-personal",
                    label: "Personal",
                    values: [
                        "cloudflare.token": "cloudflare-personal-token",
                        "cloudflare.account-id": "cloudflare-personal-id",
                    ]
                ),
                ProviderAccount(
                    id: "cloudflare-work",
                    label: "Work",
                    values: [
                        "cloudflare.token": "cloudflare-work-token",
                        "cloudflare.account-id": "cloudflare-work-id",
                    ]
                ),
            ],
            activeIndex: 1
        ),
        ProviderAccountData(
            type: .vercel,
            accounts: [
                ProviderAccount(
                    id: "vercel-personal",
                    label: "Personal",
                    values: [
                        "vercel.token": "vercel-personal-token",
                        "vercel.team": "personal-team",
                    ]
                ),
                ProviderAccount(
                    id: "vercel-work",
                    label: "Work",
                    values: [
                        "vercel.token": "vercel-work-token",
                        "vercel.team": "work-team",
                    ]
                ),
            ],
            activeIndex: 0
        ),
        ProviderAccountData(
            type: .openRouter,
            accounts: [
                ProviderAccount(
                    id: "openrouter-personal",
                    label: "Personal",
                    values: [
                        "openrouter.api-key": "openrouter-personal-key",
                        "openrouter.management-key": "openrouter-personal-management-key",
                    ]
                ),
                ProviderAccount(
                    id: "openrouter-work",
                    label: "Work",
                    values: [
                        "openrouter.api-key": "openrouter-work-key",
                        "openrouter.management-key": "openrouter-work-management-key",
                    ]
                ),
            ],
            activeIndex: 1
        ),
    ]

    let store = CredentialStore(service: service)
    try store.saveAccountData(accountData)

    #expect(try CredentialStore(service: service).loadAccountData() == accountData)
}

@MainActor
@Test
func credentialStoreMigratesTheFlatAccountIndexIntoProviderOwnedLists() throws {
    let service = "com.costbar.tests.flat-account-migration.\(UUID().uuidString)"
    defer {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    let legacyIndex = Data(#"""
    [
      {"id":"personal","type":"openai-api","name":"Personal","usesGitHubCLI":false},
      {"id":"work","type":"openai-api","name":"Work","usesGitHubCLI":false}
    ]
    """#.utf8)
    for (account, data) in [
        ("accounts.v2", legacyIndex),
        ("account.v2.personal.openai.admin-key", Data("personal-key".utf8)),
        ("account.v2.work.openai.admin-key", Data("work-key".utf8)),
    ] {
        let status = SecItemAdd([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ] as CFDictionary, nil)
        #expect(status == errSecSuccess)
    }

    let store = CredentialStore(service: service)
    let migrated = try store.loadAccountData()

    #expect(migrated.count == 1)
    #expect(migrated[0].type == .openAIAPI)
    #expect(migrated[0].accounts.map(\.displayName) == ["Personal", "Work"])
    #expect(migrated[0].activeIndex == 0)
    #expect(migrated[0].accounts[1].values["openai.admin-key"] == "work-key")

    try store.saveAccountData(migrated)
    let newIndexStatus = SecItemCopyMatching([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "accounts.v3",
    ] as CFDictionary, nil)
    #expect(newIndexStatus == errSecSuccess)
}

@MainActor
@Test
func providerSettingsKeepsAnActiveAccountInsideEachProvider() throws {
    let service = "com.costbar.tests.provider-account-selection.\(UUID().uuidString)"
    defer {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    let credentials = CredentialStore(service: service)
    let store = ProviderSettingsStore(credentials: credentials)
    store.selectProvider(.openAIAPI)
    store.addAccount()
    store.accountName = "Personal"
    store.addAccount()
    store.accountName = "Work"
    let personalID = try #require(store.selectedProviderAccounts.first?.id)
    store.selectAccount(personalID)

    #expect(store.save())
    let saved = try CredentialStore(service: service).loadAccountData()
    let openAI = try #require(saved.first(where: { $0.type == .openAIAPI }))
    #expect(openAI.accounts.map(\.displayName) == ["Personal", "Work"])
    #expect(openAI.activeAccount?.id == personalID)
}

@MainActor
@Test
func legacyPackedCredentialsRemainRecoverableUntilExplicitlyCleared() throws {
    let service = "com.costbar.tests.credentials.legacy.\(UUID().uuidString)"
    defer {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    let legacyJSON = #"""
    {"cloudflareToken":"cloudflare-token","cloudflareAccountID":"account-id","runpodAPIKey":"runpod-key"}
    """#
    let legacy = Data(legacyJSON.utf8)
    let addStatus = SecItemAdd([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "providers",
        kSecValueData as String: legacy,
    ] as CFDictionary, nil)
    #expect(addStatus == errSecSuccess)

    let store = CredentialStore(service: service)
    let migrated = try store.load()
    #expect(migrated.cloudflareToken == "cloudflare-token")
    #expect(migrated.cloudflareAccountID == "account-id")
    #expect(migrated.runpodAPIKey == "runpod-key")

    let packedStatus = SecItemCopyMatching([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: "providers",
    ] as CFDictionary, nil)
    #expect(packedStatus == errSecSuccess)

    try store.save(.empty)
    let cleared = try CredentialStore(service: service).load()
    #expect(cleared.cloudflareToken == nil)
    #expect(cleared.cloudflareAccountID == nil)
    #expect(cleared.runpodAPIKey == nil)
}

@MainActor
@Test
func providerSettingsSelectAndExcludeGitHubOrganizations() {
    let store = ProviderSettingsStore(
        credentials: CredentialStore(
            service: "com.costbar.tests.github-selection.\(UUID().uuidString)"
        )
    )
    store.githubOrganization = "Alpha, beta\nALPHA"

    #expect(store.selectedGitHubOrganizations == ["Alpha", "beta"])
    #expect(store.isGitHubOrganizationSelected("alpha"))

    store.setGitHubOrganization("Gamma", selected: true)
    store.setGitHubOrganization("BETA", selected: false)

    #expect(store.selectedGitHubOrganizations == ["Alpha", "Gamma"])
    #expect(!store.isGitHubOrganizationSelected("beta"))
}
