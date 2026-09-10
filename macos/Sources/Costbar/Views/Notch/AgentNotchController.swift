import AppKit
import Combine
import SwiftUI

/// Owns the quota notch for the life of the app: a non-activating panel hugging
/// one screen edge that slides out when the pointer reaches it, the card that
/// floats beside a hovered ring, and the small settings window behind the gear.
///
/// It is deliberately independent of the menu bar popover, so checking a
/// session never means opening a menu or taking focus from the editor.
@MainActor
final class AgentNotchController {
  private enum Timing {
    /// How close to the edge the pointer must get, in points. The pointer
    /// stops a point short of the edge, so this means "pushed against it".
    static let activation: CGFloat = 3
    /// Within this distance of the edge a sliver of the rail peeks out.
    static let peekZone: CGFloat = 40
    /// Extra reach along the edge beyond the rail itself.
    static let alongMargin: CGFloat = 60
    /// Once out, the rail stays while the pointer works this close to the edge.
    static let keepAlive: CGFloat = 220
    static let hideDelay: Duration = .milliseconds(380)
    static let peekHideDelay: Duration = .milliseconds(160)
    /// A little longer than the slide, so rings only empty once out of sight.
    static let slideDuration: Duration = .milliseconds(360)
    static let cardDelay: Duration = .milliseconds(200)
    static let cardHideDelay: Duration = .milliseconds(140)
    /// Covers the cases event monitors miss, such as our own app being active
    /// with the pointer over someone else's window.
    static let fallbackPoll: TimeInterval = 0.25
  }

  private let store: DashboardStore
  private let sessions: SessionStore
  private let settings: NotchSettingsStore
  private let model = NotchRailModel()
  private let cards = NotchCardPresenter()
  private var cancellables: Set<AnyCancellable> = []

  private var panel: NSPanel?
  private var hosting: NSHostingView<AgentNotchRail>?
  /// The screen the panel is laid out on.
  private var screen: NSScreen?
  private var monitors: [Any] = []
  private var fallbackTimer: Timer?

  private var hideTask: Task<Void, Never>?
  private var unfillTask: Task<Void, Never>?
  private var cardTask: Task<Void, Never>?
  private var hoveredID: String?
  private var presentedID: String?
  private var settingsWindow: NSWindow?
  private var holdOpenTask: Task<Void, Never>?
  private var lastTransitionIDs: Set<String> = []

  init(store: DashboardStore, sessions: SessionStore, settings: NotchSettingsStore) {
    self.store = store
    self.sessions = sessions
    self.settings = settings
    model.edge = settings.edge
    // Windows and event monitors want a launched application; the App is
    // still being built when this runs.
    Task { [weak self] in
      self?.start()
    }
  }

  private func start() {
    store.$dashboard
      .map(CodingAgent.reports(in:))
      .sink { [weak self] reports in
        self?.apply(reports: reports)
      }
      .store(in: &cancellables)
    settings.objectWillChange
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.settingsDidChange()
      }
      .store(in: &cancellables)
    sessions.$snapshot
      .receive(on: RunLoop.main)
      .sink { [weak self] snapshot in
        self?.apply(sessions: snapshot)
      }
      .store(in: &cancellables)
    sessions.$transitions
      .receive(on: RunLoop.main)
      .sink { [weak self] transitions in
        self?.announce(transitions)
      }
      .store(in: &cancellables)
    sessions.$anyBusy
      .removeDuplicates()
      .receive(on: RunLoop.main)
      .sink { [weak self] _ in
        self?.store.pollingSettingsDidChange()
      }
      .store(in: &cancellables)
    startMonitoring()
  }

  // MARK: - Inputs

  private func apply(reports: [Dashboard.ProviderReport]) {
    model.reports = reports
    refreshPresence()
  }

  private func apply(sessions snapshot: AgentSessionSnapshot?) {
    var activity: [String: AgentActivitySummaryState] = [:]
    for provider in snapshot?.providers ?? [] {
      activity[provider.providerId] = provider.summary
    }
    model.activity = activity
    if let presentedID {
      presentCard(for: presentedID)
    }
  }

  private func settingsDidChange() {
    if model.edge != settings.edge {
      model.edge = settings.edge
      dismissCard()
      model.stage = .tucked
      model.ringsFilled = false
      // Lay out afresh on whichever screen the pointer is on.
      screen = nil
    }
    refreshPresence()
  }

  private var isEnabled: Bool {
    settings.isEnabled && !model.reports.isEmpty
  }

  /// Puts the panel on screen, still tucked away, or takes it off entirely.
  private func refreshPresence() {
    guard isEnabled else {
      dismissCard()
      hideTask?.cancel()
      hideTask = nil
      model.stage = .tucked
      model.ringsFilled = false
      panel?.ignoresMouseEvents = true
      panel?.orderOut(nil)
      screen = nil
      return
    }
    let panel = ensurePanel()
    if let target = screen ?? screenUnderPointer() ?? NSScreen.main {
      layout(on: target)
    }
    if !panel.isVisible {
      panel.orderFrontRegardless()
    }
    // A changed ring count changes the rail's length. Size once more after
    // SwiftUI has settled so the frame and the hit rectangles agree.
    Task { [weak self] in
      guard let self, let screen = self.screen else { return }
      self.layout(on: screen)
    }
    evaluate()
  }

  // MARK: - Panel

  private func ensurePanel() -> NSPanel {
    if let panel { return panel }
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // The rail paints its own shadow; AppKit's would trail the slide.
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.acceptsMouseMovedEvents = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    panel.animationBehavior = .none
    let hosting = NSHostingView(rootView: AgentNotchRail(model: model))
    panel.contentView = hosting
    self.hosting = hosting
    self.panel = panel
    return panel
  }

  private func layout(on screen: NSScreen) {
    guard let panel, let hosting else { return }
    self.screen = screen
    let size = hosting.fittingSize
    let visible = screen.visibleFrame
    let origin: NSPoint
    switch model.edge {
    case .right:
      origin = NSPoint(x: visible.maxX - size.width, y: visible.midY - size.height / 2)
    case .left:
      origin = NSPoint(x: visible.minX, y: visible.midY - size.height / 2)
    case .top:
      origin = NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height)
    case .bottom:
      origin = NSPoint(x: visible.midX - size.width / 2, y: visible.minY)
    }
    let frame = NSRect(origin: origin, size: size)
    if panel.frame != frame {
      panel.setFrame(frame, display: true)
    }
  }

  private func screenUnderPointer() -> NSScreen? {
    let point = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
  }

  // MARK: - Pointer

  private func startMonitoring() {
    let moves: NSEvent.EventTypeMask = [
      .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
    ]
    if let monitor = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
      MainActor.assumeIsolated { self?.evaluate() }
    }) {
      monitors.append(monitor)
    }
    if let monitor = NSEvent.addLocalMonitorForEvents(
      matching: moves.union(.leftMouseDown),
      handler: { [weak self] event in
        let swallowed = MainActor.assumeIsolated { self?.handleLocal(event) ?? false }
        return swallowed ? nil : event
      }
    ) {
      monitors.append(monitor)
    }
    fallbackTimer = Timer.scheduledTimer(
      withTimeInterval: Timing.fallbackPoll,
      repeats: true
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.evaluate() }
    }
  }

  /// Clicks on the rail are ours; everything else just updates the pointer.
  private func handleLocal(_ event: NSEvent) -> Bool {
    if event.type == .leftMouseDown, let panel, event.window === panel {
      click(at: NSEvent.mouseLocation)
      return true
    }
    evaluate()
    return false
  }

  private func evaluate() {
    guard isEnabled, let panel else { return }
    let cursor = NSEvent.mouseLocation
    let pointerScreen = screenUnderPointer()
    if !model.isRevealed, let pointerScreen, pointerScreen !== screen {
      layout(on: pointerScreen)
    }
    guard let screen else { return }
    let visible = screen.visibleFrame
    let rail = panel.frame

    // How far in from the attached edge the pointer is (negative when it is
    // in the menu bar or Dock beyond it), and whether it is level with the rail.
    let depth: CGFloat
    let level: Bool
    switch model.edge {
    case .right:
      depth = visible.maxX - cursor.x
      level = (rail.minY - Timing.alongMargin...rail.maxY + Timing.alongMargin).contains(cursor.y)
    case .left:
      depth = cursor.x - visible.minX
      level = (rail.minY - Timing.alongMargin...rail.maxY + Timing.alongMargin).contains(cursor.y)
    case .top:
      depth = visible.maxY - cursor.y
      level = (rail.minX - Timing.alongMargin...rail.maxX + Timing.alongMargin).contains(cursor.x)
    case .bottom:
      depth = cursor.y - visible.minY
      level = (rail.minX - Timing.alongMargin...rail.maxX + Timing.alongMargin).contains(cursor.x)
    }
    let onThisScreen = pointerScreen === screen
    let touching = onThisScreen && level && depth <= Timing.activation
    let nearing = onThisScreen && level && depth <= Timing.peekZone
    let overRail = model.isRevealed && rail.insetBy(dx: -6, dy: -6).contains(cursor)
    let overCard = cards.frame?.insetBy(dx: -6, dy: -6).contains(cursor) == true
    let settingsOpen = settingsWindow?.isVisible == true
    let lingering = model.isRevealed && onThisScreen && depth <= Timing.keepAlive

    if touching || overRail || overCard || settingsOpen || lingering {
      cancelTuck()
      reveal()
    } else if nearing, !model.isRevealed {
      cancelTuck()
      peek()
    } else if model.stage != .tucked, hideTask == nil {
      let delay = model.isRevealed ? Timing.hideDelay : Timing.peekHideDelay
      hideTask = Task { [weak self] in
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, let self else { return }
        self.hideTask = nil
        self.tuck()
      }
    }
    trackHover(cursor: cursor, rail: rail)
  }

  private func cancelTuck() {
    hideTask?.cancel()
    hideTask = nil
  }

  private func reveal() {
    guard let panel, !model.isRevealed else { return }
    unfillTask?.cancel()
    unfillTask = nil
    panel.ignoresMouseEvents = false
    model.stage = .revealed
    model.ringsFilled = true
  }

  /// The sliver is a hint, not a control: it stays click-through.
  private func peek() {
    guard model.stage == .tucked else { return }
    model.stage = .peeking
  }

  private func tuck() {
    guard let panel, model.stage != .tucked else { return }
    let wasRevealed = model.isRevealed
    dismissCard()
    hoveredID = nil
    model.stage = .tucked
    model.isGearHovered = false
    panel.ignoresMouseEvents = true
    guard wasRevealed else { return }
    unfillTask = Task { [weak self] in
      try? await Task.sleep(for: Timing.slideDuration)
      guard !Task.isCancelled else { return }
      self?.model.ringsFilled = false
    }
  }

  // MARK: - Hover and clicks

  private func trackHover(cursor: NSPoint, rail: NSRect) {
    guard model.isRevealed, rail.contains(cursor) else {
      setGearHovered(false)
      setHovered(nil)
      return
    }
    let local = localPoint(cursor, in: rail)
    setGearHovered(gearFrame?.contains(local) == true)
    let hit = model.reports.first { model.frames[$0.id]?.contains(local) == true }
    setHovered(hit?.id)
  }

  private func localPoint(_ cursor: NSPoint, in rail: NSRect) -> CGPoint {
    CGPoint(x: cursor.x - rail.minX, y: rail.maxY - cursor.y)
  }

  private var gearFrame: CGRect? {
    model.frames[NotchRailModel.gearKey]?.insetBy(dx: -4, dy: -4)
  }

  private func setGearHovered(_ hovered: Bool) {
    if model.isGearHovered != hovered {
      model.isGearHovered = hovered
    }
  }

  private func setHovered(_ id: String?) {
    guard id != hoveredID else { return }
    hoveredID = id
    cardTask?.cancel()
    let delay: Duration = if id == nil {
      Timing.cardHideDelay
    } else if presentedID == nil {
      Timing.cardDelay
    } else {
      .zero
    }
    cardTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled, let self else { return }
      if let id {
        self.presentCard(for: id)
      } else {
        self.dismissCard()
      }
    }
  }

  private func presentCard(for id: String) {
    guard let panel, let screen,
          let report = model.reports.first(where: { $0.id == id }),
          let ring = model.frames[NotchRailModel.ringKey(id)]
    else { return }
    let anchor = NSRect(
      x: panel.frame.minX + ring.minX,
      y: panel.frame.maxY - ring.maxY,
      width: ring.width,
      height: ring.height
    )
    cards.present(
      AgentQuotaCard(
        report: report,
        sessions: sessions.activity(for: report.summary.providerTypeID)?.sessions ?? [],
        pointer: model.edge
      ),
      anchor: anchor,
      edge: model.edge,
      screen: screen,
      parent: panel
    )
    presentedID = id
  }

  private func dismissCard() {
    cardTask?.cancel()
    cardTask = nil
    presentedID = nil
    cards.dismiss()
  }

  private func click(at cursor: NSPoint) {
    guard let panel, model.isRevealed else { return }
    let local = localPoint(cursor, in: panel.frame)
    if gearFrame?.contains(local) == true {
      showSettings()
      return
    }
    if let session = announcedSession(at: local) {
      focus(pid: session.pid)
      return
    }
    guard let report = model.reports.first(where: { model.frames[$0.id]?.contains(local) == true }),
          let agent = CodingAgent(providerTypeID: report.summary.providerTypeID),
          settings.opensApp(agent)
    else { return }
    AgentLauncher.open(agent)
  }

  private func announcedSession(at local: CGPoint) -> AgentSession? {
    guard let report = model.reports.first(where: { model.frames[$0.id]?.contains(local) == true })
    else { return nil }
    return sessions.activity(for: report.summary.providerTypeID)?.sessions.first { $0.pid != nil }
  }

  private func announce(_ transitions: [AgentSessionTransition]) {
    let fresh = transitions.filter { !lastTransitionIDs.contains($0.id + $0.kind.rawValue) }
    lastTransitionIDs = Set(transitions.map { $0.id + $0.kind.rawValue })
    guard !fresh.isEmpty, settings.announcesCompletion, isEnabled else { return }
    cancelTuck()
    reveal()
    if settings.playsCompletionSound {
      NSSound(named: "Tink")?.play()
    }
    holdOpenTask?.cancel()
    holdOpenTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      guard !Task.isCancelled, let self else { return }
      self.holdOpenTask = nil
      self.evaluate()
    }
  }

  private func focus(pid: Int32?) {
    guard let pid else { return }
    NSRunningApplication(processIdentifier: pid)?.activate()
  }

  // MARK: - Settings window

  private func showSettings() {
    let window = settingsWindow ?? makeSettingsWindow()
    if !window.isVisible {
      window.center()
    }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  private func makeSettingsWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: NotchSettingsView.size),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "Notch"
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.appearance = NSAppearance(named: .darkAqua)
    window.contentView = NSHostingView(
      rootView: NotchSettingsView(settings: settings)
    )
    settingsWindow = window
    return window
  }
}

/// Floats the quota card beside a ring: centered on it, pointing at it, never
/// off screen. Click-through, so hovering the card counts as hovering the rail.
@MainActor
final class NotchCardPresenter {
  private static let gap: CGFloat = 6

  private var panel: NSPanel?
  private var hosting: NSHostingView<AnyView>?
  private var isShowing = false
  /// Bumped on every fresh presentation so the reveal replays; a card that
  /// only moves to another ring keeps its identity and glides instead.
  private var presentation = 0
  private var hideTask: Task<Void, Never>?

  var frame: NSRect? {
    isShowing ? panel?.frame : nil
  }

  func present(
    _ card: some View,
    anchor: NSRect,
    edge: NotchEdge,
    screen: NSScreen,
    parent: NSWindow
  ) {
    hideTask?.cancel()
    hideTask = nil
    if !isShowing { presentation += 1 }
    let root = AnyView(NotchCardReveal(edge: edge) { card }.id(presentation))
    let hosting = hosting ?? NSHostingView(rootView: root)
    hosting.rootView = root
    self.hosting = hosting
    let panel = panel ?? Self.makePanel()
    self.panel = panel
    if panel.contentView !== hosting {
      panel.contentView = hosting
    }

    let size = hosting.fittingSize
    var origin: NSPoint
    switch edge {
    case .right:
      origin = NSPoint(x: anchor.minX - Self.gap - size.width, y: anchor.midY - size.height / 2)
    case .left:
      origin = NSPoint(x: anchor.maxX + Self.gap, y: anchor.midY - size.height / 2)
    case .top:
      origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - Self.gap - size.height)
    case .bottom:
      origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + Self.gap)
    }
    let bounds = screen.visibleFrame
    origin.x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
    origin.y = min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
    let target = NSRect(origin: origin, size: size)

    if isShowing {
      NSAnimationContext.runAnimationGroup { context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        panel.animator().setFrame(target, display: true)
      }
    } else {
      panel.alphaValue = 1
      panel.setFrame(target, display: true)
      if panel.parent !== parent {
        panel.parent?.removeChildWindow(panel)
        parent.addChildWindow(panel, ordered: .above)
      }
      panel.orderFront(nil)
    }
    isShowing = true
  }

  func dismiss() {
    guard let panel, isShowing else { return }
    isShowing = false
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      panel.animator().alphaValue = 0
    }
    hideTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(140))
      guard !Task.isCancelled, let self, !self.isShowing, let panel = self.panel else { return }
      panel.parent?.removeChildWindow(panel)
      panel.orderOut(nil)
    }
  }

  private static func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
    panel.animationBehavior = .none
    return panel
  }
}

/// Fades the card in from a few points nearer the rail. Swapping the card for
/// another ring keeps the same view identity, so it moves rather than replays.
private struct NotchCardReveal<Content: View>: View {
  let edge: NotchEdge
  @ViewBuilder let content: () -> Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var shown = false

  var body: some View {
    content()
      .opacity(shown ? 1 : 0)
      .offset(shown || reduceMotion ? .zero : slide)
      .onAppear {
        withAnimation(.easeOut(duration: 0.2)) {
          shown = true
        }
      }
  }

  private var slide: CGSize {
    switch edge {
    case .right: CGSize(width: 10, height: 0)
    case .left: CGSize(width: -10, height: 0)
    case .top: CGSize(width: 0, height: -10)
    case .bottom: CGSize(width: 0, height: 10)
    }
  }
}

/// Opens the agent's app when it is installed, its website otherwise.
enum AgentLauncher {
  @MainActor
  static func open(_ agent: CodingAgent) {
    let workspace = NSWorkspace.shared
    for bundleID in agent.bundleIdentifiers {
      if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
        workspace.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return
      }
    }
    workspace.open(agent.fallbackURL)
  }
}
