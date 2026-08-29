import AppKit
import SwiftUI

/// Presents a card in a panel of its own, floating beside the menu bar popover.
///
/// SwiftUI's `.popover` becomes the key window, and a `MenuBarExtra` window
/// closes the moment it stops being key — presenting a popover from inside it
/// dismisses the very menu the card describes. The card therefore gets a
/// borderless, non-activating, click-through panel that is only ever ordered
/// in, so the popover keeps focus and the card can never be interacted with.
@MainActor
final class HoverCardPresenter {
    /// Points of air between the popover edge and the card.
    private static let gap: CGFloat = 10

    private var panel: NSPanel?
    private var hosting: NSHostingView<AnyView>?

    nonisolated init() {}

    func present(_ card: some View, anchor: CGRect, in parent: NSWindow) {
        let root = AnyView(card)
        let hosting = hosting ?? NSHostingView(rootView: root)
        hosting.rootView = root
        self.hosting = hosting

        let panel = panel ?? Self.makePanel()
        self.panel = panel
        if panel.contentView !== hosting { panel.contentView = hosting }

        let size = hosting.fittingSize
        panel.setFrame(
            NSRect(origin: origin(size: size, anchor: anchor, parent: parent), size: size),
            display: true
        )
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
        panel.invalidateShadow()
    }

    func dismiss() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private static func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // Purely informational: every event belongs to the popover behind it.
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.animationBehavior = .utilityWindow
        return panel
    }

    /// Beside the popover, top-aligned with the row that opened it, and always
    /// on screen — flipping to the other side rather than hanging off an edge.
    private func origin(size: NSSize, anchor: CGRect, parent: NSWindow) -> NSPoint {
        let bounds = (parent.screen ?? NSScreen.main)?.visibleFrame ?? parent.frame
        let popover = parent.frame

        var x = popover.minX - size.width - Self.gap
        if x < bounds.minX { x = popover.maxX + Self.gap }
        x = min(max(x, bounds.minX), max(bounds.minX, bounds.maxX - size.width))

        let y = min(
            max(anchor.maxY - size.height, bounds.minY),
            max(bounds.minY, bounds.maxY - size.height)
        )
        return NSPoint(x: x, y: y)
    }
}

/// A live handle on where a SwiftUI view sits on screen, read on demand instead
/// of published, so tracking the anchor never feeds back into a view update.
@MainActor
final class HoverCardAnchor {
    fileprivate weak var view: NSView?

    nonisolated init() {}

    var window: NSWindow? { view?.window }

    var screenRect: CGRect? {
        guard let view, let window = view.window, window.isVisible else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}

private struct HoverCardAnchorReader: NSViewRepresentable {
    let anchor: HoverCardAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        anchor.view = nsView
    }
}

private struct HoverCardModifier<Card: View>: ViewModifier {
    let isPresented: Bool
    @ViewBuilder let card: () -> Card

    @State private var anchor = HoverCardAnchor()
    @State private var presenter = HoverCardPresenter()

    func body(content: Content) -> some View {
        content
            .background(HoverCardAnchorReader(anchor: anchor))
            .onChange(of: isPresented) { _, presented in
                guard presented else { return presenter.dismiss() }
                guard let rect = anchor.screenRect, let window = anchor.window else { return }
                presenter.present(card(), anchor: rect, in: window)
            }
            .onDisappear { presenter.dismiss() }
    }
}

extension View {
    /// Floats `card` beside the window this view lives in while `isPresented`.
    /// The card is a snapshot taken when it opens, so anything in it that has
    /// to keep ticking needs its own `TimelineView`.
    func hoverCard(
        isPresented: Bool,
        @ViewBuilder card: @escaping () -> some View
    ) -> some View {
        modifier(HoverCardModifier(isPresented: isPresented, card: card))
    }
}
