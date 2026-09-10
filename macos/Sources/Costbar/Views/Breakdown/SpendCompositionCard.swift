import Charts
import SwiftUI

/// Month-to-date spend split into its largest groups.
struct SpendCompositionCard: View {
  /// Beyond this the bars are too narrow to label.
  private static let maximumBars = 8

  let entries: [SpendEntry]
  let currency: String
  let grouping: SpendGrouping

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      CardHeader(
        title: "Month-to-date composition",
        subtitle: "Actual billed spend grouped by \(grouping.title.lowercased())",
        trailing: totalMicros.currencyText(code: currency)
      )

      if chartItems.isEmpty {
        ContentUnavailableView(
          "No billed spend",
          systemImage: "chart.bar",
          description: Text("Configure an account or refresh provider data.")
        )
        .frame(maxWidth: .infinity, minHeight: 150)
      } else {
        SpendBarChart(items: chartItems, currency: currency)
      }
    }
    .cardSurface()
  }

  private var totalMicros: Int64 {
    entries.map(\.amountMicros).saturatingSum
  }

  private var chartItems: [SpendChartItem] {
    let grouped = Dictionary(grouping: entries) { $0[keyPath: grouping.entryLabel] }
    return grouped.map { label, groupedEntries in
      SpendChartItem(
        id: label,
        label: label,
        amountMicros: groupedEntries.map(\.amountMicros).saturatingSum,
        color: groupedEntries.max { $0.amountMicros < $1.amountMicros }?.tint
          ?? WindowPalette.blue
      )
    }
    .filter { $0.amountMicros > 0 }
    .sorted { $0.amountMicros > $1.amountMicros }
    .prefix(Self.maximumBars)
    .map { $0 }
  }
}

private struct SpendChartItem: Identifiable {
  let id: String
  let label: String
  let amountMicros: Int64
  let color: Color

  var amount: Double { Double(amountMicros) / 1_000_000 }
}

private struct SpendBarChart: View {
  let items: [SpendChartItem]
  let currency: String

  var body: some View {
    Chart(items) { item in
      BarMark(
        x: .value("Group", item.label),
        y: .value("Spend", item.amount)
      )
      .foregroundStyle(item.color.gradient)
      .cornerRadius(4)
      .annotation(position: .top, spacing: 6) {
        Text(item.amountMicros.currencyText(code: currency))
          .font(.footnote)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
      .accessibilityLabel(item.label)
      .accessibilityValue(item.amountMicros.currencyText(code: currency))
    }
    // Largest first, as sorted, rather than the axis's alphabetical default.
    .chartXScale(domain: items.map(\.label))
    .chartXAxis {
      AxisMarks { _ in
        AxisValueLabel()
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
        AxisGridLine()
        AxisValueLabel(
          format: .currency(code: currency)
            .precision(.fractionLength(0))
            .locale(MoneyFormat.locale)
        )
      }
    }
    .frame(height: 196)
  }
}
