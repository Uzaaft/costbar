import AppKit
import SwiftUI

@main
@MainActor
struct CostbarApp: App {
  @StateObject private var store: DashboardStore
  @StateObject private var settings: ProviderSettingsStore
  @StateObject private var notchSettings: NotchSettingsStore
  @StateObject private var menuBarSettings: MenuBarSettingsStore
  @StateObject private var sessions: SessionStore
  /// Lives as long as the app: the notch is there whether or not the menu is.
  private let notch: AgentNotchController

  init() {
    let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    let credentials = CredentialStore(
      service: isTesting
        ? "com.costbar.provider-credentials.test-host"
        : "com.costbar.provider-credentials",
      prefersICloudKeychain: !isTesting
    )
    let sessions = SessionStore()
    let notifications = QuotaNotificationController()
    let store = DashboardStore(
      credentials: credentials,
      automaticallyRefreshes: !isTesting,
      publishSnapshot: { dashboard in
        MobileSyncStore.shared.publish(dashboard)
        notifications.publish(dashboard)
      },
      activityBusy: { sessions.anyBusy }
    )
    let notchSettings = NotchSettingsStore()
    let menuBarSettings = MenuBarSettingsStore()
    _store = StateObject(wrappedValue: store)
    _settings = StateObject(wrappedValue: ProviderSettingsStore(credentials: credentials))
    _notchSettings = StateObject(wrappedValue: notchSettings)
    _menuBarSettings = StateObject(wrappedValue: menuBarSettings)
    _sessions = StateObject(wrappedValue: sessions)
    notch = AgentNotchController(store: store, sessions: sessions, settings: notchSettings)
    if !isTesting {
      sessions.start()
    }
  }

  var body: some Scene {
    WindowGroup("Breakdown", id: "dashboard") {
      BreakdownWindowView(store: store)
    }
    .defaultSize(width: 1_180, height: 760)
    .windowResizability(.contentMinSize)
    .windowToolbarStyle(.unified(showsTitle: true))

    MenuBarExtra {
      DashboardView(store: store, menuBar: menuBarSettings)
    } label: {
      MenuBarStatusLabel(store: store, menuBar: menuBarSettings)
    }
    .menuBarExtraStyle(.window)

    Settings {
      ProviderSettingsView(
        settings: settings,
        dashboard: store,
        notch: notchSettings,
        menuBar: menuBarSettings
      )
    }
  }
}

/// One number, chosen in the popover or General settings, beside a glyph that
/// says what kind of number it is: a gauge for quota, a coin for spend.
private struct MenuBarStatusLabel: View {
  @ObservedObject var store: DashboardStore
  @ObservedObject var menuBar: MenuBarSettingsStore

  var body: some View {
    let metric = menuBar.metric
    let percent = store.dashboard?.menuBarPercent(for: metric)
    HStack(spacing: 4) {
      if metric.agents != nil {
        Image(nsImage: MenuBarGauge.image(fraction: (percent ?? 0) / 100))
      } else {
        Image(systemName: "dollarsign.circle")
      }
      if let dashboard = store.dashboard {
        Text(dashboard.menuBarTitle(for: metric))
          .monospacedDigit()
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Costbar")
    .accessibilityValue(accessibilityValue(metric: metric))
  }

  private func accessibilityValue(metric: MenuBarMetric) -> String {
    guard let dashboard = store.dashboard else { return "Loading" }
    let title = dashboard.menuBarTitle(for: metric)
    return metric.agents == nil ? "\(title) month to date" : "\(metric.label), \(title) used"
  }
}

/// A ring that fills with the quota it stands for. Drawn as a template image so
/// the menu bar tints it for its own appearance, wallpaper and highlight state;
/// the track is the same ink at low alpha.
private enum MenuBarGauge {
  private static let size: CGFloat = 16
  private static let lineWidth: CGFloat = 2.25

  static func image(fraction: Double) -> NSImage {
    let fraction = min(max(fraction, 0), 1)
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
      let center = NSPoint(x: rect.midX, y: rect.midY)
      let radius = (size - lineWidth) / 2 - 0.5

      let track = NSBezierPath()
      track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
      track.lineWidth = lineWidth
      NSColor.black.withAlphaComponent(0.28).setStroke()
      track.stroke()

      guard fraction > 0 else { return true }
      // Clockwise from twelve o'clock, like every other ring in the app.
      let arc = NSBezierPath()
      arc.appendArc(
        withCenter: center,
        radius: radius,
        startAngle: 90,
        endAngle: 90 - 360 * fraction,
        clockwise: true
      )
      arc.lineWidth = lineWidth
      arc.lineCapStyle = .round
      NSColor.black.setStroke()
      arc.stroke()
      return true
    }
    image.isTemplate = true
    return image
  }
}
