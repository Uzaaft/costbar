import SwiftUI

struct GeneralSettingsDetail: View {
  @ObservedObject var settings: ProviderSettingsStore
  @ObservedObject var dashboard: DashboardStore

  var body: some View {
    SettingsDetailScaffold(
      icon: .symbol("gearshape.fill", tint: WindowPalette.blue),
      title: "General",
      subtitle: "Refresh timing and source behavior",
      settings: settings,
      dashboard: dashboard
    ) {
      Section("Refresh schedule") {
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

      Section("Credentials") {
        Text("Provider secrets are kept in the macOS Keychain. Account labels and active selections are stored separately from secret values.")
          .foregroundStyle(.secondary)
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
