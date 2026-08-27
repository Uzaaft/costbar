import CryptoKit
import Foundation

@MainActor
final class CodexAccountManager {
    private struct AccountFile: Codable {
        let version: Int
        let accounts: [ManagedCodexAccount]
    }

    private static let currentVersion = 1
    private static let activeSourceKey = "codex-active-account-v1"

    let rootURL: URL
    let ambientHomeURL: URL
    private let accountFileURL: URL
    private let managedHomesURL: URL
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let environment: [String: String]
    private let workspacePicker: any CodexWorkspaceSelecting
    private let lock = NSLock()
    private var loginRunning = false

    init(
        rootURL: URL? = nil,
        ambientHomeURL: URL? = nil,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workspacePicker: any CodexWorkspaceSelecting = CodexWorkspaceAlertPicker()
    ) {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
        let resolvedRoot = rootURL ?? applicationSupport
            .appendingPathComponent("Costbar", isDirectory: true)
            .appendingPathComponent("CodexAccounts", isDirectory: true)
        self.rootURL = resolvedRoot.standardizedFileURL
        managedHomesURL = self.rootURL.appendingPathComponent("homes", isDirectory: true)
        accountFileURL = self.rootURL.appendingPathComponent(
            "managed-accounts.json",
            isDirectory: false
        )
        self.ambientHomeURL = (ambientHomeURL ?? Self.defaultAmbientHome(
            fileManager: fileManager,
            environment: environment
        )).standardizedFileURL
        self.defaults = defaults
        self.fileManager = fileManager
        self.environment = environment
        self.workspacePicker = workspacePicker
    }

    func snapshot() throws -> CodexAccountSnapshot {
        let managed = try loadManagedAccounts()
        let systemIdentity = try? Self.loadIdentity(
            from: authFileURL(for: ambientHomeURL)
        )
        let systemMatch = systemIdentity.flatMap { liveIdentity in
            managed.first { account in
                guard let storedIdentity = try? identity(for: account) else { return false }
                return Self.identitiesMatch(liveIdentity, storedIdentity)
            }
        }
        let activeSource = resolvedActiveSource(managedAccounts: managed)

        var visible: [VisibleCodexAccount] = managed.compactMap { account in
            guard let identity = try? identity(for: account) else { return nil }
            return VisibleCodexAccount(
                id: Self.managedVisibleID(account.id),
                email: identity.email,
                accountID: identity.accountID,
                workspaceLabel: account.workspaceLabel ?? identity.workspaceLabel,
                homePath: account.homePath,
                managedAccountID: account.id,
                isSystem: systemMatch?.id == account.id,
                isActive: activeSource == Self.managedVisibleID(account.id)
            )
        }

        if let systemIdentity, systemMatch == nil {
            visible.insert(VisibleCodexAccount(
                id: Self.systemVisibleID,
                email: systemIdentity.email,
                accountID: systemIdentity.accountID,
                workspaceLabel: systemIdentity.workspaceLabel,
                homePath: ambientHomeURL.path,
                managedAccountID: nil,
                isSystem: true,
                isActive: activeSource == Self.systemVisibleID
            ), at: 0)
        }

        let systemAccountID = systemMatch.map { Self.managedVisibleID($0.id) }
            ?? (systemIdentity == nil ? nil : Self.systemVisibleID)
        let activeAccountID = visible.first(where: \.isActive)?.id
            ?? visible.first(where: \.isSystem)?.id
            ?? visible.first?.id

        return CodexAccountSnapshot(
            accounts: visible,
            activeAccountID: activeAccountID,
            systemAccountID: systemAccountID,
            ambientHomePath: ambientHomeURL.path
        )
    }

    func setActiveAccount(visibleID: String) throws {
        let snapshot = try snapshot()
        guard snapshot.accounts.contains(where: { $0.id == visibleID }) else {
            throw CodexAccountManagerError.accountNotFound
        }
        defaults.set(visibleID, forKey: Self.activeSourceKey)
    }

    func authenticateManagedAccount(
        replacing existingID: UUID? = nil,
        timeout: TimeInterval = 120
    ) async throws -> ManagedCodexAccount {
        guard beginLogin() else { throw CodexAccountManagerError.loginInProgress }
        defer { finishLogin() }

        try ensurePrivateDirectory(managedHomesURL)
        let homeURL = managedHomesURL.appendingPathComponent(
            UUID().uuidString.lowercased(),
            isDirectory: true
        )
        try ensurePrivateDirectory(homeURL)

        do {
            try await CodexCLILogin.run(
                homeURL: homeURL,
                timeout: timeout,
                environment: environment
            )
            let authURL = authFileURL(for: homeURL)
            guard fileManager.fileExists(atPath: authURL.path) else {
                throw CodexAccountManagerError.authFileMissing
            }
            let identity = try Self.loadIdentity(from: authURL)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: authURL.path
            )

            var accounts = try loadManagedAccounts()
            let replacingAccount = existingID.flatMap { id in accounts.first { $0.id == id } }
            let workspaces = (try? await Self.loadWorkspaces(from: authURL)) ?? []
            let workspace = try workspacePicker.selectWorkspace(
                from: workspaces,
                email: identity.email,
                selectedID: replacingAccount?.accountID ?? identity.accountID
            )
            let selectedAccountID = workspace?.normalizedID ?? identity.accountID
            let selectedWorkspaceLabel = workspace?.displayName ?? identity.workspaceLabel
            let existing = replacingAccount ?? accounts.first { account in
                account.email.caseInsensitiveCompare(identity.email) == .orderedSame &&
                    account.accountID == selectedAccountID
            }
            let now = Date()
            let account = ManagedCodexAccount(
                id: existing?.id ?? UUID(),
                email: identity.email,
                accountID: selectedAccountID,
                workspaceLabel: selectedWorkspaceLabel,
                homePath: homeURL.path,
                createdAt: existing?.createdAt ?? now,
                lastAuthenticatedAt: now
            )
            accounts.removeAll { $0.id == account.id }
            accounts.append(account)
            try storeManagedAccounts(accounts)

            if let existing, existing.homePath != account.homePath {
                try? removeManagedHome(path: existing.homePath)
            }
            if defaults.string(forKey: Self.activeSourceKey) == nil {
                defaults.set(Self.managedVisibleID(account.id), forKey: Self.activeSourceKey)
            }
            return account
        } catch {
            try? removeManagedHome(path: homeURL.path)
            throw error
        }
    }

    func reauthenticateSystemAccount(timeout: TimeInterval = 120) async throws {
        guard beginLogin() else { throw CodexAccountManagerError.loginInProgress }
        defer { finishLogin() }
        try await CodexCLILogin.run(
            homeURL: nil,
            timeout: timeout,
            environment: environment
        )
        _ = try Self.loadIdentity(from: authFileURL(for: ambientHomeURL))
    }

    func promoteToSystem(managedAccountID: UUID) throws {
        var accounts = try loadManagedAccounts()
        guard let target = accounts.first(where: { $0.id == managedAccountID }) else {
            throw CodexAccountManagerError.accountNotFound
        }
        let targetURL = authFileURL(for: URL(fileURLWithPath: target.homePath, isDirectory: true))
        let rawTargetData = try readAuthData(at: targetURL)
        let targetData = try Self.authData(
            rawTargetData,
            selectingAccountID: target.accountID
        )
        let targetIdentity = try Self.loadIdentity(data: targetData)
        let liveURL = authFileURL(for: ambientHomeURL)

        if let liveData = try? readAuthData(at: liveURL),
           let liveIdentity = try? Self.loadIdentity(data: liveData) {
            if Self.identitiesMatch(liveIdentity, targetIdentity),
               Self.fingerprint(liveData) == Self.fingerprint(targetData) {
                return
            }
            let alreadyPreserved = accounts.contains { account in
                guard let stored = try? identity(for: account) else { return false }
                return Self.identitiesMatch(stored, liveIdentity)
            }
            if !alreadyPreserved {
                let preservedHome = managedHomesURL.appendingPathComponent(
                    UUID().uuidString.lowercased(),
                    isDirectory: true
                )
                try ensurePrivateDirectory(preservedHome)
                do {
                    try writePrivate(liveData, to: authFileURL(for: preservedHome))
                    let now = Date()
                    accounts.append(ManagedCodexAccount(
                        id: UUID(),
                        email: liveIdentity.email,
                        accountID: liveIdentity.accountID,
                        workspaceLabel: liveIdentity.workspaceLabel,
                        homePath: preservedHome.path,
                        createdAt: now,
                        lastAuthenticatedAt: now
                    ))
                } catch {
                    try? removeManagedHome(path: preservedHome.path)
                    throw CodexAccountManagerError.systemAccountCannotBePreserved
                }
            }
        } else if fileManager.fileExists(atPath: liveURL.path) {
            throw CodexAccountManagerError.systemAccountCannotBePreserved
        }

        try storeManagedAccounts(accounts)
        try writePrivate(targetData, to: liveURL)
    }

    func removeManagedAccount(id: UUID) throws {
        var accounts = try loadManagedAccounts()
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        accounts.removeAll { $0.id == id }
        try storeManagedAccounts(accounts)
        try? removeManagedHome(path: account.homePath)
        if defaults.string(forKey: Self.activeSourceKey) == Self.managedVisibleID(id) {
            defaults.set(Self.systemVisibleID, forKey: Self.activeSourceKey)
        }
    }

    func loadManagedAccounts() throws -> [ManagedCodexAccount] {
        guard fileManager.fileExists(atPath: accountFileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(
            AccountFile.self,
            from: Data(contentsOf: accountFileURL)
        )
        guard file.version == Self.currentVersion else {
            throw CodexAccountManagerError.authFileInvalid
        }
        var seen: Set<UUID> = []
        return file.accounts.filter { seen.insert($0.id).inserted }
    }

    func storeManagedAccounts(_ accounts: [ManagedCodexAccount]) throws {
        try ensurePrivateDirectory(rootURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(AccountFile(
            version: Self.currentVersion,
            accounts: accounts
        ))
        try writePrivate(data, to: accountFileURL)
    }

    private func resolvedActiveSource(managedAccounts: [ManagedCodexAccount]) -> String {
        guard let stored = defaults.string(forKey: Self.activeSourceKey) else {
            return Self.systemVisibleID
        }
        if stored == Self.systemVisibleID { return stored }
        guard let id = Self.managedID(fromVisibleID: stored),
              managedAccounts.contains(where: { $0.id == id })
        else {
            return Self.systemVisibleID
        }
        return stored
    }

    private func identity(for account: ManagedCodexAccount) throws -> CodexAuthIdentity {
        let identity = try Self.loadIdentity(from: authFileURL(for: URL(
            fileURLWithPath: account.homePath,
            isDirectory: true
        )))
        return CodexAuthIdentity(
            email: identity.email,
            accountID: account.accountID ?? identity.accountID,
            workspaceLabel: account.workspaceLabel ?? identity.workspaceLabel,
            fingerprint: identity.fingerprint
        )
    }

    private func readAuthData(at url: URL) throws -> Data {
        guard fileManager.fileExists(atPath: url.path) else {
            throw CodexAccountManagerError.authFileMissing
        }
        return try Data(contentsOf: url)
    }

    private func authFileURL(for homeURL: URL) -> URL {
        homeURL.appendingPathComponent("auth.json", isDirectory: false)
    }

    private func ensurePrivateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
    }

    private func writePrivate(_ data: Data, to destination: URL) throws {
        try ensurePrivateDirectory(destination.deletingLastPathComponent())
        let staged = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).costbar-staged-\(UUID().uuidString)",
            isDirectory: false
        )
        do {
            try data.write(to: staged)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: staged.path
            )
            guard rename(staged.path, destination.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            try? fileManager.removeItem(at: staged)
            throw error
        }
    }

    private func removeManagedHome(path: String) throws {
        let target = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let root = managedHomesURL.standardizedFileURL.path + "/"
        guard target.path.hasPrefix(root), target.path != managedHomesURL.path else {
            throw CodexAccountManagerError.unsafeManagedHome
        }
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
    }

    private func beginLogin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !loginRunning else { return false }
        loginRunning = true
        return true
    }

    private func finishLogin() {
        lock.lock()
        loginRunning = false
        lock.unlock()
    }

    private static func defaultAmbientHome(
        fileManager: FileManager,
        environment: [String: String]
    ) -> URL {
        if let configured = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private static let systemVisibleID = "system"

    private static func managedVisibleID(_ id: UUID) -> String {
        "managed:\(id.uuidString.lowercased())"
    }

    private static func managedID(fromVisibleID id: String) -> UUID? {
        guard id.hasPrefix("managed:") else { return nil }
        return UUID(uuidString: String(id.dropFirst("managed:".count)))
    }

    private static func identitiesMatch(_ lhs: CodexAuthIdentity, _ rhs: CodexAuthIdentity) -> Bool {
        if let lhsID = lhs.accountID, let rhsID = rhs.accountID {
            return lhsID.caseInsensitiveCompare(rhsID) == .orderedSame
        }
        if lhs.fingerprint == rhs.fingerprint { return true }
        guard lhs.email.caseInsensitiveCompare(rhs.email) == .orderedSame else { return false }
        if let lhsLabel = lhs.workspaceLabel, let rhsLabel = rhs.workspaceLabel {
            return lhsLabel.caseInsensitiveCompare(rhsLabel) == .orderedSame
        }
        return lhs.accountID == nil && rhs.accountID == nil
    }

    static func loadIdentity(from url: URL) throws -> CodexAuthIdentity {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CodexAccountManagerError.authFileMissing
        }
        return try loadIdentity(data: Data(contentsOf: url))
    }

    static func loadIdentity(data: Data) throws -> CodexAuthIdentity {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = nonEmpty(tokens["access_token"] as? String)
                ?? nonEmpty(tokens["accessToken"] as? String)
        else {
            throw CodexAccountManagerError.authFileInvalid
        }
        let idToken = nonEmpty(tokens["id_token"] as? String)
            ?? nonEmpty(tokens["idToken"] as? String)
        let payload = idToken.flatMap(jwtPayload) ?? jwtPayload(accessToken) ?? [:]
        let profile = payload["https://api.openai.com/profile"] as? [String: Any]
        let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        guard let email = nonEmpty(profile?["email"] as? String)
            ?? nonEmpty(payload["email"] as? String)
        else {
            throw CodexAccountManagerError.accountIdentityMissing
        }
        let accountID = nonEmpty(tokens["account_id"] as? String)
            ?? nonEmpty(tokens["accountId"] as? String)
            ?? nonEmpty(auth?["chatgpt_account_id"] as? String)
            ?? nonEmpty(payload["chatgpt_account_id"] as? String)
        return CodexAuthIdentity(
            email: email.lowercased(),
            accountID: accountID?.lowercased(),
            workspaceLabel: workspaceLabel(payload: payload, auth: auth, accountID: accountID),
            fingerprint: fingerprint(data)
        )
    }

    private static func authData(_ data: Data, selectingAccountID: String?) throws -> Data {
        guard let selectingAccountID else { return data }
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tokens = root["tokens"] as? [String: Any]
        else { throw CodexAccountManagerError.authFileInvalid }
        tokens["account_id"] = selectingAccountID
        tokens.removeValue(forKey: "accountId")
        root["tokens"] = tokens
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    private static func loadWorkspaces(from authURL: URL) async throws -> [CodexWorkspace] {
        let data = try Data(contentsOf: authURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = nonEmpty(tokens["access_token"] as? String)
                ?? nonEmpty(tokens["accessToken"] as? String),
              let url = URL(string: "https://chatgpt.com/backend-api/accounts")
        else { throw CodexAccountManagerError.authFileInvalid }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 20
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let identity = try loadIdentity(data: data)
        if let accountID = identity.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CodexAccountManagerError.authFileInvalid
        }
        struct Response: Decodable { let items: [CodexWorkspace] }
        return try JSONDecoder().decode(Response.self, from: responseData).items
    }

    private static func workspaceLabel(
        payload: [String: Any],
        auth: [String: Any]?,
        accountID: String?
    ) -> String? {
        let organizations = (payload["organizations"] as? [[String: Any]])
            ?? (auth?["organizations"] as? [[String: Any]])
            ?? []
        let organization = organizations.first { organization in
            guard let accountID else { return false }
            return nonEmpty(organization["id"] as? String)?
                .caseInsensitiveCompare(accountID) == .orderedSame
        } ?? organizations.first
        if let label = nonEmpty(organization?["title"] as? String)
            ?? nonEmpty(organization?["name"] as? String) {
            return label
        }
        let plan = nonEmpty(auth?["chatgpt_plan_type"] as? String)?.lowercased()
        if plan == "team" || plan == "business" { return "Business" }
        return "Personal"
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded.append(String(repeating: "=", count: (4 - encoded.count % 4) % 4))
        guard let data = Data(base64Encoded: encoded),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return payload
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
