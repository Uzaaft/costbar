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
    expected.ovhEndpoint = "ovh-eu"
    expected.ovhApplicationKey = "ovh-app"
    expected.ovhApplicationSecret = "ovh-secret"
    expected.ovhConsumerKey = "ovh-consumer"
    expected.ovhProjectID = "ovh-project"
    expected.hetznerToken = "hetzner-token"
    expected.xAIManagementKey = "xai-management-key"
    expected.xAITeamID = "team_123"

    try CredentialStore(service: service).save(expected)
    let actual = try CredentialStore(service: service).load()

    #expect(actual == expected)
}
