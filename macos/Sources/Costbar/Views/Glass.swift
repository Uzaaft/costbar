import SwiftUI

/// Liquid Glass belongs to the layer that floats above content: toolbars,
/// sidebars and buttons, which the system draws itself, and transient panels
/// such as the hover card, which sit beside the menu bar popover's own glass.
/// Content inside a window stays on quiet fills so it never stacks glass on glass.
extension View {
  /// The surface for a floating panel, such as the hover card. Glass where the
  /// system has it; a material with a hairline edge before that.
  @ViewBuilder
  func panelSurface(in shape: some Shape) -> some View {
    if #available(macOS 26, *) {
      glassEffect(.regular, in: shape)
    } else {
      background(.regularMaterial, in: shape)
        .overlay { shape.stroke(.primary.opacity(0.08), lineWidth: 1) }
    }
  }

  /// A custom bar pinned to the bottom edge. Where the system supports it, the
  /// bar registers for the scroll edge effect so content scrolling beneath it
  /// stays legible without a custom background.
  @ViewBuilder
  func bottomBar(@ViewBuilder content: () -> some View) -> some View {
    let bar = content()
    if #available(macOS 26, *) {
      safeAreaBar(edge: .bottom, spacing: 0) { bar }
    } else {
      safeAreaInset(edge: .bottom, spacing: 0) {
        bar
          .background(.bar)
          .overlay(alignment: .top) { Divider() }
      }
    }
  }
}
