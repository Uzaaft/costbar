import SwiftUI

struct BreakdownWindowView: View {
  @ObservedObject var store: DashboardStore
  @State private var section = WindowSection.overview
  @State private var grouping = SpendGrouping.service
  @State private var selectedProviderID: String?
  @State private var selectedTokenWindowID = "month"

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
        DashboardCommandBar(
          store: store,
          grouping: $grouping,
          usageWindows: selectedProvider?.tokenUsageWindows ?? [],
          selectedTokenWindowID: $selectedTokenWindowID
        )

        Rectangle()
          .fill(WindowPalette.hairline)
          .frame(height: 1)

        dashboardContent
      }
    }
    .frame(minWidth: 1_020, idealWidth: 1_180, minHeight: 650, idealHeight: 760)
    .background(WindowPalette.background)
    .environment(\.colorScheme, .dark)
    .onChange(of: selectedProviderID) { _, providerID in
      selectedTokenWindowID = "month"
      if providerID != nil {
        grouping = .resource
      }
    }
  }

  private var selectedProvider: Dashboard.ProviderReport? {
    guard let selectedProviderID else { return nil }
    return store.dashboard?.providers.first { $0.id == selectedProviderID }
  }

  @ViewBuilder
  private var dashboardContent: some View {
    if let dashboard = store.dashboard, let total = displayTotal(in: dashboard) {
      let selectedProvider = dashboard.providers.first { $0.id == selectedProviderID }
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          DashboardMetrics(
            dashboard: dashboard,
            total: total,
            selectedProvider: selectedProvider,
            selectedTokenWindowID: selectedTokenWindowID
          )

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
    } else if let dashboard = store.dashboard,
              dashboard.providers.allSatisfy({ $0.summary.status == .notConfigured }) {
      ContentUnavailableView(
        "No providers configured",
        systemImage: "gearshape",
        description: Text("Add provider credentials or enable a local integration in Settings.")
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
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

  private func displayTotal(in dashboard: Dashboard) -> Dashboard.CurrencyTotal? {
    guard
      let selectedProviderID,
      let report = dashboard.providers.first(where: { $0.id == selectedProviderID })
    else {
      return dashboard.primaryTotal
    }

    let financial = report.financials.first { value in
      value.currency == report.summary.currency
    }
    return Dashboard.CurrencyTotal(
      currency: financial?.currency ?? report.summary.currency,
      currentCostMicros: financial?.currentCostMicros ?? report.summary.currentCostMicros,
      projectedCostMicros: financial?.projectedCostMicros ?? report.summary.projectedCostMicros,
      creditRemainingMicros: financial?.creditRemainingMicros
        ?? report.summary.creditRemainingMicros,
      projectionComplete: financial?.projectedCostMicros != nil
        || report.summary.projectedCostMicros != nil,
      creditComplete: financial?.creditRemainingMicros != nil
        || report.summary.creditRemainingMicros != nil
    )
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
  case resource

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
        ProviderLogo(providerID: report.id, size: 17)

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
  let usageWindows: [Dashboard.TokenUsageWindow]
  @Binding var selectedTokenWindowID: String

  var body: some View {
    HStack(spacing: 14) {
      PeriodSelector(
        windows: usageWindows,
        selection: $selectedTokenWindowID
      )

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
  let windows: [Dashboard.TokenUsageWindow]
  @Binding var selection: String

  var body: some View {
    HStack(spacing: 2) {
      periodButton(id: "month", title: "Month")
      ForEach(windows) { window in
        periodButton(id: window.id, title: shortLabel(for: window))
      }
    }
    .padding(3)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(WindowPalette.controlBackground)
    )
    .help(windows.isEmpty ? "Monthly data" : "Choose a rolling local-usage window")
  }

  private func periodButton(id: String, title: String) -> some View {
    Button {
      selection = id
    } label: {
      Text(title)
        .font(.system(size: 13, weight: selection == id ? .semibold : .regular))
        .foregroundStyle(
          selection == id ? WindowPalette.textPrimary : WindowPalette.textSecondary
        )
        .padding(.horizontal, 13)
        .frame(height: 30)
        .background(
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selection == id ? WindowPalette.segmentSelected : .clear)
        )
    }
    .buttonStyle(.plain)
  }

  private func shortLabel(for window: Dashboard.TokenUsageWindow) -> String {
    switch window.id {
    case "hour": "1h"
    case "day": "24h"
    case "week": "7d"
    case "thirty-days": "30d"
    default: window.label
    }
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
  let selectedProvider: Dashboard.ProviderReport?
  let selectedTokenWindowID: String

  var body: some View {
    if let selectedProvider {
      AccountMetrics(
        report: selectedProvider,
        total: total,
        selectedTokenWindowID: selectedTokenWindowID
      )
    } else {
      overviewMetrics
    }
  }

  private var overviewMetrics: some View {
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

private struct AccountMetrics: View {
  private struct Value {
    let title: String
    let value: String
  }

  private struct DisplayedUsage {
    let label: String
    let inputTokens: UInt64
    let outputTokens: UInt64
    let cacheReadTokens: UInt64
    let totalTokens: UInt64
  }

  let report: Dashboard.ProviderReport
  let total: Dashboard.CurrencyTotal
  let selectedTokenWindowID: String

  private var summary: Dashboard.ProviderSummary { report.summary }

  var body: some View {
    HStack(alignment: .bottom, spacing: 34) {
      VStack(alignment: .leading, spacing: 7) {
        MetricLabel(primaryTitle)
        primaryValue
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      ForEach(Array(secondaryValues.enumerated()), id: \.offset) { _, metric in
        MetricValue(title: metric.title, value: metric.value)
      }
    }
  }

  private var primaryTitle: String {
    if summary.status != .available { return summary.displayName }
    if usesTokensAsPrimary { return displayedUsage?.label ?? "Tokens this month" }
    return "Month to date"
  }

  @ViewBuilder
  private var primaryValue: some View {
    if summary.status != .available {
      HeroTextAmount(value: providerStatusText)
    } else if usesTokensAsPrimary, let usage = displayedUsage {
      HeroTextAmount(value: tokenText(usage.totalTokens))
    } else {
      HeroCurrencyAmount(micros: total.currentCostMicros, currency: total.currency)
    }
  }

  private var usesTokensAsPrimary: Bool {
    !summary.contributesToTotals && report.tokenUsage != nil
  }

  private var secondaryValues: [Value] {
    var values: [Value] = []

    if summary.status != .available {
      values.append(Value(title: "Status", value: providerStatusText))
      values.append(Value(title: "Account type", value: accountType))
      values.append(Value(title: "Last updated", value: lastUpdatedText))
      return values
    }

    if let projected = total.projectedCostMicros {
      values.append(
        Value(title: "Projected", value: projected.currencyText(code: total.currency))
      )
    }
    if let credit = total.creditRemainingMicros {
      values.append(
        Value(title: "Credit remaining", value: credit.currencyText(code: total.currency))
      )
    }

    values.append(contentsOf: additionalCurrencyValues)
    if !prioritizesSelectedWindow {
      values.append(contentsOf: report.allowanceWindows.map(allowanceValue))
    }

    if let usage = displayedUsage {
      if usesTokensAsPrimary {
        values.append(Value(title: "Input tokens", value: tokenText(usage.inputTokens)))
        values.append(Value(title: "Output tokens", value: tokenText(usage.outputTokens)))
        values.append(Value(title: "Cached tokens", value: tokenText(usage.cacheReadTokens)))
      } else {
        values.append(Value(title: "Total tokens", value: tokenText(usage.totalTokens)))
      }
    }
    if prioritizesSelectedWindow {
      values.append(contentsOf: report.allowanceWindows.map(allowanceValue))
    }

    if !report.resources.isEmpty {
      values.append(Value(title: "Resources", value: resourceCountText))
    }
    if !report.lineItems.isEmpty {
      values.append(Value(title: "Billed services", value: "\(serviceCount)"))
    }
    values.append(Value(title: "Last updated", value: lastUpdatedText))
    values.append(Value(title: "Account type", value: accountType))

    return Array(values.prefix(3))
  }

  private var providerStatusText: String {
    switch summary.status {
    case .available: "Available"
    case .notConfigured: "Not configured"
    case .unavailable: "Unavailable"
    }
  }

  private var displayedUsage: DisplayedUsage? {
    if selectedTokenWindowID != "month",
       let window = report.tokenUsageWindows.first(where: { $0.id == selectedTokenWindowID }) {
      return DisplayedUsage(
        label: "Tokens · (window.label)",
        inputTokens: window.inputTokens,
        outputTokens: window.outputTokens,
        cacheReadTokens: window.cacheReadTokens,
        totalTokens: window.totalTokens
      )
    }
    guard let usage = report.tokenUsage else { return nil }
    return DisplayedUsage(
      label: "Tokens this month",
      inputTokens: usage.inputTokens,
      outputTokens: usage.outputTokens,
      cacheReadTokens: usage.cacheReadTokens,
      totalTokens: usage.totalTokens
    )
  }

  private var prioritizesSelectedWindow: Bool {
    usesTokensAsPrimary && selectedTokenWindowID != "month"
  }

  private var additionalCurrencyValues: [Value] {
    report.financials.compactMap { financial in
      guard financial.currency != total.currency else { return nil }
      return Value(
        title: "Month to date (\(financial.currency))",
        value: financial.currentCostMicros.currencyText(code: financial.currency)
      )
    }
  }

  private func allowanceValue(_ window: Dashboard.AllowanceWindow) -> Value {
    let precision = window.usedPercent.rounded() == window.usedPercent ? 0 : 1
    let percent = window.usedPercent.formatted(
      .number.precision(.fractionLength(precision)).locale(MoneyFormat.locale)
    )
    return Value(title: "\(window.label) usage", value: "\(percent)%")
  }

  private func tokenText(_ tokens: UInt64) -> String {
    tokens.formatted(
      .number
        .notation(.compactName)
        .precision(.fractionLength(0...1))
        .locale(MoneyFormat.locale)
    )
  }

  private var resourceCountText: String {
    let quantity = report.resources.reduce(UInt64(0)) { partial, resource in
      let (sum, overflow) = partial.addingReportingOverflow(resource.quantity)
      return overflow ? .max : sum
    }
    return tokenText(quantity)
  }

  private var serviceCount: Int {
    Set(report.lineItems.map(\.service)).count
  }

  private var accountType: String {
    summary.kind.replacingOccurrences(of: "_", with: " ").capitalized
  }

  private var lastUpdatedText: String {
    guard summary.updatedAtUnix > 0 else { return "Never" }
    return Date(timeIntervalSince1970: TimeInterval(summary.updatedAtUnix)).formatted(
      date: .abbreviated,
      time: .shortened
    )
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

private struct HeroTextAmount: View {
  let value: String

  var body: some View {
    Text(value)
      .font(.system(size: 46, weight: .light))
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
