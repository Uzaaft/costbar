import SwiftUI

/// The headline figures at the top of the breakdown: one hero amount plus up to
/// three supporting metrics.
struct BreakdownMetrics: View {
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
    MetricRow {
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
  /// The row fits three metrics beside the hero amount.
  private static let secondaryMetricCount = 3

  private struct Metric {
    let title: String
    let value: String
  }

  /// The token counts backing the primary and secondary figures, either for the
  /// selected rolling window or for the month.
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
    MetricRow {
      VStack(alignment: .leading, spacing: 7) {
        MetricLabel(primaryTitle)
        primaryValue
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      ForEach(Array(secondaryMetrics.enumerated()), id: \.offset) { _, metric in
        MetricValue(title: metric.title, value: metric.value)
      }
    }
  }

  private var primaryTitle: String {
    if summary.status != .available { return summary.displayName }
    if usesTokensAsPrimary { return displayedUsage?.label ?? "Tokens this month" }
    if let window = selectedRollingSpendWindow { return window.label }
    return "Month to date"
  }

  @ViewBuilder
  private var primaryValue: some View {
    if summary.status != .available {
      HeroTextAmount(value: providerStatusText)
    } else if usesTokensAsPrimary, let usage = displayedUsage {
      HeroTextAmount(value: TokenFormat.compact(usage.totalTokens))
    } else if let spend = selectedRollingSpendMicros {
      HeroCurrencyAmount(micros: spend, currency: total.currency)
    } else {
      HeroCurrencyAmount(micros: total.currentCostMicros, currency: total.currency)
    }
  }

  /// Local sources have no bill, so their tokens are the headline figure.
  private var usesTokensAsPrimary: Bool {
    !summary.contributesToTotals && report.tokenUsage != nil
  }

  private var secondaryMetrics: [Metric] {
    guard summary.status == .available else {
      return [
        Metric(title: "Status", value: providerStatusText),
        Metric(title: "Account type", value: accountType),
        Metric(title: "Last updated", value: lastUpdatedText),
      ]
    }

    var metrics: [Metric] = []
    if let projected = total.projectedCostMicros {
      metrics.append(
        Metric(title: "Projected", value: projected.currencyText(code: total.currency))
      )
    }
    if let credit = total.creditRemainingMicros {
      metrics.append(
        Metric(title: "Credit remaining", value: credit.currencyText(code: total.currency))
      )
    }

    metrics.append(contentsOf: additionalCurrencyMetrics)
    // When a rolling window is selected its allowance is the point of the view,
    // so it outranks the token counts.
    if !prioritizesSelectedWindow {
      metrics.append(contentsOf: report.allowanceWindows.map(allowanceMetric))
    }

    if let usage = displayedUsage {
      if usesTokensAsPrimary {
        metrics.append(Metric(
          title: "Input tokens",
          value: TokenFormat.compact(usage.inputTokens)
        ))
        metrics.append(Metric(
          title: "Output tokens",
          value: TokenFormat.compact(usage.outputTokens)
        ))
        metrics.append(Metric(
          title: "Cached tokens",
          value: TokenFormat.compact(usage.cacheReadTokens)
        ))
      } else {
        metrics.append(Metric(
          title: "Total tokens",
          value: TokenFormat.compact(usage.totalTokens)
        ))
      }
    }
    if prioritizesSelectedWindow {
      metrics.append(contentsOf: report.allowanceWindows.map(allowanceMetric))
    }

    if !report.resources.isEmpty {
      metrics.append(Metric(title: "Resources", value: resourceCountText))
    }
    if !report.lineItems.isEmpty {
      metrics.append(Metric(title: "Billed services", value: "\(serviceCount)"))
    }
    metrics.append(Metric(title: "Last updated", value: lastUpdatedText))
    metrics.append(Metric(title: "Account type", value: accountType))

    return Array(metrics.prefix(Self.secondaryMetricCount))
  }

  private var providerStatusText: String {
    switch summary.status {
    case .available: "Available"
    case .notConfigured: "Not configured"
    case .unavailable: "Unavailable"
    }
  }

  private var displayedUsage: DisplayedUsage? {
    if let window = selectedWindow {
      return DisplayedUsage(
        label: "Tokens · \(window.label)",
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

  private var selectedWindow: Dashboard.TokenUsageWindow? {
    guard selectedTokenWindowID != "month" else { return nil }
    return report.tokenUsageWindows.first { $0.id == selectedTokenWindowID }
  }

  private var prioritizesSelectedWindow: Bool {
    usesTokensAsPrimary && selectedTokenWindowID != "month"
  }

  private var selectedRollingSpendWindow: Dashboard.TokenUsageWindow? {
    guard summary.providerTypeID == "openrouter" else { return nil }
    return selectedWindow
  }

  private var selectedRollingSpendMicros: Int64? {
    guard let window = selectedRollingSpendWindow else { return nil }
    return report.spendSeries
      .flatMap(\.buckets)
      .filter { bucket in
        bucket.period.startUnix < window.period.endExclusiveUnix &&
          bucket.period.endExclusiveUnix > window.period.startUnix
      }
      .map(\.amountMicros)
      .saturatingSum
  }

  private var additionalCurrencyMetrics: [Metric] {
    report.financials.compactMap { financial in
      guard financial.currency != total.currency else { return nil }
      return Metric(
        title: "Month to date (\(financial.currency))",
        value: financial.currentCostMicros.currencyText(code: financial.currency)
      )
    }
  }

  private func allowanceMetric(_ window: Dashboard.AllowanceWindow) -> Metric {
    Metric(title: "\(window.label) usage", value: window.usedPercentText)
  }

  private var resourceCountText: String {
    TokenFormat.compact(report.resources.map(\.quantity).saturatingSum)
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

private struct MetricRow<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    HStack(alignment: .bottom, spacing: 34) {
      content
    }
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
