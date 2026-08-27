import SwiftUI

struct ProviderAccountSettingsDetail: View {
  let provider: ProviderAccountType
  @ObservedObject var settings: ProviderSettingsStore
  @ObservedObject var dashboard: DashboardStore

  var body: some View {
    SettingsDetailScaffold(
      icon: .provider(id: provider.sourceID),
      title: provider.displayName,
      subtitle: subtitle,
      settings: settings,
      dashboard: dashboard
    ) {
      ProviderAccountListSection(provider: provider, settings: settings)

      if settings.hasSelectedAccount {
        Section("Account details") {
          TextField("Label", text: $settings.accountName)
        }

        Section("Credentials") {
          if provider == .github {
            GitHubCredentialFields(settings: settings)
          } else {
            ForEach(provider.credentialFields) { field in
              ProviderCredentialRow(field: field, settings: settings)
            }
            SettingsHelpText(provider.credentialHelp)
          }
        }
      }
    }
  }

  private var subtitle: String {
    let count = settings.selectedProviderAccounts.count
    if count == 0 { return "No accounts configured" }
    return count == 1 ? "1 configured account" : "\(count) configured accounts"
  }
}

private struct ProviderCredentialRow: View {
  let field: ProviderCredentialField
  @ObservedObject var settings: ProviderSettingsStore

  var body: some View {
    switch field.entry {
    case .plain:
      TextField(field.title, text: settings.binding(for: field.setting))
        .textContentType(.none)
    case let .secret(link):
      if let link {
        SetupLinkedSecureField(
          title: field.title,
          text: settings.binding(for: field.setting),
          destination: link.destination,
          actionLabel: link.actionLabel
        )
      } else {
        SecureField(field.title, text: settings.binding(for: field.setting))
      }
    }
  }
}

private struct ProviderAccountListSection: View {
  let provider: ProviderAccountType
  @ObservedObject var settings: ProviderSettingsStore

  var body: some View {
    Section("Accounts") {
      if settings.selectedProviderAccounts.isEmpty {
        Text("No accounts configured for \(provider.displayName).")
          .foregroundStyle(.secondary)
      } else {
        Picker("Active", selection: activeAccountBinding) {
          ForEach(settings.selectedProviderAccounts) { account in
            Text(account.displayName).tag(account.id)
          }
        }

        SettingsHelpText("Choose which account Costbar treats as active. Every configured account still refreshes independently and appears in the dashboard.")

        Divider()

        ForEach(settings.selectedProviderAccounts) { account in
          accountRow(account)
        }
      }

      Button("Add Account") {
        settings.addAccount()
      }
    }
  }

  private func accountRow(_ account: ProviderAccount) -> some View {
    let isActive = account.id == settings.selectedAccountID
    return HStack(spacing: 12) {
      Button {
        settings.selectAccount(account.id)
      } label: {
        HStack(spacing: 7) {
          Text(account.displayName)
            .fontWeight(isActive ? .semibold : .regular)
          if isActive {
            Text("Active")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .buttonStyle(.plain)

      Spacer()

      Button("Edit") {
        settings.selectAccount(account.id)
      }
      .controlSize(.small)

      Button("Remove") {
        settings.removeAccount(account.id)
      }
      .controlSize(.small)
    }
  }

  private var activeAccountBinding: Binding<String> {
    Binding(
      get: { settings.selectedAccountID ?? settings.selectedProviderAccounts.first?.id ?? "" },
      set: { settings.selectAccount($0) }
    )
  }
}

/// GitHub picks between the signed-in `gh` CLI and a stored token, so its
/// credentials do not fit the shared field table.
private struct GitHubCredentialFields: View {
  @ObservedObject var settings: ProviderSettingsStore

  var body: some View {
    Picker("Authentication", selection: $settings.usesGitHubCLI) {
      Text("Saved token").tag(false)
      Text("GitHub CLI").tag(true)
    }
    .pickerStyle(.segmented)

    if settings.usesGitHubCLI {
      organizationDiscovery
    } else {
      TextField(
        "Organizations (comma-separated)",
        text: settings.binding(for: .githubOrganization)
      )
      .textContentType(.none)
      SetupLinkedSecureField(
        title: "GitHub token",
        text: settings.binding(for: .githubToken),
        destination: ProviderSetupLinks.githubToken(
          organization: settings.primaryGitHubOrganization
        ),
        actionLabel: "Create token",
        linkEnabled: settings.hasSingleGitHubOrganization
      )
      SettingsHelpText(ProviderAccountType.github.credentialHelp)
    }
  }

  @ViewBuilder
  private var organizationDiscovery: some View {
    HStack {
      Button("Discover organizations") {
        settings.discoverGitHubOrganizations()
      }
      .disabled(settings.isDiscoveringGitHubOrganizations)
      if settings.isDiscoveringGitHubOrganizations {
        ProgressView()
          .controlSize(.small)
      }
      Spacer()
      if !settings.availableGitHubOrganizations.isEmpty {
        Button("All") { settings.selectAllGitHubOrganizations() }
        Button("None") { settings.clearGitHubOrganizations() }
      }
    }
    ForEach(settings.availableGitHubOrganizations, id: \.self) { organization in
      Toggle(organization, isOn: selectionBinding(for: organization))
    }
    SettingsHelpText("Costbar invokes the signed-in gh CLI directly; its token is never exported.")
  }

  private func selectionBinding(for organization: String) -> Binding<Bool> {
    Binding(
      get: { settings.isGitHubOrganizationSelected(organization) },
      set: { settings.setGitHubOrganization(organization, selected: $0) }
    )
  }
}
