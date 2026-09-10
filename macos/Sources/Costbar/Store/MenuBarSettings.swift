import Combine
import Foundation

/// What the menu-bar extra itself shows. One number, chosen by the user.
enum MenuBarMetric: String, CaseIterable, Identifiable, Sendable {
    case cost
    case tightest
    case claude
    case codex
    case cursor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cost: "Month-to-Date Cost"
        case .tightest: "Tightest Agent Limit"
        case .claude: "Claude Limit"
        case .codex: "Codex Limit"
        case .cursor: "Cursor Limit"
        }
    }

    var detail: String {
        switch self {
        case .cost: "Month-to-date AI and infrastructure spend."
        case .tightest: "The most-used quota window across every coding agent."
        case .claude: "The most-used Claude quota window."
        case .codex: "The most-used Codex quota window."
        case .cursor: "The most-used Cursor quota window."
        }
    }

    /// The agents whose quota this metric reads, or `nil` for the cost total.
    var agents: [CodingAgent]? {
        switch self {
        case .cost: nil
        case .tightest: CodingAgent.allCases
        case .claude: [.claude]
        case .codex: [.codex]
        case .cursor: [.cursor]
        }
    }
}

@MainActor
final class MenuBarSettingsStore: ObservableObject {
    @Published var metric: MenuBarMetric {
        didSet { defaults.set(metric.rawValue, forKey: Self.metricKey) }
    }

    private let defaults: UserDefaults
    private static let metricKey = "menubar-metric-v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        metric = defaults.string(forKey: Self.metricKey)
            .flatMap(MenuBarMetric.init(rawValue:)) ?? .cost
    }
}
