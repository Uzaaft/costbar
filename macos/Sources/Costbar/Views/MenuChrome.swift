import SwiftUI

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

/// "now", "44 sec. ago", "3 min. ago" — the system's own relative wording, kept
/// current without redrawing every second.
struct RelativeAgeText: View {
  let date: Date

  var body: some View {
    TimelineView(.periodic(from: .now, by: 15)) { _ in
      Text(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
    }
  }
}

extension Dashboard.AllowanceWindow {
  /// The accent color while there is room, the system's warning colors as the
  /// allowance runs out. The thresholds match the quota notifications.
  var statusTint: Color {
    if usedPercent >= 95 { return .red }
    if usedPercent >= 80 { return .orange }
    return .accentColor
  }
}

/// How much of an allowance is used. A capsule rather than `ProgressView`,
/// whose linear style on macOS ignores `tint`.
struct UsageBar: View {
  let fraction: Double
  let tint: Color
  var height: CGFloat = 4
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let fraction = min(max(fraction, 0), 1)
    GeometryReader { proxy in
      Capsule()
        .fill(.quaternary)
        .overlay(alignment: .leading) {
          Capsule()
            .fill(tint)
            // Never thinner than a dot, so a sliver of use is still visible.
            .frame(width: fraction > 0 ? max(height, proxy.size.width * fraction) : 0)
        }
    }
    .frame(height: height)
    .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: fraction)
    .accessibilityHidden(true)
  }
}

private struct HoverHighlight: ViewModifier {
  let cornerRadius: CGFloat
  @State private var isHovering = false

  func body(content: Content) -> some View {
    content
      .background(
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .fill(isHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
      )
      .onHover { isHovering = $0 }
  }
}

extension View {
  /// The highlight a menu row gets under the pointer. For rows that act when
  /// clicked; a row that only informs should not light up.
  func hoverHighlight(cornerRadius: CGFloat = 8) -> some View {
    modifier(HoverHighlight(cornerRadius: cornerRadius))
  }

  /// A grouped block of rows on the popover, the way System Settings and
  /// Control Center group theirs.
  func platter() -> some View {
    background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  /// Spins a refresh arrow while work is in flight. Continuous rotation needs
  /// macOS 15; earlier systems pulse instead. Both honor Reduce Motion.
  @ViewBuilder
  func refreshSpin(isActive: Bool) -> some View {
    if #available(macOS 15, *) {
      symbolEffect(.rotate, options: .repeat(.continuous), isActive: isActive)
    } else {
      symbolEffect(.pulse, isActive: isActive)
    }
  }

  /// A round icon button in the popover header: glass where the system has it,
  /// a bordered circle before that.
  @ViewBuilder
  func headerButtonStyle() -> some View {
    if #available(macOS 26, *) {
      buttonStyle(.glass)
        .buttonBorderShape(.circle)
    } else {
      buttonStyle(.bordered)
        .buttonBorderShape(.circle)
    }
  }
}
