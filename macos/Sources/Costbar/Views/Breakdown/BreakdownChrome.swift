import Charts
import SwiftUI

/// The breakdown window paints its own dark chrome instead of following the
/// system appearance, so its colors live here rather than in the asset catalog.
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

enum TokenFormat {
  /// Compact token count, e.g. "1.2M".
  static func compact(_ tokens: UInt64) -> String {
    tokens.formatted(
      .number
        .notation(.compactName)
        .precision(.fractionLength(0...1))
        .locale(MoneyFormat.locale)
    )
  }

  static func withUnit(_ tokens: UInt64) -> String {
    compact(tokens) + " tokens"
  }
}

/// Title, caption, and trailing total shared by every breakdown card.
struct CardHeader: View {
  let title: String
  let subtitle: String
  let trailing: String

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(WindowPalette.textPrimary)
        Text(subtitle)
          .font(.system(size: 11.5))
          .foregroundStyle(WindowPalette.textTertiary)
      }

      Spacer(minLength: 12)

      Text(trailing)
        .font(.system(size: 13, weight: .medium, design: .monospaced))
        .foregroundStyle(WindowPalette.textSecondary)
    }
  }
}

struct ErrorStrip: View {
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

extension View {
  /// The rounded panel every breakdown card sits on.
  func cardSurface() -> some View {
    padding(18)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(WindowPalette.sidebar.opacity(0.68))
          .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .stroke(WindowPalette.hairline, lineWidth: 1)
          }
      )
  }

  /// The rounded, hairline-bordered frame around a breakdown table.
  func tableSurface() -> some View {
    clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
          .stroke(WindowPalette.hairline, lineWidth: 1)
      }
  }

  /// Axis, gridline, and plot styling shared by the breakdown bar charts.
  func breakdownChartStyle(
    xMarkCount: Int,
    xLabel: @escaping (Date) -> String,
    yLabel: @escaping (Double) -> String
  ) -> some View {
    chartLegend(.hidden)
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: xMarkCount)) { value in
          AxisGridLine()
            .foregroundStyle(WindowPalette.hairline)
          AxisTick()
            .foregroundStyle(WindowPalette.textTertiary)
          if let date = value.as(Date.self) {
            AxisValueLabel {
              Text(xLabel(date))
                .font(.system(size: 9.5))
                .foregroundStyle(WindowPalette.textTertiary)
            }
          }
        }
      }
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
          AxisGridLine()
            .foregroundStyle(WindowPalette.hairline)
          if let amount = value.as(Double.self) {
            AxisValueLabel {
              Text(yLabel(amount))
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(WindowPalette.textTertiary)
            }
          }
        }
      }
      .chartPlotStyle { plotArea in
        plotArea.background(WindowPalette.background.opacity(0.34))
      }
      .frame(height: 220)
  }
}
