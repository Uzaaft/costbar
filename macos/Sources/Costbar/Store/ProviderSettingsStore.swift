import Foundation
import SwiftUI

/// The long-running Codex CLI task blocking further account changes.
enum CodexAccountOperation: Equatable, Sendable {
    case addingAccount
    /// `nil` re-authenticates the system CLI login rather than a managed one.
    case reauthenticating(UUID?)
    case changingSystemAccount
    case removing(UUID)
}

@MainActor
final class ProviderSettingsStore: ObservableObject {
    @Published private(set) var accountData: [ProviderAccountData] = []
    @Published private(set) var selectedProviderType = ProviderAccountType.digitalOcean
    @Published private(set) var selectedAccountID: String?
    @Published var accountName = ""
    /// The credential values being edited for ``selectedAccountID``. Views bind
    /// to individual settings through ``binding(for:)``.
    @Published var editor = ProviderCredentials.empty
    @Published var usesGitHubCLI = false
    @Published private(set) var availableGitHubOrganizations: [String] = []
    @Published private(set) var isDiscoveringGitHubOrganizations = false
    @Published var trackedLocalSources: Set<LocalSource> = []
    @Published private(set) var codexAccounts: [VisibleCodexAccount] = []
    @Published private(set) var codexActiveAccountID: String?
    @Published private(set) var codexSystemAccountID: String?
    @Published private(set) var codexOperation: CodexAccountOperation?
    @Published var defaultPollingInterval = PollingSettings.defaultIntervalSeconds
    @Published var pollingIntervalOverrides: [String: Int] = [:]
    @Published private(set) var hasClaudeStatusBridge = false
    @Published private(set) var message: String?

    private let credentials: CredentialStore
    private let codexAccountManager: CodexAccountManager

    init(
        credentials: CredentialStore,
        codexAccountManager: CodexAccountManager = CodexAccountManager()
    ) {
        self.credentials = credentials
        self.codexAccountManager = codexAccountManager
        reload()
    }

    func save() -> Bool {
        do {
            commitSelectedAccount()
            try credentials.saveAccountData(accountData)
            LocalAISettings.save(trackedSources: trackedLocalSources)
            CLIAuthSettings.saveGitHubCLI(
                accountData.first(where: { $0.type == .github })?
                    .accounts.contains(where: \.usesGitHubCLI) == true
            )
            PollingSettings.save(
                defaultInterval: defaultPollingInterval,
                overrides: pollingIntervalOverrides
            )
            message = "Settings saved. API credentials remain in Keychain; Codex OAuth stays in its managed CLI profile."
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    private func reload() {
        do {
            accountData = try credentials.loadAccountData()
            if CLIAuthSettings.usesGitHubCLI(),
               let dataIndex = accountData.firstIndex(where: { $0.type == .github }),
               !accountData[dataIndex].accounts.isEmpty {
                let accountIndex = accountData[dataIndex].clampedActiveIndex
                accountData[dataIndex].accounts[accountIndex].usesGitHubCLI = true
            }
            selectedProviderType = accountData.first?.type ?? .digitalOcean
            loadSelectedAccount()
        } catch {
            message = error.localizedDescription
        }
        trackedLocalSources = LocalAISettings.trackedSources()
        refreshCodexAccounts()
        defaultPollingInterval = PollingSettings.defaultInterval()
        pollingIntervalOverrides = PollingSettings.overrides()
        hasClaudeStatusBridge = ClaudeStatusLineBridge.isInstalled
    }

    // MARK: - Provider accounts

    var selectedProviderAccounts: [ProviderAccount] {
        accounts(for: selectedProviderType)
    }

    var hasSelectedAccount: Bool { selectedAccountID != nil }

    func accounts(for type: ProviderAccountType) -> [ProviderAccount] {
        accountData.first(where: { $0.type == type })?.accounts ?? []
    }

    func selectProvider(_ type: ProviderAccountType) {
        guard type != selectedProviderType else { return }
        commitSelectedAccount()
        selectedProviderType = type
        loadSelectedAccount()
    }

    func selectAccount(_ id: String?) {
        guard id != selectedAccountID else { return }
        commitSelectedAccount()
        guard let dataIndex = accountData.firstIndex(where: { $0.type == selectedProviderType }),
              let id,
              let accountIndex = accountData[dataIndex].accounts.firstIndex(where: { $0.id == id })
        else {
            selectedAccountID = nil
            clearAccountEditor()
            return
        }
        accountData[dataIndex].activeIndex = accountIndex
        selectedAccountID = id
        loadEditor(from: accountData[dataIndex].accounts[accountIndex])
    }

    func addAccount() {
        commitSelectedAccount()
        let type = selectedProviderType
        let dataIndex: Int
        if let existing = accountData.firstIndex(where: { $0.type == type }) {
            dataIndex = existing
        } else {
            accountData.append(ProviderAccountData(type: type, accounts: []))
            dataIndex = accountData.count - 1
        }
        let ordinal = accountData[dataIndex].accounts.count + 1
        let label = ordinal == 1 ? type.displayName : "\(type.displayName) \(ordinal)"
        let account = ProviderAccount(label: label)
        accountData[dataIndex].accounts.append(account)
        accountData[dataIndex].activeIndex = accountData[dataIndex].accounts.count - 1
        selectedAccountID = account.id
        loadEditor(from: account)
    }

    func removeAccount(_ id: String) {
        commitSelectedAccount()
        guard let dataIndex = accountData.firstIndex(where: { $0.type == selectedProviderType }),
              let removedIndex = accountData[dataIndex].accounts.firstIndex(where: { $0.id == id })
        else { return }

        let activeID = accountData[dataIndex].activeAccount?.id
        accountData[dataIndex].accounts.remove(at: removedIndex)
        if accountData[dataIndex].accounts.isEmpty {
            accountData.remove(at: dataIndex)
            selectedAccountID = nil
            clearAccountEditor()
            return
        }

        let nextIndex = if activeID != id,
                           let preservedIndex = accountData[dataIndex].accounts.firstIndex(where: {
                               $0.id == activeID
                           }) {
            preservedIndex
        } else {
            min(removedIndex, accountData[dataIndex].accounts.count - 1)
        }
        accountData[dataIndex].activeIndex = nextIndex
        let replacement = accountData[dataIndex].accounts[nextIndex]
        selectedAccountID = replacement.id
        loadEditor(from: replacement)
    }

    // MARK: - Credential editor

    /// A non-optional text binding for one credential field. Blank input clears
    /// the stored value rather than saving an empty string.
    func binding(for setting: ProviderSetting) -> Binding<String> {
        Binding(
            get: { [weak self] in self?.editor[setting: setting] ?? "" },
            set: { [weak self] value in
                self?.editor[setting: setting] = value.isEmpty ? nil : value
            }
        )
    }

    private func commitSelectedAccount() {
        guard let dataIndex = accountData.firstIndex(where: { $0.type == selectedProviderType }),
              let selectedAccountID,
              let accountIndex = accountData[dataIndex].accounts.firstIndex(where: {
                  $0.id == selectedAccountID
              })
        else { return }
        let type = selectedProviderType
        accountData[dataIndex].accounts[accountIndex].label = accountName
        accountData[dataIndex].accounts[accountIndex].values = Dictionary(
            uniqueKeysWithValues: type.settings.compactMap { setting -> (String, String)? in
                guard let value = editor[setting: setting]?.trimmedOrNil else { return nil }
                return (setting.key, value)
            }
        )
        accountData[dataIndex].accounts[accountIndex].usesGitHubCLI =
            type == .github && usesGitHubCLI
    }

    private func loadEditor(from account: ProviderAccount) {
        accountName = account.displayName
        usesGitHubCLI = account.usesGitHubCLI
        editor = account.credentials(for: selectedProviderType)
        availableGitHubOrganizations = selectedGitHubOrganizations
    }

    private func clearAccountEditor() {
        accountName = ""
        usesGitHubCLI = false
        editor = .empty
        availableGitHubOrganizations = []
    }

    private func loadSelectedAccount() {
        guard let data = accountData.first(where: { $0.type == selectedProviderType }),
              let account = data.activeAccount
        else {
            selectedAccountID = nil
            clearAccountEditor()
            return
        }
        selectedAccountID = account.id
        loadEditor(from: account)
    }

    // MARK: - Local sources

    func tracks(_ source: LocalSource) -> Bool {
        trackedLocalSources.contains(source)
    }

    func trackingBinding(for source: LocalSource) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.tracks(source) ?? false },
            set: { [weak self] isTracked in
                guard let self else { return }
                if isTracked {
                    trackedLocalSources.insert(source)
                } else {
                    trackedLocalSources.remove(source)
                }
            }
        )
    }

    // MARK: - Codex accounts

    var hasCodexAccountOperationInFlight: Bool { codexOperation != nil }

    func refreshCodexAccounts() {
        do {
            let snapshot = try codexAccountManager.snapshot()
            codexAccounts = snapshot.accounts
            codexActiveAccountID = snapshot.activeAccountID
            codexSystemAccountID = snapshot.systemAccountID
        } catch {
            codexAccounts = []
            codexActiveAccountID = nil
            codexSystemAccountID = nil
            message = error.localizedDescription
        }
    }

    func selectActiveCodexAccount(_ id: String) {
        do {
            try codexAccountManager.setActiveAccount(visibleID: id)
            refreshCodexAccounts()
            message = "Selected Codex account appears first. All accounts remain tracked."
        } catch {
            message = error.localizedDescription
        }
    }

    @discardableResult
    func addCodexAccount() async -> Bool {
        await authenticateManagedCodexAccount(replacing: nil)
    }

    @discardableResult
    func reauthenticateCodexAccount(_ account: VisibleCodexAccount) async -> Bool {
        if let managedAccountID = account.managedAccountID {
            return await authenticateManagedCodexAccount(replacing: managedAccountID)
        }
        return await performCodexOperation(.reauthenticating(nil)) {
            try await self.codexAccountManager.reauthenticateSystemAccount()
            return "System Codex account re-authenticated."
        }
    }

    @discardableResult
    func selectSystemCodexAccount(_ visibleID: String) async -> Bool {
        guard visibleID != codexSystemAccountID,
              let account = codexAccounts.first(where: { $0.id == visibleID }),
              let managedAccountID = account.managedAccountID
        else { return false }
        return await performCodexOperation(.changingSystemAccount) {
            try self.codexAccountManager.promoteToSystem(managedAccountID: managedAccountID)
            return "The selected account is now the default Codex CLI account on this Mac."
        }
    }

    @discardableResult
    func removeCodexAccount(_ account: VisibleCodexAccount) async -> Bool {
        guard let managedAccountID = account.managedAccountID else { return false }
        return await performCodexOperation(.removing(managedAccountID)) {
            try self.codexAccountManager.removeManagedAccount(id: managedAccountID)
            return account.isSystem
                ? "Removed Costbar's managed copy. The system Codex login remains signed in."
                : "Codex account removed."
        }
    }

    private func authenticateManagedCodexAccount(replacing id: UUID?) async -> Bool {
        await performCodexOperation(id == nil ? .addingAccount : .reauthenticating(id)) {
            let account = try await self.codexAccountManager
                .authenticateManagedAccount(replacing: id)
            self.trackedLocalSources.insert(.codex)
            if id == nil {
                self.refreshCodexAccounts()
                if let visible = self.codexAccounts.first(where: {
                    $0.managedAccountID == account.id
                }) {
                    self.selectActiveCodexAccount(visible.id)
                }
            }
            return id == nil
                ? "Codex account added through the Codex CLI."
                : "Codex account re-authenticated through the Codex CLI."
        }
    }

    /// Runs one Codex CLI task at a time, refreshing the account list and
    /// reporting the task's own success message when it finishes.
    private func performCodexOperation(
        _ operation: CodexAccountOperation,
        body: @escaping () async throws -> String
    ) async -> Bool {
        guard codexOperation == nil else { return false }
        codexOperation = operation
        defer { codexOperation = nil }
        do {
            let successMessage = try await body()
            refreshCodexAccounts()
            message = successMessage
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }

    // MARK: - Polling

    func pollingIntervalOverride(for sourceID: String) -> Int? {
        pollingIntervalOverrides[sourceID]
    }

    func setPollingIntervalOverride(_ interval: Int?, for sourceID: String) {
        pollingIntervalOverrides[sourceID] = interval
    }

    // MARK: - GitHub organizations

    var githubOrganization: String {
        get { editor[setting: .githubOrganization] ?? "" }
        set { editor[setting: .githubOrganization] = newValue.isEmpty ? nil : newValue }
    }

    var selectedGitHubOrganizations: [String] {
        Self.organizations(in: githubOrganization)
    }

    var primaryGitHubOrganization: String {
        selectedGitHubOrganizations.first ?? ""
    }

    var hasSingleGitHubOrganization: Bool {
        selectedGitHubOrganizations.count == 1
    }

    func isGitHubOrganizationSelected(_ organization: String) -> Bool {
        selectedGitHubOrganizations.contains {
            $0.caseInsensitiveCompare(organization) == .orderedSame
        }
    }

    func setGitHubOrganization(_ organization: String, selected: Bool) {
        var organizations = selectedGitHubOrganizations.filter {
            $0.caseInsensitiveCompare(organization) != .orderedSame
        }
        if selected { organizations.append(organization) }
        githubOrganization = organizations.joined(separator: ", ")
    }

    func selectAllGitHubOrganizations() {
        githubOrganization = availableGitHubOrganizations.joined(separator: ", ")
    }

    func clearGitHubOrganizations() {
        githubOrganization = ""
    }

    func discoverGitHubOrganizations() {
        guard !isDiscoveringGitHubOrganizations else { return }
        isDiscoveringGitHubOrganizations = true
        Task { [weak self] in
            guard let self else { return }
            defer { isDiscoveringGitHubOrganizations = false }
            do {
                let discovered = try await CostbarCore.githubCLIOrganizations()
                availableGitHubOrganizations = Self.mergedOrganizations(
                    discovered + selectedGitHubOrganizations
                )
                message = discovered.isEmpty
                    ? "The signed-in GitHub CLI account has no organizations."
                    : "Choose which GitHub organizations Costbar should include."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    // MARK: - Claude quota bridge

    func installClaudeStatusBridge() {
        do {
            try ClaudeStatusLineBridge.install()
            hasClaudeStatusBridge = true
            message = "Claude subscription quota bridge installed."
        } catch {
            message = error.localizedDescription
        }
    }

    func restoreClaudeStatusLine() {
        do {
            try ClaudeStatusLineBridge.restore()
            hasClaudeStatusBridge = false
            message = "Previous Claude status line restored."
        } catch {
            message = error.localizedDescription
        }
    }

    private static func organizations(in raw: String) -> [String] {
        mergedOrganizations(
            raw.components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    private static func mergedOrganizations(_ organizations: [String]) -> [String] {
        organizations.reduce(into: []) { result, organization in
            guard !result.contains(where: {
                $0.caseInsensitiveCompare(organization) == .orderedSame
            }) else { return }
            result.append(organization)
        }
    }
}

extension String {
    var trimmedOrNil: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
