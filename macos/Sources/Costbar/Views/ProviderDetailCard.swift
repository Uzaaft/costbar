import SwiftUI

/// The detail behind one provider row: how its allowances are tracking against
/// the clock, what it has spent over the recent windows, its 30-day shape, and
/// what the tokens were actually made of. Everything here is already in the
/// snapshot; the row simply has no space for it.
struct ProviderDetailCard: View {
  let report: Dashboard.ProviderReport

  private static let width: CGFloat = 300
  private static let padding: CGFloat = 15

  private var summary: Dashboard.ProviderSummary { report.summary }
  private var accent: Color { ProviderTint.color(for: summary.providerTypeID) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      switch summary.status {
      case .available:
        availableSections
      case .notConfigured:
        section {
          note(
            "Not configured",
            detail: "Add credentials for this account in Settings to start tracking it."
          )
        }
      case .unavailable:
        section {
          note(
            "Last refresh failed",
            detail: summary.errorMessage ?? "The provider did not return usage data.",
            tint: MenuPalette.warning
          )
        }
      }
    }
    .frame(width: Self.width)
    .background(MenuPalette.raised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .stroke(Color.white.opacity(0.11), lineWidth: 1)
    }
    .environment(\.colorScheme, .dark)
  }

  /// Each section is gated on having something to say, so the card never
  /// carries a divider with nothing under it.
  @ViewBuilder
  private var availableSections: some View {
    if !report.allowanceWindows.isEmpty {
      section { allowances }
    }
    let visibleStats = Array(stats.prefix(4))
    if !visibleStats.isEmpty {
      section { statGrid(visibleStats) }
    }
    let points = trend
    if points.contains(where: { $0.value > 0 }) {
      section { trendChart(points) }
    }
    let mix = mixSegments
    if mix.count > 1 {
      section { tokenMix(mix) }
    }
    section { provenance }
  }

  // MARK: - Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 9) {
        ProviderLogo(providerID: summary.providerTypeID, size: 19)
        Text(summary.displayName)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(MenuPalette.textPrimary)
        Spacer(minLength: 8)
        freshness
      }
      Text(subtitle)
        .font(.system(size: 11))
        .foregroundStyle(MenuPalette.textTertiary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(.horizontal, Self.padding)
    .padding(.top, 13)
    .padding(.bottom, 12)
  }

  private var freshness: some View {
    HStack(spacing: 5) {
      Circle()
        .fill(statusColor)
        .frame(width: 5, height: 5)
      if summary.updatedAtUnix > 0 {
        let updated = Date(timeIntervalSince1970: TimeInterval(summary.updatedAtUnix))
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(RelativeAge.text(since: updated, now: context.date))
            .monospacedDigit()
        }
      } else {
        Text("never refreshed")
      }
    }
    .font(.system(size: 10.5))
    .foregroundStyle(MenuPalette.textTertiary)
  }

  private var statusColor: Color {
    switch summary.status {
    case .available: accent
    case .notConfigured: MenuPalette.textTertiary
    case .unavailable: MenuPalette.warning
    }
  }

  private var subtitle: String {
    if let source = report.tokenUsage?.source, !source.isEmpty { return source }
    if summary.status == .available, !report.lineItems.isEmpty {
      let services = Set(report.lineItems.map(\.service)).count
      return "\(services) billed \(services == 1 ? "service" : "services")"
    }
    return summary.kind.replacingOccurrences(of: "_", with: " ").capitalized
  }

  // MARK: - Allowances

  private var allowances: some View {
    TimelineView(.periodic(from: .now, by: 20)) { context in
      VStack(alignment: .leading, spacing: 13) {
        ForEach(report.allowanceWindows) { window in
          AllowanceGauge(window: window, now: context.date, accent: accent)
        }
      }
    }
  }

  // MARK: - Stats

  private func statGrid(_ visible: [Stat]) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 13) {
      ForEach(Array(stride(from: 0, to: visible.count, by: 2)), id: \.self) { start in
        GridRow {
          statTile(visible[start])
          if start + 1 < visible.count {
            statTile(visible[start + 1])
          } else {
            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
          }
        }
      }
    }
  }

  private struct Stat {
    let title: String
    let value: String
    var detail: String?
  }

  private func statTile(_ stat: Stat) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(stat.title)
        .font(.system(size: 9.5, weight: .semibold))
        .tracking(0.8)
        .textCase(.uppercase)
        .foregroundStyle(MenuPalette.textTertiary)
      Text(stat.value)
        .font(.system(size: 17, weight: .regular))
        .monospacedDigit()
        .foregroundStyle(MenuPalette.textPrimary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      if let detail = stat.detail {
        Text(detail)
          .font(.system(size: 10))
          .foregroundStyle(MenuPalette.textTertiary)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var stats: [Stat] {
    tracksTokensOnly ? tokenStats : billedStats
  }

  /// Local sources have no bill, so their tokens are the headline figures.
  private var tracksTokensOnly: Bool {
    !summary.contributesToTotals && report.tokenUsage != nil
  }

  private var tokenStats: [Stat] {
    var stats: [Stat] = []
    if let day = usageWindow("day") {
      stats.append(Stat(title: "Last 24h", value: TokenFormat.compact(day.totalTokens)))
    }
    if let week = usageWindow("week") {
      stats.append(Stat(title: "Last 7 days", value: TokenFormat.compact(week.totalTokens)))
    }
    if let usage = report.tokenUsage {
      stats.append(Stat(title: "This month", value: TokenFormat.compact(usage.totalTokens)))
    }
    if let peak = trend.max(by: { $0.value < $1.value }), peak.value > 0 {
      stats.append(Stat(
        title: "Busiest day",
        value: TokenFormat.compact(UInt64(peak.value)),
        detail: peak.date.formatted(.dateTime.month(.abbreviated).day())
      ))
    }
    return stats
  }

  private var billedStats: [Stat] {
    var stats = [Stat(
      title: "Month to date",
      value: summary.currentCostMicros.currencyText(code: summary.currency)
    )]
    if let projected = summary.projectedCostMicros {
      stats.append(Stat(
        title: "Projected",
        value: projected.currencyText(code: summary.currency),
        detail: "end of month"
      ))
    }
    if let credit = summary.creditRemainingMicros {
      stats.append(Stat(
        title: "Credit left",
        value: credit.currencyText(code: summary.currency)
      ))
    }
    if let usage = report.tokenUsage {
      stats.append(Stat(title: "Tokens", value: TokenFormat.compact(usage.totalTokens)))
    }
    if let top = topLineItem {
      stats.append(Stat(
        title: "Largest service",
        value: top.amountMicros.currencyText(code: top.currency ?? summary.currency),
        detail: top.service
      ))
    }
    let resourceCount = report.resources.filter { $0.kind != "model" }.count
    if resourceCount > 0 {
      stats.append(Stat(title: "Resources", value: "\(resourceCount)"))
    }
    return stats
  }

  private func usageWindow(_ id: String) -> Dashboard.TokenUsageWindow? {
    report.tokenUsageWindows.first { $0.id == id }
  }

  private var topLineItem: Dashboard.CostLineItem? {
    report.lineItems.max { $0.amountMicros < $1.amountMicros }
  }

  // MARK: - Trend

  private struct TrendPoint: Identifiable {
    let date: Date
    let value: Double

    var id: TimeInterval { date.timeIntervalSince1970 }
  }

  private func trendChart(_ points: [TrendPoint]) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        sectionLabel("Last 30 days")
        Spacer(minLength: 6)
        Text("peak \(trendText(points.map(\.value).max() ?? 0))")
          .font(.system(size: 9.5))
          .monospacedDigit()
          .foregroundStyle(MenuPalette.textTertiary)
      }
      Sparkline(values: points.map(\.value), accent: accent)
    }
  }

  /// Daily volume over the trailing month: tokens where that is all the source
  /// reports, money everywhere else.
  private var trend: [TrendPoint] {
    if tracksTokensOnly {
      let series = report.tokenUsageSeries.first { $0.id == "thirty-days" }
        ?? report.tokenUsageSeries.first { $0.id == "month" }
      return series?.buckets.map { bucket in
        TrendPoint(
          date: Date(timeIntervalSince1970: TimeInterval(bucket.period.startUnix)),
          value: Double(bucket.totalTokens)
        )
      } ?? []
    }

    let calendar = Calendar.current
    var byDay: [Date: Int64] = [:]
    for bucket in report.spendSeries.flatMap(\.buckets) {
      let day = calendar.startOfDay(
        for: Date(timeIntervalSince1970: TimeInterval(bucket.period.startUnix))
      )
      byDay[day] = (byDay[day] ?? 0).saturatingAdding(bucket.amountMicros)
    }
    return byDay
      .sorted { $0.key < $1.key }
      .suffix(30)
      .map { TrendPoint(date: $0.key, value: Double($0.value) / 1_000_000) }
  }

  private func trendText(_ value: Double) -> String {
    guard !tracksTokensOnly else { return TokenFormat.compact(UInt64(max(0, value))) }
    return value.formatted(
      .currency(code: summary.currency)
        .precision(.fractionLength(value < 10 ? 2 : 0))
        .locale(MoneyFormat.locale)
    )
  }

  // MARK: - Token mix

  private func tokenMix(_ segments: [MixSegment]) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      sectionLabel("Token mix · this month")
      GeometryReader { proxy in
        HStack(spacing: 0) {
          ForEach(segments) { segment in
            Rectangle()
              .fill(segment.category.color)
              .frame(width: proxy.size.width * segment.fraction)
          }
        }
      }
      .frame(height: 7)
      .clipShape(Capsule())
      MixLegend(segments: segments)
    }
  }

  fileprivate struct MixSegment: Identifiable {
    let category: TokenHistoryCategory
    let fraction: Double

    var id: TokenHistoryCategory { category }
    var percentText: String {
      fraction.formatted(
        .percent.precision(.fractionLength(0)).locale(MoneyFormat.locale)
      )
    }
  }

  private var mixSegments: [MixSegment] {
    guard let usage = report.tokenUsage, usage.totalTokens > 0 else { return [] }
    let total = Double(usage.totalTokens)
    return TokenHistoryCategory.allCases
      .map { MixSegment(category: $0, fraction: Double($0.tokens(in: usage)) / total) }
      .filter { $0.fraction > 0 }
      .sorted { $0.fraction > $1.fraction }
  }

  // MARK: - Provenance

  private var provenance: some View {
    VStack(alignment: .leading, spacing: 4) {
      if !modelNames.isEmpty {
        Text(modelNames.joined(separator: " · "))
          .font(.system(size: 10.5))
          .foregroundStyle(MenuPalette.textSecondary)
          .lineLimit(2)
      }
      Text(provenanceNote)
        .font(.system(size: 10))
        .foregroundStyle(MenuPalette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var modelNames: [String] {
    let names = report.resources.filter { $0.kind == "model" }.map(\.name)
    guard names.count > 3 else { return names }
    return names.prefix(3) + ["+\(names.count - 3) more"]
  }

  private var provenanceNote: String {
    tracksTokensOnly
      ? "Counted from local session logs · not a subscription bill"
      : "Reported by the provider's billing API"
  }

  // MARK: - Chrome

  private func section(@ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Rectangle()
        .fill(MenuPalette.hairline)
        .frame(height: 1)
      content()
        .padding(.horizontal, Self.padding)
        .padding(.vertical, 12)
    }
  }

  private func sectionLabel(_ title: String) -> some View {
    Text(title)
      .font(.system(size: 9.5, weight: .semibold))
      .tracking(0.8)
      .textCase(.uppercase)
      .foregroundStyle(MenuPalette.textTertiary)
  }

  private func note(
    _ title: String,
    detail: String,
    tint: Color = MenuPalette.textSecondary
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(tint)
      Text(detail)
        .font(.system(size: 11))
        .foregroundStyle(MenuPalette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

/// One allowance window: how much is gone, when it comes back, and whether the
/// current rate gets there first.
private struct AllowanceGauge: View {
  let window: Dashboard.AllowanceWindow
  let now: Date
  let accent: Color

  private var fraction: Double { min(max(window.usedPercent, 0), 100) / 100 }
  private var pace: AllowancePace? { AllowancePace(window: window, now: now) }

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 8) {
        Text(window.label)
          .font(.system(size: 10, weight: .semibold))
          .tracking(0.8)
          .textCase(.uppercase)
          .foregroundStyle(MenuPalette.textSecondary)
        Spacer(minLength: 6)
        Text(window.usedPercentText)
          .font(.system(size: 11, weight: .medium))
          .monospacedDigit()
          .foregroundStyle(MenuPalette.textPrimary)
        if let resets = resetText {
          Text(resets)
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(MenuPalette.textTertiary)
        }
      }

      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          Capsule().fill(MenuPalette.track)
          Capsule()
            .fill(barColor)
            .frame(width: max(fraction > 0 ? 2 : 0, proxy.size.width * fraction))
        }
      }
      .frame(height: 5)

      if let outlook = outlookText {
        Text(outlook)
          .font(.system(size: 10.5))
          .foregroundStyle(outlookColor)
          .lineLimit(1)
      }
    }
  }

  private var barColor: Color {
    if window.usedPercent >= 90 { return MenuPalette.warning }
    return pace?.isOverspending == true ? MenuPalette.warning.opacity(0.85) : accent
  }

  private var resetText: String? {
    guard let resetsAtUnix = window.resetsAtUnix else { return window.detail }
    let resetsAt = Date(timeIntervalSince1970: TimeInterval(resetsAtUnix))
    guard resetsAt > now else { return nil }
    return "resets in \(DurationFormat.compact(resetsAt.timeIntervalSince(now)))"
  }

  /// The sentence the card exists for: is this window going to last?
  private var outlookText: String? {
    if window.usedPercent >= 100 { return "Spent · waiting on the reset" }
    guard let pace else { return window.detail }
    let deviation = "\(Int(abs(pace.deviationPoints).rounded()))% "
    switch pace.outlook {
    case let .emptiesAt(date):
      let remaining = DurationFormat.compact(date.timeIntervalSince(now))
      return pace.isOverspending
        ? deviation + "ahead of pace · empty in \(remaining)"
        : "Empty in \(remaining) at this rate"
    case .lastsUntilReset:
      if pace.isUnderspending { return deviation + "in reserve · lasts to the reset" }
      if pace.isOverspending { return deviation + "ahead of pace · still lasts to the reset" }
      return "On pace · lasts to the reset"
    }
  }

  private var outlookColor: Color {
    pace?.isOverspending == true || window.usedPercent >= 100
      ? MenuPalette.warning
      : MenuPalette.textSecondary
  }
}

/// A row of thin daily bars, most recent on the right.
private struct Sparkline: View {
  let values: [Double]
  let accent: Color

  var body: some View {
    let peak = values.max() ?? 0
    HStack(alignment: .bottom, spacing: 2) {
      ForEach(Array(values.enumerated()), id: \.offset) { index, value in
        RoundedRectangle(cornerRadius: 1, style: .continuous)
          .fill(index == values.count - 1 ? accent : accent.opacity(0.42))
          .frame(height: height(value, peak: peak))
      }
    }
    .frame(height: 34, alignment: .bottom)
  }

  private func height(_ value: Double, peak: Double) -> CGFloat {
    guard peak > 0 else { return 1 }
    return max(1, 34 * CGFloat(value / peak))
  }
}

/// The mix legend, wrapped so a fifth token class does not push the card wide.
private struct MixLegend: View {
  let segments: [ProviderDetailCard.MixSegment]

  var body: some View {
    ViewThatFits(in: .horizontal) {
      row(segments)
      VStack(alignment: .leading, spacing: 4) {
        row(Array(segments.prefix(2)))
        row(Array(segments.dropFirst(2)))
      }
    }
  }

  private func row(_ items: [ProviderDetailCard.MixSegment]) -> some View {
    HStack(spacing: 10) {
      ForEach(items) { segment in
        HStack(spacing: 4) {
          Circle()
            .fill(segment.category.color)
            .frame(width: 5, height: 5)
          Text("\(segment.category.title) \(segment.percentText)")
            .font(.system(size: 10))
            .foregroundStyle(MenuPalette.textTertiary)
            .fixedSize()
        }
      }
      Spacer(minLength: 0)
    }
  }
}
