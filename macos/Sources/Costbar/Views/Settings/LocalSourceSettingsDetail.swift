import SwiftUI

struct LocalSourceSettingsDetail: View {
  let source: LocalSource
  @ObservedObject var settings: ProviderSettingsStore
  @ObservedObject var dashboard: DashboardStore

  var body: some View {
    SettingsDetailScaffold(
      icon: .provider(id: source.sourceID),
      title: source.displayName,
      subtitle: settings.tracks(source) ? "Enabled" : "Disabled",
      settings: settings,
      dashboard: dashboard
    ) {
      if source == .codex {
        CodexAccountsSection(settings: settings, dashboard: dashboard)
      }

      Section("Usage source") {
        Toggle(
          "Track \(source.displayName) usage",
          isOn: settings.trackingBinding(for: source)
        )
        Text(source.trackingDescription)
          .foregroundStyle(.secondary)
      }

      if source == .claude, settings.tracks(.claude) {
        ClaudeQuotaBridgeSection(settings: settings)
      }
    }
    .onAppear {
      if source == .codex { settings.refreshCodexAccounts() }
    }
  }
}

/// Claude publishes subscription quota only through its status-line hook, so
/// Costbar swaps in a bridge script to read it.
private struct ClaudeQuotaBridgeSection: View {
  @ObservedObject var settings: ProviderSettingsStore

  var body: some View {
    Section("Subscription quota") {
      if settings.hasClaudeStatusBridge {
        Button("Restore previous Claude status line") {
          settings.restoreClaudeStatusLine()
        }
      } else {
        Button("Install Claude quota bridge") {
          settings.installClaudeStatusBridge()
        }
      }
      SettingsHelpText("The bridge captures Claude's official status-line rate-limit feed without retaining prompts or responses.")
    }
  }
}
