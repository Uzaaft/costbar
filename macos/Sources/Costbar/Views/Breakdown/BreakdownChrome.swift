import Charts
import SwiftUI

/// The breakdown window's few named roles, all system colors so they follow
/// the appearance, accent color, and Increase Contrast.
enum WindowPalette {
  static let surface = Color(nsColor: .quaternarySystemFill)
  static let tableHeader = Color(nsColor: .quaternarySystemFill)
  static let textPrimary = Color.primary
  static let textSecondary = Color.secondary
  static let textTertiary = Color.secondary
  static let hairline = Color(nsColor: .separatorColor)
  static let blue = Color.accentColor
  static let warning = Color.orange
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
          .font(.title3.weight(.semibold))
          .foregroundStyle(WindowPalette.textPrimary)
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(WindowPalette.textTertiary)
      }

      Spacer(minLength: 12)

      Text(trailing)
        .font(.body.weight(.medium).monospacedDigit())
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
    .font(.callout)
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
          .fill(WindowPalette.surface)
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
                .font(.footnote)
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
                .font(.footnote.monospacedDigit())
                .foregroundStyle(WindowPalette.textTertiary)
            }
          }
        }
      }
      .frame(height: 220)
  }
}
