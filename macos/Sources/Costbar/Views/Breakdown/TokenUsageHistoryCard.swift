import Charts
import SwiftUI

/// Locally counted tokens over the selected period, split by token class.
struct TokenUsageHistoryCard: View {
  let report: Dashboard.ProviderReport
  let selectedSeriesID: String

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      CardHeader(
        title: "Token history",
        subtitle: series?.label ?? "Selected period",
        trailing: TokenFormat.compact(totalTokens)
      )

      if let series, series.buckets.contains(where: { $0.totalTokens > 0 }) {
        TokenHistoryChart(series: series)
        tokenLegend
      } else {
        ContentUnavailableView(
          "No token activity",
          systemImage: "chart.bar.xaxis",
          description: Text("No local session tokens were recorded in this period.")
        )
        .frame(maxWidth: .infinity, minHeight: 180)
      }
    }
    .cardSurface()
  }

  private var series: Dashboard.TokenUsageSeries? {
    report.tokenUsageSeries.first { $0.id == selectedSeriesID }
      ?? report.tokenUsageSeries.first { $0.id == "month" }
      ?? report.tokenUsageSeries.first
  }

  private var totalTokens: UInt64 {
    series?.buckets.map(\.totalTokens).saturatingSum ?? 0
  }

  private var tokenLegend: some View {
    HStack(spacing: 16) {
      ForEach(TokenHistoryCategory.allCases) { category in
        HStack(spacing: 6) {
          Circle()
            .fill(category.color)
            .frame(width: 7, height: 7)
          Text(category.title)
            .font(.system(size: 10.5))
            .foregroundStyle(WindowPalette.textTertiary)
        }
      }
    }
  }
}

private struct TokenHistoryChart: View {
  let series: Dashboard.TokenUsageSeries

  var body: some View {
    Chart(segments) { segment in
      BarMark(
        x: .value("Time", segment.date),
        y: .value("Tokens", Double(segment.tokens))
      )
      .foregroundStyle(by: .value("Token class", segment.category.title))
      .cornerRadius(2)
      .accessibilityLabel("\(axisLabel(segment.date)), \(segment.category.title)")
      .accessibilityValue(TokenFormat.compact(segment.tokens))
    }
    .chartForegroundStyleScale(
      domain: TokenHistoryCategory.allCases.map(\.title),
      range: TokenHistoryCategory.allCases.map(\.color)
    )
    .breakdownChartStyle(
      xMarkCount: 6,
      xLabel: axisLabel,
      yLabel: { TokenFormat.compact(UInt64(max(0, $0))) }
    )
  }

  private var segments: [TokenHistorySegment] {
    series.buckets.flatMap { bucket in
      TokenHistoryCategory.allCases.map { category in
        TokenHistorySegment(
          bucket: bucket,
          category: category,
          tokens: category.tokens(in: bucket)
        )
      }
    }
  }

  private func axisLabel(_ date: Date) -> String {
    switch series.id {
    case "hour":
      date.formatted(.dateTime.hour().minute())
    case "day":
      date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)))
    default:
      date.formatted(.dateTime.month(.abbreviated).day())
    }
  }
}

private struct TokenHistorySegment: Identifiable {
  let bucket: Dashboard.TokenUsageBucket
  let category: TokenHistoryCategory
  let tokens: UInt64

  var id: String { "\(bucket.id):\(category.rawValue)" }

  /// Bars sit at the middle of their bucket so wide buckets are not skewed left.
  var date: Date {
    let midpoint = bucket.period.startUnix
      + (bucket.period.endExclusiveUnix - bucket.period.startUnix) / 2
    return Date(timeIntervalSince1970: TimeInterval(midpoint))
  }
}
