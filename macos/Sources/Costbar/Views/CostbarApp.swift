import SwiftUI

@main
@MainActor
struct CostbarApp: App {
  @StateObject private var store: DashboardStore
  @StateObject private var settings: ProviderSettingsStore

  init() {
    let credentials = CredentialStore()
    _store = StateObject(wrappedValue: DashboardStore(credentials: credentials))
    _settings = StateObject(wrappedValue: ProviderSettingsStore(credentials: credentials))
  }

  var body: some Scene {
    WindowGroup("Costbar — Breakdown", id: "dashboard") {
      BreakdownWindowView(store: store)
    }
    .defaultSize(width: 1_180, height: 760)
    .windowResizability(.contentMinSize)
    .windowToolbarStyle(.unifiedCompact(showsTitle: true))

    MenuBarExtra {
      DashboardView(store: store)
    } label: {
      Label(store.menuBarTitle, systemImage: "dollarsign.square")
    }
    .menuBarExtraStyle(.window)

    Settings {
      ProviderSettingsView(settings: settings, dashboard: store)
    }
  }
}
