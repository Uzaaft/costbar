import SwiftUI

/// The card beside a ring: every allowance window with its reset time, plus
/// whatever local activity Costbar has counted. Black like the rail, with a
/// pointer toward whichever edge the rail hangs from.
struct AgentQuotaCard: View {
  let report: Dashboard.ProviderReport
  /// The edge the rail is on, which is where the pointer goes. `nil` draws a
  /// plain card, for use inside the popover.
  var pointer: NotchEdge? = nil
  var now: Date = .now

  static let width: CGFloat = 225
  private static let cornerRadius: CGFloat = 14
  private static let pointerLength: CGFloat = 24
  private static let pointerBase: CGFloat = 32

  private var summary: Dashboard.ProviderSummary { report.summary }

  var body: some View {
    content
      .padding(12)
      .frame(width: Self.width, alignment: .leading)
      .background(
        NotchPalette.surface,
        in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
          .stroke(NotchPalette.border, lineWidth: 1)
      }
      .overlay(alignment: Self.pointerAlignment(pointer)) {
        if let pointer {
          PointerShape(edge: pointer)
            .fill(NotchPalette.surface)
            .frame(
              width: pointer.isVertical ? Self.pointerLength : Self.pointerBase,
              height: pointer.isVertical ? Self.pointerBase : Self.pointerLength
            )
            .offset(Self.pointerOffset(pointer))
        }
      }
      .padding(Self.pointerInsets(pointer))
      .environment(\.colorScheme, .dark)
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        ProviderLogo(providerID: summary.providerTypeID, size: 22, monochrome: .white)
        Text("\(summary.displayName) Usage")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.white)
          .lineLimit(1)
        Spacer(minLength: 8)
        if let age {
          Text(age)
            .font(.system(size: 11))
            .foregroundStyle(NotchPalette.textSecondary)
            .lineLimit(1)
            .layoutPriority(1)
        }
      }
      .padding(.bottom, 12)

      if report.allowanceWindows.isEmpty {
        Text(summary.status == .available ? "No quota windows reported" : "Last refresh failed")
          .font(.system(size: 12))
          .foregroundStyle(NotchPalette.textSecondary)
      } else {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(report.allowanceWindows) { window in
            allowance(window)
          }
        }
      }

      if let usage = report.tokenUsage {
        Divider()
          .overlay(NotchPalette.hairline)
          .padding(.vertical, 11)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          VStack(alignment: .leading, spacing: 3) {
            Text("Local activity")
              .font(.system(size: 12, weight: .semibold))
              .foregroundStyle(.white)
            Text(usage.source)
              .font(.system(size: 11))
              .foregroundStyle(NotchPalette.textSecondary)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
          Text("\(TokenFormat.compact(usage.totalTokens)) tokens")
            .font(.system(size: 11))
            .foregroundStyle(NotchPalette.textSecondary)
            .lineLimit(1)
        }
      }
    }
  }

  private func allowance(_ window: Dashboard.AllowanceWindow) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(window.label)
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.white)
          .lineLimit(1)
        Spacer(minLength: 6)
        Text(resetText(window))
          .font(.system(size: 12))
          .foregroundStyle(NotchPalette.textSecondary)
          .lineLimit(1)
      }
      QuotaBar(percent: window.usedPercent)
      Text(window.usedPercentText + " Used")
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white)
    }
  }

  private func resetText(_ window: Dashboard.AllowanceWindow) -> String {
    guard let reset = window.resetsAtUnix else { return "No reset time" }
    let date = Date(timeIntervalSince1970: TimeInterval(reset))
    return "Resets " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
  }

  /// "11 min ago", "1 hr 54 min ago": when the provider last answered.
  private var age: String? {
    guard summary.updatedAtUnix > 0 else { return nil }
    let updated = Date(timeIntervalSince1970: TimeInterval(summary.updatedAtUnix))
    let minutes = max(0, Int(now.timeIntervalSince(updated))) / 60
    if minutes < 1 { return "just now" }
    if minutes < 60 { return "\(minutes) min ago" }
    let hours = minutes / 60
    if hours >= 24 { return "\(hours / 24) d ago" }
    let rest = minutes % 60
    return rest > 0 ? "\(hours) hr \(rest) min ago" : "\(hours) hr ago"
  }

  private static func pointerAlignment(_ edge: NotchEdge?) -> Alignment {
    switch edge {
    case .right: .trailing
    case .left: .leading
    case .top: .top
    case .bottom: .bottom
    case nil: .center
    }
  }

  private static func pointerOffset(_ edge: NotchEdge) -> CGSize {
    switch edge {
    case .right: CGSize(width: pointerLength, height: 0)
    case .left: CGSize(width: -pointerLength, height: 0)
    case .top: CGSize(width: 0, height: -pointerLength)
    case .bottom: CGSize(width: 0, height: pointerLength)
    }
  }

  /// Room for the pointer, so the card's fitting size includes it.
  private static func pointerInsets(_ edge: NotchEdge?) -> EdgeInsets {
    let l = pointerLength
    switch edge {
    case .right: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: l)
    case .left: return EdgeInsets(top: 0, leading: l, bottom: 0, trailing: 0)
    case .top: return EdgeInsets(top: l, leading: 0, bottom: 0, trailing: 0)
    case .bottom: return EdgeInsets(top: 0, leading: 0, bottom: l, trailing: 0)
    case nil: return EdgeInsets()
    }
  }
}

/// A triangle whose tip points at `edge`.
private struct PointerShape: Shape {
  let edge: NotchEdge

  func path(in rect: CGRect) -> Path {
    var path = Path()
    switch edge {
    case .right:
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    case .left:
      path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    case .top:
      path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    case .bottom:
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    }
    path.closeSubpath()
    return path
  }
}
