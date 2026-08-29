import SwiftUI

/// The menu bar popover paints its own dark chrome instead of following the
/// system appearance, so its colors live here rather than in the asset catalog.
enum MenuPalette {
  static let background = Color(red: 0.106, green: 0.106, blue: 0.118)
  /// Surfaces that float above the popover, such as the provider detail card.
  static let raised = Color(red: 0.137, green: 0.139, blue: 0.153)
  static let textPrimary = Color.white
  static let textSecondary = Color.white.opacity(0.58)
  static let textTertiary = Color.white.opacity(0.38)
  static let hairline = Color.white.opacity(0.08)
  static let hover = Color.white.opacity(0.08)
  static let track = Color.white.opacity(0.11)
  static let live = Color(red: 0.16, green: 0.55, blue: 1.0)
  static let warning = Color(red: 0.96, green: 0.61, blue: 0.22)
}

/// "12s ago", "4m ago", "3h ago" — short enough for a status line that updates
/// every second without the row reflowing.
enum RelativeAge {
  static func text(since date: Date, now: Date) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s ago" }
    if seconds < 3_600 { return "\(seconds / 60)m ago" }
    return "\(seconds / 3_600)h ago"
  }
}

/// A duration written the way a deadline reads: "1h 40m", "2d 12h", "45m".
enum DurationFormat {
  static func compact(_ interval: TimeInterval) -> String {
    let seconds = Int(max(0, interval))
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60
    if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
    if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
    return "\(max(minutes, 1))m"
  }
}

private struct HoverHighlight: ViewModifier {
  let cornerRadius: CGFloat
  @State private var isHovering = false

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(isHovering ? MenuPalette.hover : .clear)
      )
      .onHover { isHovering = $0 }
  }
}

extension View {
  func hoverHighlight(cornerRadius: CGFloat = 8) -> some View {
    modifier(HoverHighlight(cornerRadius: cornerRadius))
  }
}
