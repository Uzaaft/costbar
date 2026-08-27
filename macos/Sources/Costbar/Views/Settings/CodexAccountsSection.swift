import SwiftUI

/// Codex accounts are owned by the Codex CLI, so every mutation here runs a CLI
/// task and reloads the on-disk profile list afterwards.
struct CodexAccountsSection: View {
  @ObservedObject var settings: ProviderSettingsStore
  @ObservedObject var dashboard: DashboardStore

  var body: some View {
    Section("Accounts") {
      if settings.codexAccounts.isEmpty {
        Text("No Codex accounts detected yet.")
          .foregroundStyle(.secondary)
      } else {
        accountPickers
        Divider()
        ForEach(settings.codexAccounts) { account in
          CodexAccountRow(account: account, settings: settings, dashboard: dashboard)
        }
      }

      Button(addAccountTitle) {
        run {
          guard await settings.addCodexAccount() else { return false }
          _ = settings.save()
          return true
        }
      }
      .disabled(settings.hasCodexAccountOperationInFlight)

      SettingsHelpText("Sign-in runs through the installed Codex CLI. Added accounts use isolated Costbar-managed CODEX_HOME profiles.")
    }
  }

  private var accountPickers: some View {
    VStack(alignment: .leading, spacing: 6) {
      CodexAccountPickerRow(label: "Active") {
        Picker("", selection: activeAccountBinding) {
          ForEach(settings.codexAccounts) { account in
            Text(account.displayName).tag(account.id)
          }
        }
      }
      SettingsHelpText("Choose which Codex account Costbar should follow.")

      CodexAccountPickerRow(label: "System") {
        if let systemAccountBinding {
          Picker("", selection: systemAccountBinding) {
            ForEach(settings.codexAccounts) { account in
              Text(account.displayName).tag(account.id)
            }
          }
        } else {
          // No CLI login exists yet, so there is nothing to switch between —
          // only managed profiles can be promoted into place.
          Menu("No system account") {
            ForEach(settings.codexAccounts) { account in
              Button(account.displayName) {
                run { await settings.selectSystemCodexAccount(account.id) }
              }
              .disabled(account.managedAccountID == nil)
            }
          }
          .font(.subheadline)
        }
      }
      SettingsHelpText("The default Codex CLI account on this Mac.")
    }
    .disabled(settings.hasCodexAccountOperationInFlight)
  }

  private var addAccountTitle: String {
    settings.codexOperation == .addingAccount ? "Adding Account…" : "Add Account"
  }

  private var activeAccountBinding: Binding<String> {
    Binding(
      get: { settings.codexActiveAccountID ?? settings.codexAccounts.first?.id ?? "" },
      set: { id in
        settings.selectActiveCodexAccount(id)
        dashboard.refresh()
      }
    )
  }

  private var systemAccountBinding: Binding<String>? {
    guard let systemID = settings.codexSystemAccountID else { return nil }
    return Binding(
      get: { settings.codexSystemAccountID ?? systemID },
      set: { id in run { await settings.selectSystemCodexAccount(id) } }
    )
  }

  /// Refreshes the dashboard only when the CLI task actually changed something.
  private func run(_ operation: @escaping () async -> Bool) {
    Task {
      if await operation() { dashboard.refresh() }
    }
  }
}

/// A label column wide enough to keep the two account pickers aligned.
private struct CodexAccountPickerRow<Control: View>: View {
  let label: String
  @ViewBuilder let control: Control

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(label)
        .font(.subheadline.weight(.semibold))
        .frame(width: 92, alignment: .leading)
      control
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
      Spacer(minLength: 0)
    }
  }
}

private struct CodexAccountRow: View {
  let account: VisibleCodexAccount
  @ObservedObject var settings: ProviderSettingsStore
  @ObservedObject var dashboard: DashboardStore

  var body: some View {
    HStack(spacing: 12) {
      Text(account.displayName)
        .font(.subheadline.weight(.semibold))
      if account.isSystem {
        Text("(System)")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
      }
      Spacer()

      Button(reauthenticationTitle) {
        run { await settings.reauthenticateCodexAccount(account) }
      }
      .disabled(settings.hasCodexAccountOperationInFlight)

      if account.managedAccountID != nil {
        Button(removalTitle) {
          run { await settings.removeCodexAccount(account) }
        }
        .disabled(settings.hasCodexAccountOperationInFlight)
      }
    }
  }

  private var reauthenticationTitle: String {
    settings.codexOperation == .reauthenticating(account.managedAccountID)
      ? "Re-authenticating…"
      : "Re-auth"
  }

  private var removalTitle: String {
    guard let managedAccountID = account.managedAccountID else { return "Remove" }
    return settings.codexOperation == .removing(managedAccountID) ? "Removing…" : "Remove"
  }

  private func run(_ operation: @escaping () async -> Bool) {
    Task {
      if await operation() { dashboard.refresh() }
    }
  }
}
