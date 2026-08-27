import SwiftUI

/// What the sidebar selection points at.
enum SettingsDestination: Hashable {
  case general
  case provider(ProviderAccountType)
  case local(LocalSource)
}

struct ProviderSettingsView: View {
  @ObservedObject var settings: ProviderSettingsStore
  @ObservedObject var dashboard: DashboardStore
  @State private var selection: SettingsDestination?
  @State private var searchText = ""

  var body: some View {
    NavigationSplitView {
      SettingsSidebar(
        settings: settings,
        selection: $selection,
        searchText: $searchText
      )
    } detail: {
      detail
    }
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: 940, idealWidth: 1_080, minHeight: 680, idealHeight: 760)
    .onAppear {
      if selection == nil {
        selection = .provider(settings.selectedProviderType)
      }
    }
    .onChange(of: selection) { _, destination in
      guard case let .provider(provider) = destination else { return }
      settings.selectProvider(provider)
    }
  }

  @ViewBuilder
  private var detail: some View {
    switch selection ?? .general {
    case .general:
      GeneralSettingsDetail(settings: settings, dashboard: dashboard)
    case let .provider(provider):
      ProviderAccountSettingsDetail(
        provider: provider,
        settings: settings,
        dashboard: dashboard
      )
      .tint(ProviderTint.color(for: provider.sourceID))
    case let .local(source):
      LocalSourceSettingsDetail(
        source: source,
        settings: settings,
        dashboard: dashboard
      )
      .tint(ProviderTint.color(for: source.sourceID))
    }
  }
}

private struct SettingsSidebar: View {
  @ObservedObject var settings: ProviderSettingsStore
  @Binding var selection: SettingsDestination?
  @Binding var searchText: String

  var body: some View {
    List(selection: $selection) {
      SettingsSidebarRow(
        icon: .symbol("gearshape.fill", tint: WindowPalette.blue),
        title: "General",
        isEnabled: false
      )
      .tag(SettingsDestination.general)

      Section {
        ForEach(filteredLocalSources) { source in
          SettingsSidebarRow(
            icon: .provider(id: source.sourceID),
            title: source.displayName,
            isEnabled: settings.tracks(source)
          )
          .tag(SettingsDestination.local(source))
        }

        ForEach(filteredProviders) { provider in
          SettingsSidebarRow(
            icon: .provider(id: provider.sourceID),
            title: provider.displayName,
            isEnabled: !settings.accounts(for: provider).isEmpty
          )
          .tag(SettingsDestination.provider(provider))
        }
      } header: {
        HStack {
          Text("Providers")
          Spacer()
          Text("\(enabledSourceCount) on")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
    }
    .listStyle(.sidebar)
    .searchable(text: $searchText, prompt: "Search providers")
    .navigationSplitViewColumnWidth(min: 220, ideal: 245, max: 300)
  }

  private var filteredProviders: [ProviderAccountType] {
    ProviderAccountType.allCases.filter { matchesSearch($0.displayName) }
  }

  private var filteredLocalSources: [LocalSource] {
    LocalSource.allCases.filter { matchesSearch($0.displayName) }
  }

  private var enabledSourceCount: Int {
    ProviderAccountType.allCases.filter { !settings.accounts(for: $0).isEmpty }.count +
      settings.trackedLocalSources.count
  }

  private func matchesSearch(_ value: String) -> Bool {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty || value.localizedCaseInsensitiveContains(query)
  }
}
