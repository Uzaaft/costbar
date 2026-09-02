import Combine
import Foundation

/// Which screen edge the quota notch hangs from.
enum NotchEdge: String, CaseIterable, Identifiable, Sendable {
    case right
    case left
    case top
    case bottom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .right: "Right"
        case .left: "Left"
        case .top: "Top"
        case .bottom: "Bottom"
        }
    }

    /// Whether the rail runs up and down (rings stacked) or across.
    var isVertical: Bool { self == .right || self == .left }
}

/// UI preference only: whether the notch is shown, where it lives, and what
/// its rings do when clicked. Saved as it changes, so the notch and both
/// settings surfaces stay in step without a save step.
@MainActor
final class NotchSettingsStore: ObservableObject {
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    @Published var edge: NotchEdge {
        didSet { defaults.set(edge.rawValue, forKey: Self.edgeKey) }
    }

    /// Provider type IDs whose ring opens the agent when clicked. Agents are
    /// opt-out, so a newly tracked one opens by default.
    @Published private(set) var launchDisabled: Set<String> {
        didSet { defaults.set(Array(launchDisabled).sorted(), forKey: Self.launchDisabledKey) }
    }

    private let defaults: UserDefaults
    private static let enabledKey = "notch-enabled-v1"
    private static let edgeKey = "notch-edge-v1"
    private static let launchDisabledKey = "notch-launch-disabled-v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        edge = defaults.string(forKey: Self.edgeKey)
            .flatMap(NotchEdge.init(rawValue:)) ?? .right
        launchDisabled = Set(
            (defaults.stringArray(forKey: Self.launchDisabledKey) ?? [])
                .filter(CodingAgent.providerTypeIDs.contains)
        )
    }

    func opensApp(_ agent: CodingAgent) -> Bool {
        !launchDisabled.contains(agent.providerTypeID)
    }

    func setOpensApp(_ enabled: Bool, for agent: CodingAgent) {
        if enabled {
            launchDisabled.remove(agent.providerTypeID)
        } else {
            launchDisabled.insert(agent.providerTypeID)
        }
    }
}
