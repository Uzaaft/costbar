import Combine
import CostbarKit
import Foundation

/// Polls the Zig session monitor independently of the billed dashboard.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var snapshot: AgentSessionSnapshot?
    @Published private(set) var anyBusy = false
    @Published private(set) var transitions: [AgentSessionTransition] = []

    nonisolated(unsafe) private var monitor: OpaquePointer?
    private var timer: Timer?
    private let loadCodexHomes: @MainActor () -> [(id: String, home: String)]

    init(loadCodexHomes: @escaping @MainActor () -> [(id: String, home: String)] = SessionStore.defaultCodexHomes) {
        self.loadCodexHomes = loadCodexHomes
        monitor = costbar_session_monitor_create()
    }

    deinit {
        if let monitor {
            costbar_session_monitor_destroy(monitor)
        }
    }

    func start() {
        applyRoots()
        poll()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func activity(for providerTypeID: String) -> AgentProviderActivity? {
        snapshot?.providers.first { $0.matches(providerTypeID: providerTypeID) }
    }

    private func applyRoots() {
        guard let monitor else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var lines = ["claude\tdefault\t\(home)"]
        let homes = loadCodexHomes()
        if homes.isEmpty {
            lines.append("codex\tdefault\t\(home)/.codex")
        } else {
            for account in homes {
                lines.append("codex\t\(account.id)\t\(account.home)")
            }
        }
        let payload = Data(lines.joined(separator: "\n").utf8)
        _ = payload.withUnsafeBytes { buffer in
            costbar_session_monitor_set_roots(monitor, buffer.costbarBytes)
        }
    }

    private func poll() {
        guard let monitor else { return }
        applyRoots()
        var json = costbar_bytes_t(ptr: nil, len: 0)
        let now = Int64(Date.now.timeIntervalSince1970)
        guard costbar_session_monitor_poll(monitor, now, &json) == COSTBAR_STATUS_OK,
              let pointer = json.ptr
        else { return }
        let data = Data(bytes: pointer, count: json.len)
        var transitionBytes = costbar_bytes_t(ptr: nil, len: 0)
        if costbar_session_monitor_transitions(monitor, &transitionBytes) == COSTBAR_STATUS_OK,
           let transitionPointer = transitionBytes.ptr
        {
            let transitionData = Data(bytes: transitionPointer, count: transitionBytes.len)
            if let decoded = try? Self.decoder.decode([AgentSessionTransition].self, from: transitionData) {
                transitions = decoded
            }
        }
        guard let decoded = try? Self.decoder.decode(AgentSessionSnapshot.self, from: data) else { return }
        snapshot = decoded
        anyBusy = decoded.anyBusy
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private static func defaultCodexHomes() -> [(id: String, home: String)] {
        (try? CodexAccountManager().snapshot().accounts.map { ($0.id, $0.homePath) }) ?? []
    }
}
