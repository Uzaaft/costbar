import SwiftUI

struct GeneralSettingsDetail: View {
  @ObservedObject var settings: ProviderSettingsStore
  @ObservedObject var dashboard: DashboardStore
  @ObservedObject var notch: NotchSettingsStore
  @ObservedObject var menuBar: MenuBarSettingsStore

  @ObservedObject private var mobileSync = MobileSyncStore.shared

  var body: some View {
    SettingsDetailScaffold(
      icon: .symbol("gearshape.fill", tint: WindowPalette.blue),
      title: "General",
      subtitle: "Refresh timing and source behavior",
      settings: settings,
      dashboard: dashboard
    ) {
      Section("Refresh Schedule") {
        Picker("All sources", selection: $settings.defaultPollingInterval) {
          ForEach(PollingSettings.intervalOptions) { option in
            Text(option.label).tag(option.seconds)
          }
        }

        DisclosureGroup("Per-source overrides") {
          ForEach(PollingSource.all) { source in
            Picker(source.displayName, selection: overrideBinding(for: source.id)) {
              Text("Default (\(PollingSettings.label(for: settings.defaultPollingInterval)))")
                .tag(Int?.none)
              ForEach(PollingSettings.intervalOptions) { option in
                Text(option.label).tag(Int?.some(option.seconds))
              }
            }
          }
        }

        SettingsHelpText("Sources without an override use the all-sources interval.")
      }

      Section("Menu Bar") {
        Picker("Show", selection: $menuBar.metric) {
          ForEach(MenuBarMetric.allCases) { metric in
            Text(metric.label).tag(metric)
          }
        }
        SettingsHelpText(menuBar.metric.detail + " Change it here or from the Costbar menu.")
      }

      Section("Notch") {
        Toggle("Side notch", isOn: $notch.isEnabled)

        Picker("Edge", selection: $notch.edge) {
          ForEach(NotchEdge.allCases) { edge in
            Text(edge.label).tag(edge)
          }
        }
        .pickerStyle(.segmented)

        SettingsHelpText(
          "When enabled, quota rings for Claude, Cursor and Codex slide out from the screen edge when the pointer reaches it. The gear under the rail opens its own settings."
        )
      }

      Section("iPhone Companion") {
        Toggle("Sync usage through private iCloud", isOn: Binding(
          get: { mobileSync.isEnabled },
          set: { mobileSync.setEnabled($0, dashboard: dashboard.dashboard) }
        ))
        .disabled(!MobileSyncStore.isSupported)
        Text(mobileSync.status).foregroundStyle(.secondary)
        SettingsHelpText("Uses the same Apple Account on your Mac and iPhone. Shares provider names, costs and quotas; credentials and session contents stay on this Mac. Keep Costbar running for fresh usage. Requires an iCloud-enabled signed build.")
      }

      Section("Credentials") {
        switch settings.credentialLocation {
        case .iCloudKeychain:
          Label("Synced with iCloud Keychain", systemImage: "key.icloud")
          SettingsHelpText("Provider keys are end-to-end encrypted and available to Costbar on every Mac signed in to your Apple Account with iCloud Keychain turned on. They are never included in the iPhone usage snapshot.")
        case .thisMac:
          Label("Stored in the Keychain on this Mac", systemImage: "key")
          SettingsHelpText("This build is not signed for iCloud Keychain, so provider keys stay on this Mac. Install a signed build to sync them across your Macs.")
        }
      }
    }
  }

  private func overrideBinding(for sourceID: String) -> Binding<Int?> {
    Binding(
      get: { settings.pollingIntervalOverride(for: sourceID) },
      set: { settings.setPollingIntervalOverride($0, for: sourceID) }
    )
  }
}
