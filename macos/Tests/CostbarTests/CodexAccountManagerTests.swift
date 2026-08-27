import Foundation
import Testing
@testable import Costbar

@MainActor
@Test
func codexAccountsUseWorkspaceIdentityInsteadOfEmail() throws {
    let fixture = try CodexAccountFixture()
    defer { fixture.cleanup() }

    let personal = try fixture.managedAccount(
        id: UUID(),
        accountID: "workspace-personal",
        workspaceLabel: "Personal"
    )
    let work = try fixture.managedAccount(
        id: UUID(),
        accountID: "workspace-work",
        workspaceLabel: "Polymath AS"
    )
    try fixture.manager.storeManagedAccounts([personal, work])
    try fixture.writeAuth(accountID: "workspace-work", to: fixture.ambientHome)

    var snapshot = try fixture.manager.snapshot()
    #expect(snapshot.accounts.count == 2)
    #expect(snapshot.accounts.map(\.displayName) == [
        "uzair@polmath.no — Personal",
        "uzair@polmath.no — Polymath AS",
    ])
    #expect(snapshot.accounts.filter(\.isSystem).map(\.managedAccountID) == [work.id])
    #expect(snapshot.activeAccount?.managedAccountID == work.id)

    let personalVisibleID = try #require(snapshot.accounts.first {
        $0.managedAccountID == personal.id
    }?.id)
    try fixture.manager.setActiveAccount(visibleID: personalVisibleID)
    snapshot = try fixture.manager.snapshot()

    #expect(snapshot.activeAccount?.managedAccountID == personal.id)
    #expect(snapshot.accounts.first { $0.managedAccountID == work.id }?.isSystem == true)
}

@MainActor
@Test
func promotingCodexWorkspaceSwapsSystemAuthWithoutDuplicatingSameEmail() throws {
    let fixture = try CodexAccountFixture()
    defer { fixture.cleanup() }

    let personal = try fixture.managedAccount(
        id: UUID(),
        accountID: "workspace-personal",
        workspaceLabel: "Personal"
    )
    let work = try fixture.managedAccount(
        id: UUID(),
        accountID: "workspace-work",
        workspaceLabel: "Polymath AS",
        authAccountID: "workspace-personal"
    )
    try fixture.manager.storeManagedAccounts([personal, work])
    try fixture.writeAuth(accountID: "workspace-personal", to: fixture.ambientHome)

    try fixture.manager.promoteToSystem(managedAccountID: work.id)

    let snapshot = try fixture.manager.snapshot()
    #expect(snapshot.accounts.count == 2)
    #expect(snapshot.accounts.filter(\.isSystem).map(\.managedAccountID) == [work.id])
    let liveIdentity = try CodexAccountManager.loadIdentity(
        from: fixture.ambientHome.appendingPathComponent("auth.json")
    )
    #expect(liveIdentity.accountID == "workspace-work")

    let attributes = try FileManager.default.attributesOfItem(
        atPath: fixture.ambientHome.appendingPathComponent("auth.json").path
    )
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@MainActor
private struct CodexAccountFixture {
    let root: URL
    let ambientHome: URL
    let defaultsSuite: String
    let defaults: UserDefaults
    let manager: CodexAccountManager

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "costbar-codex-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        ambientHome = root.appendingPathComponent("ambient", isDirectory: true)
        defaultsSuite = "com.costbar.tests.codex-accounts.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defaults.removePersistentDomain(forName: defaultsSuite)
        manager = CodexAccountManager(
            rootURL: root.appendingPathComponent("managed", isDirectory: true),
            ambientHomeURL: ambientHome,
            defaults: defaults,
            environment: [:]
        )
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }

    func managedAccount(
        id: UUID,
        accountID: String,
        workspaceLabel: String,
        authAccountID: String? = nil
    ) throws -> ManagedCodexAccount {
        let home = manager.rootURL
            .appendingPathComponent("homes", isDirectory: true)
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try writeAuth(accountID: authAccountID ?? accountID, to: home)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        return ManagedCodexAccount(
            id: id,
            email: "uzair@polmath.no",
            accountID: accountID,
            workspaceLabel: workspaceLabel,
            homePath: home.path,
            createdAt: now,
            lastAuthenticatedAt: now
        )
    }

    func writeAuth(accountID: String, to home: URL) throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let payload: [String: Any] = [
            "email": "uzair@polmath.no",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": accountID,
            ],
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let encodedPayload = payloadData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "e30.\(encodedPayload).signature"
        let auth: [String: Any] = [
            "tokens": [
                "access_token": token,
                "refresh_token": "refresh-\(accountID)",
                "id_token": token,
                "account_id": accountID,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: auth, options: [.sortedKeys])
        try data.write(to: home.appendingPathComponent("auth.json"))
    }
}
