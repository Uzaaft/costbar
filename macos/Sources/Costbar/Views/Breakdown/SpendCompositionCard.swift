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
}

private struct SpendBarChart: View {
  /// Room under the bars for the value and the label.
  private static let labelHeight: CGFloat = 49

  let items: [SpendChartItem]
  let currency: String

  var body: some View {
    GeometryReader { geometry in
      let availableHeight = max(80, geometry.size.height - Self.labelHeight)

      ZStack(alignment: .bottom) {
        chartGrid

        HStack(alignment: .bottom, spacing: 12) {
          ForEach(items) { item in
            bar(item, height: barHeight(for: item, available: availableHeight))
          }
        }
        .padding(.horizontal, 4)
      }
    }
    .frame(height: 196)
  }

  private func bar(_ item: SpendChartItem, height: CGFloat) -> some View {
    VStack(spacing: 7) {
      Text(item.amountMicros.currencyText(code: currency))
        .font(.system(size: 9.5, design: .monospaced))
        .foregroundStyle(WindowPalette.textTertiary)
        .lineLimit(1)
        .minimumScaleFactor(0.65)

      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(
          LinearGradient(
            colors: [item.color.opacity(0.72), item.color],
            startPoint: .bottom,
            endPoint: .top
          )
        )
        .frame(height: height)

      Text(item.label)
        .font(.system(size: 10.5))
        .foregroundStyle(WindowPalette.textSecondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }
    .frame(maxWidth: .infinity)
  }

  private var chartGrid: some View {
    VStack {
      Rectangle().fill(WindowPalette.hairline).frame(height: 1)
      Spacer()
      Rectangle().fill(WindowPalette.hairline).frame(height: 1)
      Spacer()
      Rectangle().fill(WindowPalette.hairline).frame(height: 1)
    }
    .padding(.bottom, 27)
  }

  private func barHeight(for item: SpendChartItem, available: CGFloat) -> CGFloat {
    guard let maximum = items.map(\.amountMicros).max(), maximum > 0 else { return 4 }
    let ratio = CGFloat(Double(item.amountMicros) / Double(maximum))
    return max(5, ratio * available)
  }
}
