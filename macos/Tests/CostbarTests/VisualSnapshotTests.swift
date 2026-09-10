import AppKit
import SwiftUI
import Testing
@testable import Costbar

/// Renders the real views to PNG for visual review. Only runs when
/// `COSTBAR_SNAPSHOT_DIR` is set, so the normal test run stays headless:
///
///     COSTBAR_SNAPSHOT_DIR=/tmp/shots xcodebuild test -only-testing:CostbarTests/VisualSnapshotTests …
///
/// Rendering happens in-process, so no Screen Recording permission is needed.
/// Liquid Glass, materials, and sidebar vibrancy sample what is behind the
/// window, which an offscreen render does not have: glass shows flat, glass
/// content can resolve to the wrong appearance, and sidebar selection and icons
/// draw dark. Check those on screen.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["COSTBAR_SNAPSHOT_DIR"] != nil))
struct VisualSnapshotTests {
  private let directory = URL(
    fileURLWithPath: ProcessInfo.processInfo.environment["COSTBAR_SNAPSHOT_DIR"] ?? NSTemporaryDirectory()
  )

  @Test(arguments: [ColorScheme.light, .dark])
  func menuBarPopover(scheme: ColorScheme) throws {
    let store = SnapshotFixture.store()
    let menuBar = MenuBarSettingsStore(defaults: SnapshotFixture.defaults())
    try render(
      DashboardView(store: store, menuBar: menuBar),
      size: CGSize(width: 320, height: 560),
      scheme: scheme,
      name: "menu-popover"
    )
  }

  @Test(arguments: [ColorScheme.light, .dark])
  func providerHoverCard(scheme: ColorScheme) throws {
    try render(
      ProviderDetailCard(report: SnapshotFixture.claude),
      size: CGSize(width: 300, height: 520),
      scheme: scheme,
      name: "hover-card"
    )
  }

  @Test(arguments: [ColorScheme.light, .dark])
  func breakdownWindow(scheme: ColorScheme) throws {
    try render(
      BreakdownWindowView(store: SnapshotFixture.store()),
      size: CGSize(width: 1_180, height: 760),
      scheme: scheme,
      name: "breakdown-window",
      titled: true
    )
  }

  @Test(arguments: [ColorScheme.light, .dark])
  func breakdownSidebar(scheme: ColorScheme) throws {
    try render(
      BreakdownSidebar(dashboard: SnapshotFixture.dashboard, selection: .constant(.section(.overview))),
      size: CGSize(width: 232, height: 520),
      scheme: scheme,
      name: "breakdown-sidebar"
    )
  }

  private func render(
    _ view: some View,
    size: CGSize,
    scheme: ColorScheme,
    name: String,
    titled: Bool = false
  ) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let hosting = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: size),
      styleMask: titled ? [.titled, .fullSizeContentView, .resizable] : [.borderless],
      backing: .buffered,
      defer: false
    )
    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    window.backgroundColor = .windowBackgroundColor
    window.contentView = hosting
    window.setContentSize(size)
    window.layoutIfNeeded()
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))

    let target = window.contentView?.superview ?? hosting
    let bitmap = try #require(target.bitmapImageRepForCachingDisplay(in: target.bounds))
    target.cacheDisplay(in: target.bounds, to: bitmap)
    let data = try #require(bitmap.representation(using: .png, properties: [:]))
    try data.write(to: directory.appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png"))
    window.orderOut(nil)
  }
}

@MainActor
private enum SnapshotFixture {
  static func defaults() -> UserDefaults {
    UserDefaults(suiteName: "com.costbar.tests.snapshots.\(UUID().uuidString)")!
  }

  static func store() -> DashboardStore {
    DashboardStore(
      credentials: Credentials(),
      automaticallyRefreshes: false,
      publishSnapshot: { _ in },
      coreFactory: { Core(dashboard: dashboard) }
    )
  }

  static let now = Int64(Date().timeIntervalSince1970)

  static let dashboard = Dashboard(
    period: .currentMonth(),
    generatedAtUnix: now - 42,
    totals: [
      .init(
        currency: "USD",
        currentCostMicros: 184_270_000,
        projectedCostMicros: 312_900_000,
        creditRemainingMicros: nil,
        projectionComplete: true,
        creditComplete: false
      ),
    ],
    providers: [hetzner, cloudflare, claude, codex]
  )

  static let hetzner = report(
    type: "hetzner", name: "Hetzner", cost: 96_400_000,
    resources: [.init(id: "s1", name: "Servers", kind: "product", status: "active", quantity: 3)],
    lineItems: [
      .init(id: "a", description: "CX32 · web-1", service: "Servers", amountMicros: 41_200_000, currency: "USD", detail: "744 h"),
      .init(id: "b", description: "CX32 · web-2", service: "Servers", amountMicros: 41_200_000, currency: "USD", detail: "744 h"),
      .init(id: "c", description: "Volume · 200 GB", service: "Volumes", amountMicros: 14_000_000, currency: "USD", detail: nil),
    ]
  )

  static let cloudflare = report(
    type: "cloudflare", name: "Cloudflare", cost: 87_870_000,
    resources: [.init(id: "w", name: "Workers", kind: "product", status: "active", quantity: 2)],
    lineItems: [
      .init(id: "d", description: "Workers Paid", service: "Workers", amountMicros: 5_000_000, currency: "USD", detail: "monthly"),
      .init(id: "e", description: "R2 storage", service: "R2", amountMicros: 82_870_000, currency: "USD", detail: "5.5 TB"),
    ]
  )

  static let claude = report(
    type: "claude", name: "Claude · Max", cost: 0, contributes: false,
    windows: [
      .init(id: "session", label: "Session (5h)", usedPercent: 37, resetsAtUnix: now + 7_200, durationMinutes: 300, detail: nil),
      .init(id: "weekly_all", label: "Weekly", usedPercent: 92, resetsAtUnix: now + 260_000, durationMinutes: 10_080, detail: nil),
    ]
  )

  static let codex = report(
    type: "codex", name: "Codex · Pro", cost: 0, contributes: false,
    windows: [
      .init(id: "primary", label: "5h window", usedPercent: 12, resetsAtUnix: now + 9_000, durationMinutes: 300, detail: nil),
      .init(id: "secondary", label: "Weekly", usedPercent: 48, resetsAtUnix: now + 400_000, durationMinutes: 10_080, detail: nil),
    ]
  )

  static func report(
    type: String,
    name: String,
    cost: Int64,
    contributes: Bool = true,
    resources: [Dashboard.Resource] = [],
    lineItems: [Dashboard.CostLineItem] = [],
    windows: [Dashboard.AllowanceWindow] = []
  ) -> Dashboard.ProviderReport {
    .init(
      summary: .init(
        id: type, displayName: name, sourceID: type, kind: contributes ? "cloud" : "ai",
        status: .available, errorMessage: nil, currency: "USD",
        currentCostMicros: cost, projectedCostMicros: nil, creditRemainingMicros: nil,
        contributesToTotals: contributes, updatedAtUnix: now - 42
      ),
      resources: resources,
      lineItems: lineItems,
      allowanceWindows: windows,
      tokenUsage: nil,
      tokenUsageWindows: [],
      tokenUsageSeries: [],
      spendSeries: [],
      financials: []
    )
  }

  private final class Credentials: DashboardCredentials {
    func loadAccountData() throws -> [ProviderAccountData] { [] }
  }

  private final class Core: DashboardCore {
    let dashboard: Dashboard
    init(dashboard: Dashboard) { self.dashboard = dashboard }
    func cachedSnapshot(period _: Dashboard.Period, accountData _: [ProviderAccountData]) throws -> Dashboard? { dashboard }
    func snapshot(period _: Dashboard.Period) throws -> Dashboard { dashboard }
    func refresh(_: DashboardRefreshRequest) async throws -> CostbarCore.RefreshReport {
      .init(configuredCount: 0, refreshedCount: 0, errors: nil)
    }
  }
}
