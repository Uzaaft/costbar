import SwiftUI

struct BreakdownWindowView: View {
  @ObservedObject var store: DashboardStore
  @State private var section = WindowSection.overview
  @State private var grouping = SpendGrouping.service
  @State private var selectedProviderID: String?

  var body: some View {
    HStack(spacing: 0) {
      BreakdownSidebar(
        dashboard: store.dashboard,
        section: $section,
        selectedProviderID: $selectedProviderID
      )
      .frame(width: 232)

      Rectangle()
        .fill(WindowPalette.hairline)
        .frame(width: 1)

      VStack(spacing: 0) {
        DashboardCommandBar(store: store, grouping: $grouping)

        Rectangle()
          .fill(WindowPalette.hairline)
          .frame(height: 1)

        dashboardContent
      }
    }
    .frame(minWidth: 1_020, idealWidth: 1_180, minHeight: 650, idealHeight: 760)
    .background(WindowPalette.background)
    .environment(\.colorScheme, .dark)
  }

  @ViewBuilder
  private var dashboardContent: some View {
    if let dashboard = store.dashboard, let total = dashboard.primaryTotal {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          DashboardMetrics(dashboard: dashboard, total: total)

          if let error = store.errorMessage {
            ErrorStrip(message: error)
          }

          SpendCompositionCard(
            entries: visibleEntries(dashboard: dashboard, total: total),
            currency: total.currency,
            grouping: grouping
          )

          BreakdownDataTable(
            dashboard: dashboard,
            total: total,
            section: section,
            selectedProviderID: selectedProviderID
          )
        }
        .padding(.horizontal, 30)
        .padding(.top, 28)
        .padding(.bottom, 34)
      }
    } else if let error = store.errorMessage {
      ContentUnavailableView(
        "Unable to load costs",
        systemImage: "exclamationmark.triangle",
        description: Text(error)
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ProgressView("Loading costs…")
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func visibleEntries(
    dashboard: Dashboard,
    total: Dashboard.CurrencyTotal
  ) -> [SpendEntry] {
    dashboard.spendEntries(currency: total.currency).filter { entry in
      selectedProviderID == nil || entry.providerID == selectedProviderID
    }
  }
}

enum WindowSection: String, CaseIterable, Identifiable {
  case overview
  case providers
  case services
  case resources

  var id: Self { self }

  var title: String {
    switch self {
    case .overview: "Overview"
    case .providers: "By provider"
    case .services: "By service"
    case .resources: "By resource type"
    }
  }

  var icon: String {
    switch self {
    case .overview: "rectangle.grid.2x2"
    case .providers: "building.2"
    case .services: "square.stack.3d.up"
    case .resources: "shippingbox"
    }
  }
}

enum SpendGrouping: String, CaseIterable, Identifiable {
  case service
  case provider

  var id: Self { self }
  var title: String { rawValue.capitalized }
}

private struct BreakdownSidebar: View {
  let dashboard: Dashboard?
  @Binding var section: WindowSection
  @Binding var selectedProviderID: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      sidebarLabel("Views")
        .padding(.top, 26)

      VStack(spacing: 4) {
        ForEach(WindowSection.allCases) { item in
          SidebarButton(
            title: item.title,
            systemImage: item.icon,
            isSelected: section == item && selectedProviderID == nil
          ) {
            section = item
            selectedProviderID = nil
          }
        }
      }
      .padding(.top, 10)

      sidebarLabel("Accounts")
        .padding(.top, 30)

      ScrollView {
        VStack(spacing: 4) {
          ForEach(dashboard?.providers ?? []) { report in
            AccountSidebarButton(
              report: report,
              isSelected: selectedProviderID == report.id
            ) {
              selectedProviderID = report.id
              section = .providers
            }
          }
        }
        .padding(.top, 10)
      }

      Spacer(minLength: 20)

      SettingsLink {
        Label("Add or edit accounts", systemImage: "plus")
          .font(.system(size: 13))
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .padding(.vertical, 11)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .foregroundStyle(WindowPalette.textSecondary)
      .background(
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
          .foregroundStyle(WindowPalette.border)
      )
      .padding(.bottom, 20)
    }
    .padding(.horizontal, 18)
    .background(WindowPalette.sidebar)
  }

  private func sidebarLabel(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 11, weight: .semibold))
      .tracking(1.2)
      .textCase(.uppercase)
      .foregroundStyle(WindowPalette.textTertiary)
      .padding(.horizontal, 10)
  }
}

private struct SidebarButton: View {
  let title: String
  let systemImage: String
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: systemImage)
        .font(.system(size: 13.5, weight: isSelected ? .medium : .regular))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(isSelected ? WindowPalette.textPrimary : WindowPalette.textSecondary)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(isSelected ? WindowPalette.selection : .clear)
    )
  }
}

private struct AccountSidebarButton: View {
  let report: Dashboard.ProviderReport
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 10) {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
          .fill(ProviderTint.color(for: report.id))
          .frame(width: 9, height: 9)

        Text(report.summary.displayName)
          .lineLimit(1)

        Spacer(minLength: 4)

        if report.summary.status == .unavailable {
          Circle()
            .fill(WindowPalette.warning)
            .frame(width: 5, height: 5)
        }
      }
      .font(.system(size: 13))
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 11)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(isSelected ? WindowPalette.textPrimary : WindowPalette.textSecondary)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(isSelected ? WindowPalette.selection : .clear)
    )
  }
}

private struct DashboardCommandBar: View {
  @ObservedObject var store: DashboardStore
  @Binding var grouping: SpendGrouping

  var body: some View {
    HStack(spacing: 14) {
      PeriodSelector()

      Spacer(minLength: 20)

      Menu {
        Picker("Group spend", selection: $grouping) {
          ForEach(SpendGrouping.allCases) { option in
            Text(option.title).tag(option)
          }
        }
      } label: {
        CommandPill(title: "Group: \(grouping.title)", systemImage: "chevron.down")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()

      Button {
        store.refresh()
      } label: {
        HStack(spacing: 8) {
          if store.isRefreshing {
            ProgressView()
              .controlSize(.mini)
          } else {
            Image(systemName: "arrow.clockwise")
          }
          Text(refreshTitle)
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(WindowPalette.textSecondary)
        .padding(.horizontal, 13)
        .frame(height: 34)
        .background(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(WindowPalette.border, lineWidth: 1)
        )
      }
      .buttonStyle(.plain)
      .disabled(store.isRefreshing)
      .keyboardShortcut("r", modifiers: .command)
    }
    .padding(.horizontal, 30)
    .frame(height: 72)
    .background(WindowPalette.chrome)
  }

  private var refreshTitle: String {
    guard let updated = store.lastUpdatedAt else { return "Refresh" }
    return updated.formatted(date: .omitted, time: .shortened)
  }
}

private struct PeriodSelector: View {
  var body: some View {
    HStack(spacing: 2) {
      periodButton("Day", enabled: false)
      periodButton("Month", enabled: true)
      periodButton("Quarter", enabled: false)
    }
    .padding(3)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(WindowPalette.controlBackground)
    )
    .help("Daily and quarterly history will appear when providers expose time-series data.")
  }

  private func periodButton(_ title: String, enabled: Bool) -> some View {
    Text(title)
      .font(.system(size: 13, weight: enabled ? .semibold : .regular))
      .foregroundStyle(enabled ? WindowPalette.textPrimary : WindowPalette.textTertiary)
      .padding(.horizontal, 15)
      .frame(height: 30)
      .background(
        RoundedRectangle(cornerRadius: 7, style: .continuous)
          .fill(enabled ? WindowPalette.segmentSelected : .clear)
      )
  }
}

private struct CommandPill: View {
  let title: String
  let systemImage: String

  var body: some View {
    HStack(spacing: 8) {
      Text(title)
      Image(systemName: systemImage)
        .font(.system(size: 9, weight: .semibold))
    }
    .font(.system(size: 12.5, weight: .medium))
    .foregroundStyle(WindowPalette.textSecondary)
    .padding(.horizontal, 13)
    .frame(height: 34)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(WindowPalette.border, lineWidth: 1)
    )
  }
}

private struct DashboardMetrics: View {
  let dashboard: Dashboard
  let total: Dashboard.CurrencyTotal

  var body: some View {
    HStack(alignment: .bottom, spacing: 34) {
      VStack(alignment: .leading, spacing: 7) {
        MetricLabel("Month to date")
        HeroCurrencyAmount(micros: total.currentCostMicros, currency: total.currency)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      MetricValue(
        title: "Projected",
        value: total.projectedCostMicros?.currencyText(code: total.currency) ?? "—"
      )

      MetricValue(
        title: "Credit remaining",
        value: total.creditRemainingMicros?.currencyText(code: total.currency) ?? "—"
      )

      MetricValue(
        title: "Accounts",
        value: "\(availableProviderCount) / \(dashboard.providers.count)"
      )
    }
  }

  private var availableProviderCount: Int {
    dashboard.providers.filter { $0.summary.status == .available }.count
  }
}

private struct MetricLabel: View {
  let title: String

  init(_ title: String) {
    self.title = title
  }

  var body: some View {
    Text(title)
      .font(.system(size: 11, weight: .semibold))
      .tracking(1.15)
      .textCase(.uppercase)
      .foregroundStyle(WindowPalette.textTertiary)
  }
}

private struct MetricValue: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      MetricLabel(title)
      Text(value)
        .font(.system(size: 25, weight: .light))
        .monospacedDigit()
        .foregroundStyle(WindowPalette.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(minWidth: 130, alignment: .leading)
  }
}

private struct HeroCurrencyAmount: View {
  let micros: Int64
  let currency: String

  var body: some View {
    let display = CurrencyDisplay(micros: micros, code: currency)
    HStack(alignment: .firstTextBaseline, spacing: 1) {
      Text(display.symbol)
        .font(.system(size: 29, weight: .light))
        .foregroundStyle(WindowPalette.textSecondary)
      Text(display.whole)
        .font(.system(size: 50, weight: .light))
      Text(display.fraction)
        .font(.system(size: 31, weight: .light))
        .foregroundStyle(WindowPalette.textTertiary)
    }
    .monospacedDigit()
    .foregroundStyle(WindowPalette.textPrimary)
    .lineLimit(1)
    .minimumScaleFactor(0.65)
  }
}

private struct ErrorStrip: View {
  let message: String

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: "exclamationmark.triangle.fill")
      Text(message)
        .lineLimit(2)
      Spacer(minLength: 0)
    }
    .font(.system(size: 12))
    .foregroundStyle(WindowPalette.warning)
    .padding(12)
    .background(WindowPalette.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
  }
}

enum ProviderTint {
  static func color(for id: String) -> Color {
    switch id {
    case "digitalocean": Color(red: 0.22, green: 0.49, blue: 0.96)
    case "cloudflare": Color(red: 0.95, green: 0.49, blue: 0.20)
    case "runpod": Color(red: 0.40, green: 0.78, blue: 0.55)
    case "vercel": Color(red: 0.91, green: 0.91, blue: 0.94)
    case "openrouter": Color(red: 0.51, green: 0.46, blue: 0.93)
    case "subscriptions": Color(red: 0.73, green: 0.45, blue: 0.91)
    case "codex": Color(red: 0.23, green: 0.75, blue: 0.66)
    case "claude": Color(red: 0.82, green: 0.44, blue: 0.29)
    case "openai-api": Color(red: 0.22, green: 0.72, blue: 0.62)
    case "anthropic-api": Color(red: 0.78, green: 0.43, blue: 0.26)
    case "github": Color(red: 0.65, green: 0.65, blue: 0.72)
    case "cursor": Color(red: 0.55, green: 0.70, blue: 0.98)
    default: WindowPalette.blue
    }
  }
}

enum WindowPalette {
  static let background = Color(red: 0.072, green: 0.072, blue: 0.082)
  static let sidebar = Color(red: 0.09, green: 0.092, blue: 0.102)
  static let chrome = Color(red: 0.075, green: 0.076, blue: 0.086)
  static let controlBackground = Color.white.opacity(0.055)
  static let segmentSelected = Color.white.opacity(0.13)
  static let selection = Color(red: 0.17, green: 0.24, blue: 0.27)
  static let textPrimary = Color.white.opacity(0.94)
  static let textSecondary = Color.white.opacity(0.62)
  static let textTertiary = Color.white.opacity(0.34)
  static let hairline = Color.white.opacity(0.075)
  static let border = Color.white.opacity(0.12)
  static let blue = Color(red: 0.25, green: 0.52, blue: 0.95)
  static let warning = Color(red: 0.96, green: 0.61, blue: 0.22)
}
