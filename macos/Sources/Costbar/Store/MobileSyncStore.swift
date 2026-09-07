import Foundation

@MainActor
final class MobileSyncStore: ObservableObject {
    static let shared = MobileSyncStore()
    static var isSupported: Bool { Bundle.main.object(forInfoDictionaryKey: "CostbarMobileSyncEnabled") as? String == "YES" }
    @Published private(set) var isEnabled = MobileSyncStore.isSupported && UserDefaults.standard.bool(forKey: "mobileSyncEnabled")
    @Published private(set) var status = "Sync is off"
    private let cloud = UsageCloud()
    private var task: Task<Void, Never>?

    func setEnabled(_ enabled: Bool, dashboard: Dashboard?) {
        guard Self.isSupported else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "mobileSyncEnabled")
        // Serialize removal after any in-flight upload so disabling cannot leave a later upload behind.
        let previous = task
        task = Task {
            await previous?.value
            if enabled {
                if let dashboard { await upload(dashboard) }
            } else {
                do {
                    try await cloud.remove()
                    status = "Sync is off; iCloud snapshot removed"
                } catch { status = "Sync is off. Could not remove snapshot: \(error.localizedDescription)" }
            }
        }
    }

    func publish(_ dashboard: Dashboard) {
        guard isEnabled else { return }
        let previous = task
        task = Task {
            await previous?.value
            guard isEnabled else { return }
            await upload(dashboard)
        }
    }

    private func upload(_ dashboard: Dashboard) async {
        status = "Syncing to iCloud…"
        do {
            try await cloud.publish(UsageSnapshot(dashboard: dashboard))
            status = "Synced to iCloud"
        } catch { status = error.localizedDescription }
    }
}

extension UsageSnapshot {
    private static func totals(for report: Dashboard.ProviderReport) -> [Total] {
        guard report.summary.contributesToTotals else { return [] }
        if !report.financials.isEmpty {
            return report.financials.map {
                Total(currency: $0.currency, micros: $0.currentCostMicros, projectedMicros: $0.projectedCostMicros)
            }
        }
        guard report.summary.status == .available else { return [] }
        return [Total(currency: report.summary.currency,
                      micros: report.summary.currentCostMicros,
                      projectedMicros: report.summary.projectedCostMicros)]
    }

    init(dashboard: Dashboard) {
        self.init(
            version: 1,
            generatedAt: Date(timeIntervalSince1970: Double(dashboard.generatedAtUnix)),
            totals: dashboard.totals.map {
                Total(currency: $0.currency, micros: $0.currentCostMicros, projectedMicros: $0.projectedCostMicros)
            },
            providers: dashboard.providers.filter { $0.summary.status != .notConfigured }.map { report in
                Provider(
                    id: report.id, name: report.summary.displayName,
                    available: report.summary.status == .available,
                    updatedAt: Date(timeIntervalSince1970: Double(report.summary.updatedAtUnix)),
                    totals: Self.totals(for: report),
                    quotas: report.allowanceWindows.map {
                        Quota(id: $0.id, label: $0.label, usedPercent: $0.usedPercent,
                              resetsAt: $0.resetsAtUnix.map { Date(timeIntervalSince1970: Double($0)) })
                    }
                )
            }
        )
    }
}
