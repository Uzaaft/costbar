import AppKit
import SwiftUI

/// The menu bar popover: the month's total, then every account grouped by what
/// it answers — how much quota is left, and where the money went.
struct DashboardView: View {
  @ObservedObject var store: DashboardStore
  @ObservedObject var menuBar: MenuBarSettingsStore
  @Environment(\.openWindow) private var openWindow
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var showsLineItems = false

  var body: some View {
    VStack(spacing: 0) {
      header
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
      content
      Divider()
      footer
    }
    .frame(width: 320)
  }

  // MARK: - Header

  private var header: some View {
    HStack(alignment: .top, spacing: 8) {
      VStack(alignment: .leading, spacing: 2) {
        if let total = store.dashboard?.primaryTotal {
          Text("Month to Date")
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
          Text(total.currentCostMicros.currencyText(code: total.currency))
            .font(.largeTitle.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            // Digits roll to a new total instead of snapping, so a refresh
            // that moved the number is noticed and one that did not is silent.
            .contentTransition(.numericText(value: Double(total.currentCostMicros)))
            .animation(reduceMotion ? nil : .snappy(duration: 0.35), value: total.currentCostMicros)
          if let projected = total.projectedCostMicros {
            Text("Projected \(projected.currencyText(code: total.currency)) by month end")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          if let credit = total.creditRemainingMicros {
            Text("\(credit.currencyText(code: total.currency)) prepaid credit left")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
        } else {
          Text("Costbar")
            .font(.headline)
        }
        status
          .padding(.top, 2)
      }

      Spacer(minLength: 8)

      HStack(spacing: 6) {
        Button {
          store.refresh()
        } label: {
          Label("Refresh", systemImage: "arrow.clockwise")
            .refreshSpin(isActive: store.isRefreshing)
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(store.isRefreshing)
        .help("Refresh (⌘R)")

        moreMenu
      }
      .labelStyle(.iconOnly)
      .headerButtonStyle()
    }
  }

  /// When the figures were fetched, and a warning when they are not current.
  @ViewBuilder
  private var status: some View {
    HStack(spacing: 4) {
      if store.dataSource == .stale || store.dataSource == .unavailable {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
      }
      if let updated = store.lastUpdatedAt {
        Text(store.dataSource.statusPrefix)
        RelativeAgeText(date: updated)
      } else {
        Text(store.dataSource.label)
      }
    }
    .font(.subheadline)
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
  }

  private var moreMenu: some View {
    Menu {
      Picker("Show in Menu Bar", selection: $menuBar.metric) {
        ForEach(MenuBarMetric.allCases) { metric in
          Text(metric.label).tag(metric)
        }
      }
      .pickerStyle(.menu)

      if store.dashboard?.hasLineItems == true {
        Toggle("Show Line Items", isOn: lineItemsBinding)
          .keyboardShortcut("b", modifiers: .command)
      }

      Divider()

      SettingsLink {
        Text("Settings…")
      }
      .keyboardShortcut(",", modifiers: .command)

      Divider()

      Button("Quit Costbar") {
        NSApp.terminate(nil)
      }
      .keyboardShortcut("q", modifiers: .command)
    } label: {
      Label("More", systemImage: "ellipsis")
    }
    .menuStyle(.button)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("More")
  }

  private var lineItemsBinding: Binding<Bool> {
    Binding(
      get: { showsLineItems },
      set: { shows in
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.25)) { showsLineItems = shows }
      }
    )
  }

  // MARK: - Content

  @ViewBuilder
  private var content: some View {
    if let dashboard = store.dashboard {
      let accounts = dashboard.providers.filter { $0.summary.status != .notConfigured }
      if accounts.isEmpty {
        ContentUnavailableView {
          Label("No Accounts", systemImage: "tray")
        } description: {
          Text("Add a provider or turn on a local source to start tracking.")
        } actions: {
          SettingsLink {
            Text("Open Settings…")
          }
        }
        .frame(minHeight: 220)
      } else {
        // A scroll view takes every point it is offered, which would pad a
        // short list out to the full height. Only scroll once it overflows.
        ViewThatFits(in: .vertical) {
          sections(accounts: accounts, dashboard: dashboard)
          ScrollView {
            sections(accounts: accounts, dashboard: dashboard)
          }
        }
        .frame(maxHeight: listMaxHeight, alignment: .top)
      }
    } else if let error = store.errorMessage {
      ContentUnavailableView(
        "Unable to Load Costs",
        systemImage: "exclamationmark.triangle",
        description: Text(error)
      )
      .frame(minHeight: 220)
    } else {
      ProgressView("Loading costs…")
        .controlSize(.small)
        .frame(maxWidth: .infinity, minHeight: 220)
    }
  }

  private func sections(accounts: [Dashboard.ProviderReport], dashboard: Dashboard) -> some View {
    let subscriptions = accounts.filter { !$0.summary.contributesToTotals }
    let billed = accounts.filter(\.summary.contributesToTotals)
    return VStack(alignment: .leading, spacing: 14) {
      if let error = store.errorMessage {
        errorBanner(error)
      }
      if !subscriptions.isEmpty {
        MenuSection("Coding Agents", items: subscriptions) { report in
          SubscriptionRow(report: report)
        }
      }
      if !billed.isEmpty {
        MenuSection("Spend", items: billed) { report in
          SpendRow(
            report: report,
            aggregateCostMicros: dashboard.primaryTotal?.currentCostMicros ?? 0
          )
        }
      }
      if showsLineItems, dashboard.hasLineItems {
        MenuSection("Line Items", items: accounts.filter { !$0.lineItems.isEmpty }) { report in
          LineItemGroup(report: report)
        }
        .transition(.opacity)
      }
    }
    .padding(.horizontal, 12)
    .padding(.bottom, 12)
  }

  private func errorBanner(_ message: String) -> some View {
    Label {
      Text(message)
        .lineLimit(3)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    }
    .font(.subheadline)
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .platter()
    .help(message)
  }

  private var listMaxHeight: CGFloat {
    let screen = NSScreen.main?.visibleFrame.height ?? 800
    return min(520, max(280, screen * 0.6))
  }

  // MARK: - Footer

  private var footer: some View {
    Button {
      openWindow(id: "dashboard")
      NSApp.activate()
    } label: {
      Text("Open Breakdown Window")
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .hoverHighlight(cornerRadius: 6)
    .padding(6)
  }
}

extension DashboardDataSource {
  /// Leads the "… 3 min. ago" status line.
  fileprivate var statusPrefix: String {
    switch self {
    case .live: "Updated"
    case .cached: "Cached"
    case .stale: "Out of date · updated"
    case .notConfigured, .unavailable: "Last updated"
    }
  }
}

/// A titled group of rows on one platter, separated by inset dividers.
private struct MenuSection<Item: Identifiable, Row: View>: View {
  let title: String
  let items: [Item]
  @ViewBuilder let row: (Item) -> Row

  init(_ title: String, items: [Item], @ViewBuilder row: @escaping (Item) -> Row) {
    self.title = title
    self.items = items
    self.row = row
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 10)
        .accessibilityAddTraits(.isHeader)
      VStack(spacing: 0) {
        ForEach(items) { item in
          row(item)
          if item.id != items.last?.id {
            Divider()
              .padding(.leading, 10)
          }
        }
      }
      .platter()
    }
  }
}

/// The logo, name and one line of context that start every account row.
private struct AccountLabel<Trailing: View>: View {
  let summary: Dashboard.ProviderSummary
  let subtitle: String?
  @ViewBuilder let trailing: Trailing

  var body: some View {
    HStack(spacing: 10) {
      ProviderLogo(providerID: summary.providerTypeID, size: 20)
      VStack(alignment: .leading, spacing: 1) {
        Text(summary.displayName)
          .lineLimit(1)
        if let subtitle {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      trailing
    }
  }
}

/// What an account shows in place of its figures when it has none.
private struct AccountStatusSymbol: View {
  let status: Dashboard.ProviderSummary.Status

  var body: some View {
    switch status {
    case .available:
      EmptyView()
    case .notConfigured:
      Image(systemName: "gearshape")
        .foregroundStyle(.secondary)
        .accessibilityLabel("Not configured")
    case .unavailable:
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityLabel("Unavailable")
    }
  }
}

/// A coding agent or local source: nothing is billed, so the row is about how
/// much of each allowance is gone and when it comes back.
private struct SubscriptionRow: View {
  let report: Dashboard.ProviderReport

  private var summary: Dashboard.ProviderSummary { report.summary }

  /// Headline first, then the other most-used window. The hover card has the
  /// rest; listing every window here is what overflowed the popover.
  private var visibleAllowances: [Dashboard.AllowanceWindow] {
    guard summary.status == .available else { return [] }
    if let headline = report.headlineWindow {
      let extra = report.allowanceWindows
        .filter { $0.id != headline.id }
        .max(by: { $0.usedPercent < $1.usedPercent })
      return extra.map { [headline, $0] } ?? [headline]
    }
    return Array(
      report.allowanceWindows.sorted { $0.usedPercent > $1.usedPercent }.prefix(2)
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      AccountLabel(summary: summary, subtitle: subtitle) {
        if summary.status == .available, let tokens = report.tokenUsage {
          Text(TokenFormat.withUnit(tokens.totalTokens))
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        } else {
          AccountStatusSymbol(status: summary.status)
        }
      }

      if !visibleAllowances.isEmpty {
        TimelineView(.periodic(from: .now, by: 30)) { context in
          VStack(alignment: .leading, spacing: 8) {
            ForEach(visibleAllowances) { window in
              AllowanceMeter(window: window, now: context.date)
            }
          }
        }
      }
    }
    .padding(10)
    .contentShape(Rectangle())
    .hoverCard {
      ProviderDetailCard(report: report)
    }
    .accessibilityElement(children: .combine)
  }

  private var subtitle: String? {
    switch summary.status {
    case .notConfigured: "Not configured"
    case .unavailable: summary.errorMessage ?? "Unavailable"
    case .available: report.allowanceWindows.isEmpty ? report.tokenUsage?.source : nil
    }
  }
}

/// One allowance window: its name, how much is used, when it resets.
private struct AllowanceMeter: View {
  let window: Dashboard.AllowanceWindow
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(window.label)
          .lineLimit(1)
        Spacer(minLength: 8)
        if let reset = resetText {
          Text(reset)
            .foregroundStyle(.secondary)
        }
        Text(window.usedPercentText)
          .fontWeight(.medium)
          .monospacedDigit()
          .contentTransition(.numericText(value: window.usedPercent))
      }
      .font(.subheadline)

      UsageBar(fraction: window.usedPercent / 100, tint: window.statusTint)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(window.label)
    .accessibilityValue([window.usedPercentText + " used", resetText].compactMap(\.self).joined(separator: ", "))
  }

  /// "resets in 1h 59m". A clock time alone cannot tell this afternoon from
  /// three days away, which is the difference that matters.
  private var resetText: String? {
    guard let reset = window.resetsAtUnix else { return nil }
    let remaining = Date(timeIntervalSince1970: TimeInterval(reset)).timeIntervalSince(now)
    guard remaining > 0 else { return nil }
    return "resets in \(DurationFormat.compact(remaining))"
  }
}

/// A billed account: what it has cost this month and its share of the total.
private struct SpendRow: View {
  let report: Dashboard.ProviderReport
  let aggregateCostMicros: Int64

  private var summary: Dashboard.ProviderSummary { report.summary }

  var body: some View {
    AccountLabel(summary: summary, subtitle: subtitle) {
      if summary.status == .available {
        VStack(alignment: .trailing, spacing: 1) {
          Text(summary.currentCostMicros.currencyText(code: summary.currency))
            .contentTransition(.numericText(value: Double(summary.currentCostMicros)))
          Text(shareText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .animation(.snappy(duration: 0.35), value: summary.currentCostMicros)
      } else {
        AccountStatusSymbol(status: summary.status)
      }
    }
    .padding(10)
    .contentShape(Rectangle())
    .hoverCard {
      ProviderDetailCard(report: report)
    }
    .accessibilityElement(children: .combine)
  }

  private var shareText: String {
    guard aggregateCostMicros > 0 else { return "0%" }
    let share = Double(summary.currentCostMicros) / Double(aggregateCostMicros)
    return share.formatted(
      .percent
        .precision(.fractionLength(0))
        .locale(MoneyFormat.locale)
    )
  }

  private var subtitle: String {
    switch summary.status {
    case .notConfigured:
      return "Not configured"
    case .unavailable:
      return summary.errorMessage ?? "Unavailable"
    case .available:
      break
    }
    // What the provider actually bills for, when it says: "2 Droplets · 1 App".
    let products = report.resources.filter { $0.kind == "product" }
    if !products.isEmpty {
      return
        products
        .prefix(3)
        .map { "\($0.quantity) \($0.name)" }
        .joined(separator: " · ")
    }
    if summary.providerTypeID == "digitalocean" {
      let droplets = report.resources.filter { $0.kind == "droplet" }
      let activeDroplets = droplets.filter { $0.status == "active" }
      if activeDroplets.count != droplets.count {
        return "\(activeDroplets.count) active · \(droplets.count) total"
      }
      return "\(droplets.count) \(droplets.count == 1 ? "droplet" : "droplets")"
    }
    if !report.resources.isEmpty {
      return report.resources.prefix(3).map(\.name).joined(separator: " · ")
    }
    if summary.providerTypeID == "vercel", !report.lineItems.isEmpty {
      let count = report.lineItems.count
      return "\(count) billed \(count == 1 ? "service" : "services")"
    }
    if let credit = summary.creditRemainingMicros {
      return "\(credit.currencyText(code: summary.currency)) credit left"
    }
    if let usage = report.tokenUsage {
      return "\(TokenFormat.withUnit(usage.totalTokens)) · \(usage.source)"
    }
    return "No active resources"
  }
}

/// One account's line items behind the headline number, grouped by billed
/// product.
private struct LineItemGroup: View {
  let report: Dashboard.ProviderReport

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        ProviderLogo(providerID: report.summary.providerTypeID, size: 14)
        Text(report.summary.displayName)
          .fontWeight(.medium)
        Spacer(minLength: 8)
      }
      ForEach(groups(of: report)) { group in
        if group.items.count > 1 {
          row(
            label: group.id,
            detail: "\(group.items.count) items",
            amountMicros: group.amountMicros,
            currency: group.currency,
            emphasized: true
          )
          ForEach(group.items) { item in
            row(
              label: item.description,
              detail: item.detail,
              amountMicros: item.amountMicros,
              currency: item.currency
            )
            .padding(.leading, 12)
          }
        } else if let item = group.items.first {
          row(
            label: item.description,
            detail: item.detail ?? group.id,
            amountMicros: item.amountMicros,
            currency: item.currency
          )
        }
      }
    }
    .padding(10)
  }

  private func row(
    label: String,
    detail: String?,
    amountMicros: Int64,
    currency: String?,
    emphasized: Bool = false
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text(label)
          .fontWeight(emphasized ? .medium : .regular)
        if let detail {
          Text(detail)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
      .lineLimit(1)

      Spacer(minLength: 8)

      Text(currency.map { amountMicros.currencyText(code: $0) } ?? amountMicros.decimalText())
        .monospacedDigit()
        .foregroundStyle(emphasized ? .primary : .secondary)
    }
    .font(.subheadline)
  }

  private struct Group: Identifiable {
    /// The billed product, which is also the group heading.
    let id: String
    let items: [Dashboard.CostLineItem]

    var amountMicros: Int64 { items.map(\.amountMicros).saturatingSum }
    var currency: String? {
      let currencies = Set(items.compactMap(\.currency))
      return currencies.count == 1 ? currencies.first : nil
    }
  }

  private func groups(of report: Dashboard.ProviderReport) -> [Group] {
    Dictionary(grouping: report.lineItems, by: \.service)
      .map { Group(id: $0.key, items: $0.value) }
      .sorted { $0.amountMicros > $1.amountMicros }
  }
}

extension Dashboard {
  fileprivate var hasLineItems: Bool {
    providers.contains { !$0.lineItems.isEmpty }
  }
}
