import SwiftUI

/// The notch is black and white with one signal color, so it reads on any
/// wallpaper and never competes with the app behind it.
enum NotchPalette {
  static let surface = Color.black
  static let track = Color(white: 0.18)
  static let barTrack = Color(white: 0.27)
  static let textSecondary = Color.white.opacity(0.6)
  static let textTertiary = Color.white.opacity(0.45)
  static let hairline = Color.white.opacity(0.12)
  static let border = Color.white.opacity(0.1)
}

/// Green while there is plenty left, yellow past half, red when it is about to
/// run out. The one scale for every fraction the notch shows.
enum QuotaTone {
  static func color(for percent: Double) -> Color {
    if percent >= 80 { return Color(red: 1.0, green: 0.27, blue: 0.23) }
    if percent >= 50 { return Color(red: 0.98, green: 0.85, blue: 0.10) }
    return Color(red: 0.19, green: 0.84, blue: 0.29)
  }
}

struct QuotaRing: View {
  let percent: Double
  var lineWidth: CGFloat = 4.5

  var body: some View {
    let fraction = min(max(percent, 0), 100) / 100
    ZStack {
      Circle()
        .stroke(NotchPalette.track, lineWidth: lineWidth)
      Circle()
        .trim(from: 0, to: fraction)
        .stroke(
          QuotaTone.color(for: percent),
          style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
    }
  }
}

struct QuotaBar: View {
  let percent: Double

  var body: some View {
    let fraction = min(max(percent, 0), 100) / 100
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(NotchPalette.barTrack)
        Capsule()
          .fill(QuotaTone.color(for: percent))
          .frame(width: max(proxy.size.width * fraction, 4))
      }
    }
    .frame(height: 4)
  }
}

/// The rail silhouette: a rounded slab whose ends flare into the screen edge
/// with concave fillets, the way a hardware notch meets the bezel. The path
/// fills the whole rect; the outermost `filletRadius` at each end is the flare.
struct NotchShape: Shape {
  let edge: NotchEdge
  var cornerRadius: CGFloat = 26
  var filletRadius: CGFloat = 32

  func path(in rect: CGRect) -> Path {
    let depth = edge.isVertical ? rect.width : rect.height
    let length = edge.isVertical ? rect.height : rect.width
    let corner = min(cornerRadius, depth / 2)
    let fillet = max(0, min(filletRadius, length / 2 - corner))
    // Quarter circles as cubics, in (inset from the edge, distance along the
    // edge) coordinates, so one construction serves all four edges.
    let k: CGFloat = 0.5523

    func p(_ d: CGFloat, _ a: CGFloat) -> CGPoint {
      switch edge {
      case .right: CGPoint(x: rect.maxX - d, y: rect.minY + a)
      case .left: CGPoint(x: rect.minX + d, y: rect.minY + a)
      case .top: CGPoint(x: rect.minX + a, y: rect.minY + d)
      case .bottom: CGPoint(x: rect.minX + a, y: rect.maxY - d)
      }
    }

    var path = Path()
    path.move(to: p(0, 0))
    path.addCurve(
      to: p(fillet, fillet),
      control1: p(0, k * fillet),
      control2: p((1 - k) * fillet, fillet)
    )
    path.addLine(to: p(depth - corner, fillet))
    path.addCurve(
      to: p(depth, fillet + corner),
      control1: p(depth - corner + k * corner, fillet),
      control2: p(depth, fillet + corner - k * corner)
    )
    path.addLine(to: p(depth, length - fillet - corner))
    path.addCurve(
      to: p(depth - corner, length - fillet),
      control1: p(depth, length - fillet - corner + k * corner),
      control2: p(depth - corner + k * corner, length - fillet)
    )
    path.addLine(to: p(fillet, length - fillet))
    path.addCurve(
      to: p(0, length),
      control1: p((1 - k) * fillet, length - fillet),
      control2: p(0, length - k * fillet)
    )
    path.closeSubpath()
    return path
  }
}

/// How much of the rail is on screen. Peeking shows a sliver when the pointer
/// is nearing the edge, so people learn the rail is there before they hit it.
enum NotchStage: Equatable {
  case tucked
  case peeking
  case revealed
}

/// What the rail draws, owned by the controller and observed by the view.
@MainActor
final class NotchRailModel: ObservableObject {
  static let gearKey = "gear"
  static func ringKey(_ reportID: String) -> String { "ring:" + reportID }

  @Published var reports: [Dashboard.ProviderReport] = []
  @Published var edge: NotchEdge = .right
  @Published var stage: NotchStage = .tucked
  var isRevealed: Bool { stage == .revealed }
  /// Rings draw from empty each time the rail slides out, so the arcs growing
  /// is part of the reveal. Cleared once the rail has slid back in.
  @Published var ringsFilled = false
  @Published var isGearHovered = false
  /// Hit rectangles in the panel's top-left coordinate space, keyed by report
  /// ID, `ringKey`, and `gearKey`. Plain storage: read on pointer moves, never
  /// observed, so layout reporting cannot feed back into layout.
  var frames: [String: CGRect] = [:]
}

/// The rail itself: one ring and percentage per coding agent, and the gear tab
/// tucked under the end. Slides fully off screen when tucked away and paints
/// its own shadow so nothing lags a frame behind the slide.
struct AgentNotchRail: View {
  @ObservedObject var model: NotchRailModel

  /// Rail thickness across the edge: rings stacked for vertical edges, ring
  /// over label for horizontal ones.
  static let depth: CGFloat = 70
  static let horizontalDepth: CGFloat = 98
  /// How much of the rail shows while peeking.
  static let peekWidth: CGFloat = 8
  static let ringSize: CGFloat = 44
  static let gearSize: CGFloat = 34
  /// Room around the rail for its shadow.
  static let margin: CGFloat = 28
  private static let cornerRadius: CGFloat = 26
  private static let filletRadius: CGFloat = 32
  /// Far enough that the rail, its shadow, and the gear are all past the edge.
  private static let tuckedDistance: CGFloat = 170

  var body: some View {
    let edge = model.edge
    let model = model
    stack(edge) {
      rail(edge)
      gearTab(edge)
    }
    .padding(Self.margins(edge))
    .offset(Self.offset(for: model.stage, edge: edge))
    .animation(.spring(response: 0.28, dampingFraction: 0.92), value: model.stage)
    .onPreferenceChange(NotchFramePreference.self) { frames in
      MainActor.assumeIsolated { model.frames = frames }
    }
    .environment(\.colorScheme, .dark)
  }

  @ViewBuilder
  private func stack<Content: View>(
    _ edge: NotchEdge,
    @ViewBuilder content: () -> Content
  ) -> some View {
    switch edge {
    case .right: VStack(alignment: .trailing, spacing: 4, content: content)
    case .left: VStack(alignment: .leading, spacing: 4, content: content)
    case .top: HStack(alignment: .top, spacing: 4, content: content)
    case .bottom: HStack(alignment: .bottom, spacing: 4, content: content)
    }
  }

  private func rail(_ edge: NotchEdge) -> some View {
    Group {
      if edge.isVertical {
        VStack(spacing: 30) { items }
          .padding(.top, Self.filletRadius + 26)
          .padding(.bottom, Self.filletRadius + 15)
          .frame(width: Self.depth)
      } else {
        HStack(spacing: 30) { items }
          .padding(.leading, Self.filletRadius + 26)
          .padding(.trailing, Self.filletRadius + 15)
          .frame(height: Self.horizontalDepth)
      }
    }
    .background(
      NotchShape(edge: edge, cornerRadius: Self.cornerRadius, filletRadius: Self.filletRadius)
        .fill(NotchPalette.surface)
        .shadow(color: .black.opacity(0.4), radius: 12, y: 3)
    )
  }

  private var items: some View {
    ForEach(model.reports) { report in
      item(report)
    }
  }

  private func item(_ report: Dashboard.ProviderReport) -> some View {
    let window = report.allowanceWindows.first
    let shown = model.ringsFilled ? (window?.usedPercent ?? 0) : 0
    return VStack(spacing: 9) {
      ZStack {
        QuotaRing(percent: shown)
          .animation(.easeOut(duration: 0.36), value: shown)
        ProviderLogo(providerID: report.summary.providerTypeID, size: 20, monochrome: .white)
      }
      .frame(width: Self.ringSize, height: Self.ringSize)
      .reportFrame(NotchRailModel.ringKey(report.id))

      Text(window?.usedPercentText ?? "—")
        .font(.system(size: 14, weight: .bold))
        .foregroundStyle(window == nil ? NotchPalette.textTertiary : .white)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
    .frame(width: Self.depth)
    .contentShape(Rectangle())
    .reportFrame(report.id)
  }

  /// Idle, a thin arc peeks out from under the rail like a drawer pull. Under
  /// the pointer it fills into a button with the gear on it.
  private func gearTab(_ edge: NotchEdge) -> some View {
    let hovered = model.isGearHovered
    return ZStack {
      Circle()
        .trim(from: 0.29, to: 0.67)
        .stroke(NotchPalette.surface, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
        .rotationEffect(Self.arcRotation(edge))
        .padding(2.25)
        .opacity(hovered ? 0 : 1)
      Circle()
        .fill(NotchPalette.surface)
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        .scaleEffect(hovered ? 1 : 0.7)
        .opacity(hovered ? 1 : 0)
      Image(systemName: "gearshape")
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.white)
        .opacity(hovered ? 1 : 0)
    }
    .frame(width: Self.gearSize, height: Self.gearSize)
    .animation(.easeOut(duration: 0.18), value: hovered)
    .contentShape(Rectangle())
    .reportFrame(NotchRailModel.gearKey)
    .padding(Self.gearOverhang(edge))
  }

  private static func arcRotation(_ edge: NotchEdge) -> Angle {
    switch edge {
    case .right: .degrees(0)
    case .left: .degrees(180)
    case .top: .degrees(-90)
    case .bottom: .degrees(90)
    }
  }

  /// Pulls the gear part-way past the edge, so only its inner half shows.
  private static func gearOverhang(_ edge: NotchEdge) -> EdgeInsets {
    let overhang: CGFloat = -10
    switch edge {
    case .right: return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: overhang)
    case .left: return EdgeInsets(top: 0, leading: overhang, bottom: 0, trailing: 0)
    case .top: return EdgeInsets(top: overhang, leading: 0, bottom: 0, trailing: 0)
    case .bottom: return EdgeInsets(top: 0, leading: 0, bottom: overhang, trailing: 0)
    }
  }

  private static func margins(_ edge: NotchEdge) -> EdgeInsets {
    let m = margin
    switch edge {
    case .right: return EdgeInsets(top: m, leading: m, bottom: m, trailing: 0)
    case .left: return EdgeInsets(top: m, leading: 0, bottom: m, trailing: m)
    case .top: return EdgeInsets(top: 0, leading: m, bottom: m, trailing: m)
    case .bottom: return EdgeInsets(top: m, leading: m, bottom: 0, trailing: m)
    }
  }

  static func thickness(_ edge: NotchEdge) -> CGFloat {
    edge.isVertical ? depth : horizontalDepth
  }

  /// How far past the edge the rail sits: all the way when tucked, all but a
  /// sliver when peeking. The fillets and gear are still out of sight while
  /// peeking, so the sliver reads as a plain rounded tab.
  private static func offset(for stage: NotchStage, edge: NotchEdge) -> CGSize {
    let distance: CGFloat = switch stage {
    case .revealed: 0
    case .peeking: thickness(edge) - peekWidth
    case .tucked: tuckedDistance
    }
    return switch edge {
    case .right: CGSize(width: distance, height: 0)
    case .left: CGSize(width: -distance, height: 0)
    case .top: CGSize(width: 0, height: -distance)
    case .bottom: CGSize(width: 0, height: distance)
    }
  }
}

private struct NotchFramePreference: PreferenceKey {
  static let defaultValue: [String: CGRect] = [:]

  static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
    value.merge(nextValue()) { $1 }
  }
}

private extension View {
  /// Reports where this view sits in the panel so the controller can hit-test
  /// the pointer itself. SwiftUI's hover tracking wants a key window, and the
  /// rail must never be one.
  func reportFrame(_ key: String) -> some View {
    background(GeometryReader { proxy in
      Color.clear.preference(
        key: NotchFramePreference.self,
        value: [key: proxy.frame(in: .global)]
      )
    })
  }
}
