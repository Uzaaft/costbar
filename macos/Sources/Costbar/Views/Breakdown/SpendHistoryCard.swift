import Charts
import SwiftUI

/// Per-model activity for the selected window. OpenRouter reports token volume
/// rather than money, so the same chart plots either measure.
struct SpendHistoryCard: View {
  let report: Dashboard.ProviderReport
  let selectedWindowID: String

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      CardHeader(
        title: "Usage by model",
        subtitle: "\(plotsTokenVolume ? "Token volume" : "Spend by model") · \(rangeLabel)",
        trailing: plotsTokenVolume
          ? TokenFormat.withUnit(totalUsageQuantity)
          : totalMicros.currencyText(code: currency)
      )

      if segments.isEmpty {
        ContentUnavailableView(
          "No OpenRouter usage",
          systemImage: "chart.bar.xaxis",
          description: Text("No model activity was recorded in \(rangeLabel.lowercased()).")
        )
        .frame(maxWidth: .infinity, minHeight: 220)
      } else {
        chart
        modelLegend
      }
    }
    .cardSurface()
  }

  private var chart: some View {
    Chart(segments) { segment in
      BarMark(
        x: .value("Time", segment.date, unit: chartUnit),
        y: .value("Usage", chartValue(segment))
      )
      .foregroundStyle(by: .value("Model", segment.model))
      .cornerRadius(2)
      .accessibilityLabel("\(axisLabel(segment.date)), \(segment.model)")
      .accessibilityValue(accessibilityValue(segment))
    }
    .chartForegroundStyleScale(domain: modelNames, range: modelColors)
    .chartXScale(domain: dateDomain)
    .breakdownChartStyle(
      xMarkCount: 7,
      xLabel: axisLabel,
      yLabel: axisValueLabel
    )
  }

  private var modelLegend: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 16) {
        ForEach(Array(modelNames.enumerated()), id: \.element) { index, model in
          HStack(spacing: 6) {
            Circle()
              .fill(modelColors[index])
              .frame(width: 7, height: 7)
            Text(model)
              .font(.footnote)
              .foregroundStyle(WindowPalette.textTertiary)
              .lineLimit(1)
          }
        }
      }
    }
    .scrollIndicators(.hidden)
  }

  private var currency: String {
    report.spendSeries.first?.currency ?? report.summary.currency
  }

  private var plotsTokenVolume: Bool {
    report.summary.providerTypeID == "openrouter"
  }

  private var modelNames: [String] {
    let activeModels = Set(segments.map(\.model))
    return report.spendSeries.map(\.label).filter(activeModels.contains)
  }

  private var modelColors: [Color] {
    let palette = Self.modelPalette + [ProviderTint.color(for: report.id)]
    return modelNames.indices.map { palette[$0 % palette.count] }
  }

  private static let modelPalette: [Color] = [
    Color(red: 0.98, green: 0.75, blue: 0.29),
    Color(red: 0.98, green: 0.43, blue: 0.33),
    Color(red: 0.57, green: 0.38, blue: 0.95),
    Color(red: 0.27, green: 0.52, blue: 0.95),
    Color(red: 0.25, green: 0.72, blue: 0.56),
    Color(red: 0.93, green: 0.34, blue: 0.56),
    Color(red: 0.28, green: 0.72, blue: 0.83),
  ]

  private var totalMicros: Int64 {
    segments.map(\.amountMicros).saturatingSum
  }

  private var totalUsageQuantity: UInt64 {
    segments.map(\.usageQuantity).saturatingSum
  }

  private var segments: [SpendHistorySegment] {
    let rawSegments = report.spendSeries.flatMap { series in
      series.buckets.compactMap { bucket -> SpendHistorySegment? in
        guard bucket.period.startUnix < selectedPeriod.endExclusiveUnix,
              bucket.period.endExclusiveUnix > selectedPeriod.startUnix else {
          return nil
        }
        if plotsTokenVolume, bucket.usageQuantity == 0 { return nil }
        return SpendHistorySegment(
          model: series.label,
          date: Date(timeIntervalSince1970: TimeInterval(bucket.period.startUnix)),
          amountMicros: bucket.amountMicros,
          usageQuantity: bucket.usageQuantity
        )
      }
    }
    guard selectedWindowID != "day" else {
      return rawSegments.sorted(by: SpendHistorySegment.sortsBefore)
    }

    // Anything wider than a day is bucketed hourly by the core; roll it up so
    // the bars stay readable.
    var dailyTotals: [SpendHistoryGroup: SpendHistorySegment] = [:]
    for segment in rawSegments {
      let day = Calendar.current.startOfDay(for: segment.date)
      let key = SpendHistoryGroup(model: segment.model, date: day)
      dailyTotals[key] = dailyTotals[key]?.adding(segment)
        ?? SpendHistorySegment(
          model: segment.model,
          date: day,
          amountMicros: segment.amountMicros,
          usageQuantity: segment.usageQuantity
        )
    }
    return dailyTotals.values.sorted(by: SpendHistorySegment.sortsBefore)
  }

  private var dateDomain: ClosedRange<Date> {
    let start = selectedPeriod.startUnix
    let end = max(selectedPeriod.endExclusiveUnix, start + 1)
    return Date(timeIntervalSince1970: TimeInterval(start)) ...
      Date(timeIntervalSince1970: TimeInterval(end))
  }

  private var selectedPeriod: Dashboard.Period {
    selectedWindow?.period
      ?? report.spendSeries.first?.period
      ?? report.tokenUsage?.period
      ?? Dashboard.Period(startUnix: 0, endExclusiveUnix: 1)
  }

  private var selectedWindow: Dashboard.TokenUsageWindow? {
    report.tokenUsageWindows.first { $0.id == selectedWindowID }
  }

  private var rangeLabel: String {
    selectedWindow?.label ?? "This month"
  }

  private var chartUnit: Calendar.Component {
    selectedWindowID == "day" ? .hour : .day
  }

  private func axisLabel(_ date: Date) -> String {
    if selectedWindowID == "day" {
      return date.formatted(date: .omitted, time: .shortened)
    }
    return date.formatted(.dateTime.month(.abbreviated).day())
  }

  private func chartValue(_ segment: SpendHistorySegment) -> Double {
    plotsTokenVolume
      ? Double(segment.usageQuantity)
      : Double(segment.amountMicros) / 1_000_000
  }

  private func axisValueLabel(_ value: Double) -> String {
    guard plotsTokenVolume else {
      return value.formatted(
        .currency(code: currency)
          .precision(.fractionLength(0...4))
          .locale(MoneyFormat.locale)
      )
    }
    return TokenFormat.withUnit(UInt64(max(value, 0)))
  }

  private func accessibilityValue(_ segment: SpendHistorySegment) -> String {
    plotsTokenVolume
      ? TokenFormat.withUnit(segment.usageQuantity)
      : segment.amountMicros.currencyText(code: currency)
  }
}

private struct SpendHistorySegment: Identifiable {
  let model: String
  let date: Date
  let amountMicros: Int64
  let usageQuantity: UInt64

  var id: String { "\(model):\(date.timeIntervalSince1970)" }

  func adding(_ other: Self) -> Self {
    Self(
      model: model,
      date: date,
      amountMicros: amountMicros.saturatingAdding(other.amountMicros),
      usageQuantity: usageQuantity.saturatingAdding(other.usageQuantity)
    )
  }

  static func sortsBefore(_ left: Self, _ right: Self) -> Bool {
    if left.date != right.date { return left.date < right.date }
    return left.model < right.model
  }
}

private struct SpendHistoryGroup: Hashable {
  let model: String
  let date: Date
}
