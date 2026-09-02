import SwiftUI

@main
@MainActor
struct CostbarApp: App {
  @StateObject private var store: DashboardStore
  @StateObject private var settings: ProviderSettingsStore
  @StateObject private var notchSettings: NotchSettingsStore
  /// Lives as long as the app: the notch is there whether or not the menu is.
  private let notch: AgentNotchController

  init() {
    let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    let credentials = CredentialStore(
      service: isTesting
        ? "com.costbar.provider-credentials.test-host"
        : "com.costbar.provider-credentials"
    )
    let store = DashboardStore(
      credentials: credentials,
      automaticallyRefreshes: !isTesting
    )
    let notchSettings = NotchSettingsStore()
    _store = StateObject(wrappedValue: store)
    _settings = StateObject(wrappedValue: ProviderSettingsStore(credentials: credentials))
    _notchSettings = StateObject(wrappedValue: notchSettings)
    notch = AgentNotchController(store: store, settings: notchSettings)
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
      ProviderSettingsView(settings: settings, dashboard: store, notch: notchSettings)
    }
  }
}
