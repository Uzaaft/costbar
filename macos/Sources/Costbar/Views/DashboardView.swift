import AppKit
import SwiftUI

struct DashboardView: View {
  @ObservedObject var store: DashboardStore
  @Environment(\.openWindow) private var openWindow
  @State private var showsBreakdown = false

  var body: some View {
    VStack(spacing: 0) {
      content
      if let dashboard = store.dashboard, dashboard.hasBreakdown {
        hairline
        breakdownToggle
        if showsBreakdown {
          BreakdownList(dashboard: dashboard)
        }
      }
      hairline
      footer
    }
    .frame(width: 340)
    .background(Palette.background)
    .environment(\.colorScheme, .dark)
  }

  @ViewBuilder
  private var content: some View {
    if let dashboard = store.dashboard {
      VStack(alignment: .leading, spacing: 0) {
        if let total = dashboard.primaryTotal {
          header(total: total)
            .padding(.horizontal, 16)
            .padding(.top, 14)
        } else {
          Text("Subscription usage")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Palette.textPrimary)
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }

        if let error = store.errorMessage {
          errorBanner(error)
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }

        providerList(dashboard: dashboard, total: dashboard.primaryTotal)
          .padding(.horizontal, 8)
          .padding(.top, 14)
          .padding(.bottom, 8)
      }
    } else if let error = store.errorMessage {
      ContentUnavailableView(
        "Unable to load costs",
        systemImage: "exclamationmark.triangle",
        description: Text(error)
      )
      .frame(minHeight: 220)
    } else {
      ProgressView("Loading costs…")
        .controlSize(.small)
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, minHeight: 220)
    }
  }

  private func header(total: Dashboard.CurrencyTotal) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Text("Month to date")
          .font(.system(size: 11, weight: .semibold))
          .tracking(0.9)
          .textCase(.uppercase)
          .foregroundStyle(Palette.textSecondary)
        Spacer(minLength: 8)
        statusBadge
      }

      heroAmount(total: total)
        .padding(.top, 2)

      if let credit = total.creditRemainingMicros {
        HStack(spacing: 6) {
          Image(systemName: "creditcard")
            .font(.system(size: 11))
          Text("\(credit.currencyText(code: total.currency)) prepaid credit left")
            .font(.system(size: 12))
        }
        .foregroundStyle(Palette.textSecondary)
      }

      if let projected = total.projectedCostMicros {
        Text("projected \(projected.currencyText(code: total.currency))  ·  end of month")
          .font(.system(size: 12))
          .foregroundStyle(Palette.textTertiary)
      }
    }
  }

  private func heroAmount(total: Dashboard.CurrencyTotal) -> some View {
    let parts = CurrencyDisplay(micros: total.currentCostMicros, code: total.currency)
    return HStack(alignment: .firstTextBaseline, spacing: 1) {
      Text(parts.symbol)
        .font(.system(size: 22, weight: .light))
        .foregroundStyle(Palette.textSecondary)
      Text(parts.whole)
        .font(.system(size: 44, weight: .light))
        .monospacedDigit()
        .foregroundStyle(Palette.textPrimary)
      Text(parts.fraction)
        .font(.system(size: 26, weight: .light))
        .monospacedDigit()
        .foregroundStyle(Palette.textPrimary.opacity(0.62))
    }
    .lineLimit(1)
    .minimumScaleFactor(0.6)
  }

  private var statusBadge: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(statusColor)
        .frame(width: 6, height: 6)
      TimelineView(.periodic(from: .now, by: 1)) { context in
        Text(statusText(now: context.date))
          .font(.system(size: 11.5))
          .monospacedDigit()
          .foregroundStyle(Palette.textSecondary)
      }
    }
  }

  private var statusColor: Color {
    switch store.dataSourceLabel {
    case "live": Palette.live
    case "stale": .orange
    default: Palette.textTertiary
    }
  }

  private func statusText(now: Date) -> String {
    guard let updated = store.lastUpdatedAt else { return store.dataSourceLabel }
    return "\(store.dataSourceLabel) · \(Self.ageText(since: updated, now: now))"
  }

  private static func ageText(since date: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s ago" }
    if seconds < 3600 { return "\(seconds / 60)m ago" }
    return "\(seconds / 3600)h ago"
  }

  private func errorBanner(_ message: String) -> some View {
    HStack(alignment: .top, spacing: 6) {
      Image(systemName: "exclamationmark.triangle.fill")
        .font(.system(size: 10))
      Text(message)
        .font(.system(size: 11))
        .lineLimit(3)
    }
    .foregroundStyle(.orange)
  }

  private func providerList(
    dashboard: Dashboard,
    total: Dashboard.CurrencyTotal?
  ) -> some View {
    VStack(spacing: 1) {
      ForEach(dashboard.providers) { report in
        ProviderRow(
          report: report,
          aggregateCostMicros: total?.currentCostMicros ?? 0
        )
      }
    }
  }

  private var breakdownToggle: some View {
    Button {
      withAnimation(.easeOut(duration: 0.12)) { showsBreakdown.toggle() }
    } label: {
      HStack(spacing: 8) {
        Text(showsBreakdown ? "Hide breakdown" : "Open breakdown")
          .font(.system(size: 13))
        Spacer(minLength: 0)
        Text("⌘B")
          .font(.system(size: 11.5, design: .monospaced))
          .foregroundStyle(Palette.textTertiary)
        Image(systemName: showsBreakdown ? "chart.bar.xaxis" : "chart.bar")
          .font(.system(size: 13))
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .keyboardShortcut("b", modifiers: .command)
    .hoverHighlight()
    .foregroundStyle(Palette.textPrimary.opacity(0.85))
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
  }

  private var footer: some View {
    HStack(spacing: 2) {
      Button {
        store.refresh()
      } label: {
        HStack(spacing: 7) {
          if store.isRefreshing {
            ProgressView()
              .controlSize(.small)
              .scaleEffect(0.55)
              .frame(width: 11, height: 11)
          }
          Text(store.isRefreshing ? "Refreshing…" : "Refresh")
            .font(.system(size: 13))
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .keyboardShortcut("r", modifiers: .command)
      .disabled(store.isRefreshing)
      .hoverHighlight()

      Button {
        openWindow(id: "dashboard")
        NSApplication.shared.activate(ignoringOtherApps: true)
      } label: {
        iconLabel("macwindow")
      }
      .buttonStyle(.plain)
      .hoverHighlight(cornerRadius: 6)
      .help("Open dashboard")

      SettingsLink {
        iconLabel("gearshape")
      }
      .buttonStyle(.plain)
      .hoverHighlight(cornerRadius: 6)
      .help("Provider settings")

      Button {
        NSApplication.shared.terminate(nil)
      } label: {
        iconLabel("power")
      }
      .buttonStyle(.plain)
      .hoverHighlight(cornerRadius: 6)
      .help("Quit Costbar")
    }
    .foregroundStyle(Palette.textPrimary.opacity(0.85))
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
  }

  private func iconLabel(_ systemName: String) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 13))
      .frame(width: 26, height: 26)
      .contentShape(Rectangle())
  }

  private var hairline: some View {
    Rectangle()
      .fill(Palette.hairline)
      .frame(height: 1)
  }
}

private struct ProviderRow: View {
  let report: Dashboard.ProviderReport
  let aggregateCostMicros: Int64

  private var summary: Dashboard.ProviderSummary { report.summary }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .center, spacing: 11) {
        ProviderLogo(providerID: summary.providerTypeID)

        VStack(alignment: .leading, spacing: 1) {
          Text(summary.displayName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Palette.textPrimary)
          Text(subtitle)
            .font(.system(size: 11.5))
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }

        Spacer(minLength: 10)

        VStack(alignment: .trailing, spacing: 1) {
          switch summary.status {
          case .available:
            Text(providerAmount)
              .font(.system(size: 13, weight: .medium, design: .monospaced))
              .foregroundStyle(Palette.textPrimary)
            Text(summary.contributesToTotals ? percentageText : "local usage")
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(Palette.textTertiary)
          case .notConfigured:
            Image(systemName: "gearshape")
              .font(.system(size: 12))
              .foregroundStyle(Palette.textTertiary)
          case .unavailable:
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 12))
              .foregroundStyle(.orange)
          }
        }
      }

      if summary.status == .available {
        ForEach(report.allowanceWindows.prefix(3)) { window in
          allowanceRow(window)
        }
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .contentShape(Rectangle())
    .hoverHighlight()
  }

  private func allowanceRow(_ window: Dashboard.AllowanceWindow) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 8) {
        Text(window.label)
          .lineLimit(1)
        Spacer(minLength: 8)
        Text(allowanceDetail(window))
          .monospacedDigit()
      }
      .font(.system(size: 10.5))
      .foregroundStyle(Palette.textTertiary)

      ProgressView(value: min(max(window.usedPercent, 0), 100), total: 100)
        .progressViewStyle(.linear)
        .tint(window.usedPercent >= 90 ? .orange : accentColor)
        .controlSize(.mini)
    }
    .padding(.leading, 20)
  }

  private func allowanceDetail(_ window: Dashboard.AllowanceWindow) -> String {
    guard let reset = window.resetsAtUnix else { return window.usedPercentText }
    let time = Date(timeIntervalSince1970: TimeInterval(reset)).formatted(
      date: .omitted,
      time: .shortened
    )
    return "\(window.usedPercentText) · \(time)"
  }

  private var accentColor: Color {
    ProviderTint.color(for: summary.id)
  }

  private var percentageText: String {
    guard aggregateCostMicros > 0 else { return "0%" }
    let percentage = Double(summary.currentCostMicros) / Double(aggregateCostMicros)
    return percentage.formatted(
      .percent
        .precision(.fractionLength(0))
        .locale(MoneyFormat.locale)
    )
  }

  private var providerAmount: String {
    if !summary.contributesToTotals, let tokens = report.tokenUsage {
      return tokens.totalTokens.formatted(
        .number.notation(.compactName).precision(.fractionLength(0...1))
      ) + " tok"
    }
    if report.financials.count > 1 {
      return summary.currentCostMicros.currencyText(code: summary.currency)
    }
    return summary.currentCostMicros.decimalText()
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
      let tokens = usage.totalTokens.formatted(.number.notation(.compactName))
      return "\(tokens) tokens · \(usage.source)"
    }
    return "No active resources"
  }
}

/// The line items behind the headline number, grouped by billed product.
private struct BreakdownList: View {
  let dashboard: Dashboard

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        ForEach(dashboard.providers.filter { !$0.lineItems.isEmpty }) { report in
          providerBreakdown(report)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
    }
    .frame(maxHeight: 260)
    .background(Color.black.opacity(0.16))
  }

  @ViewBuilder
  private func providerBreakdown(_ report: Dashboard.ProviderReport) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        ProviderLogo(providerID: report.summary.providerTypeID, size: 14)
        Text(report.summary.displayName)
          .font(.system(size: 11, weight: .semibold))
          .tracking(0.8)
          .textCase(.uppercase)
        Spacer(minLength: 8)
        Text(report.summary.currentCostMicros.currencyText(code: report.summary.currency))
          .font(.system(size: 11, weight: .semibold, design: .monospaced))
      }
      .foregroundStyle(Palette.textSecondary)
      .padding(.bottom, 2)

      ForEach(groups(of: report)) { group in
        if group.items.count > 1 {
          row(
            label: group.id,
            detail: "\(group.items.count) items",
            amountMicros: group.amountMicros,
            currency: group.currency,
            emphasized: true
          )
          ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
            row(
              label: item.description,
              detail: item.detail,
              amountMicros: item.amountMicros,
              currency: item.currency,
              indent: 12
            )
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
  }

  private func row(
    label: String,
    detail: String?,
    amountMicros: Int64,
    currency: String? = nil,
    emphasized: Bool = false,
    indent: CGFloat = 0
  ) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      VStack(alignment: .leading, spacing: 1) {
        Text(label)
          .font(.system(size: 12, weight: emphasized ? .medium : .regular))
          .foregroundStyle(Palette.textPrimary.opacity(emphasized ? 1 : 0.82))
        if let detail {
          Text(detail)
            .font(.system(size: 10.5))
            .foregroundStyle(Palette.textTertiary)
        }
      }
      .lineLimit(1)
      .truncationMode(.tail)

      Spacer(minLength: 8)

      Text(currency.map { amountMicros.currencyText(code: $0) } ?? amountMicros.decimalText())
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(emphasized ? Palette.textPrimary : Palette.textSecondary)
    }
    .padding(.leading, indent)
  }

  private struct Group: Identifiable {
    /// The billed product, which is also the group heading.
    let id: String
    let items: [Dashboard.CostLineItem]

    var amountMicros: Int64 { items.reduce(0) { $0 + $1.amountMicros } }
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
  fileprivate var hasBreakdown: Bool {
    providers.contains { !$0.lineItems.isEmpty }
  }
}

private enum Palette {
  static let background = Color(red: 0.106, green: 0.106, blue: 0.118)
  static let textPrimary = Color.white
  static let textSecondary = Color.white.opacity(0.58)
  static let textTertiary = Color.white.opacity(0.38)
  static let hairline = Color.white.opacity(0.08)
  static let hover = Color.white.opacity(0.08)
  static let live = Color(red: 0.16, green: 0.55, blue: 1.0)
}

private struct HoverHighlight: ViewModifier {
  let cornerRadius: CGFloat
  @State private var isHovering = false

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(isHovering ? Palette.hover : .clear)
      )
      .onHover { isHovering = $0 }
  }
}

extension View {
  fileprivate func hoverHighlight(cornerRadius: CGFloat = 8) -> some View {
    modifier(HoverHighlight(cornerRadius: cornerRadius))
  }
}
