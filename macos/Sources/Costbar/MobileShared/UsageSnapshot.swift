import Foundation

/// Only normalized display values cross devices; credentials and session contents stay on the Mac.
struct UsageSnapshot: Codable, Sendable {
    struct Total: Codable, Sendable, Identifiable {
        var id: String { currency }
        let currency: String
        let micros: Int64
        let projectedMicros: Int64?

        var formatted: String {
            formattedAmount(micros)
        }

        var projectedFormatted: String? { projectedMicros.map(formattedAmount) }

        private func formattedAmount(_ value: Int64) -> String {
            (Double(value) / 1_000_000).formatted(
                .currency(code: currency).locale(Locale(identifier: "en_US"))
            )
        }
    }

    struct Quota: Codable, Sendable, Identifiable {
        let id: String
        let label: String
        let usedPercent: Double
        let resetsAt: Date?

        func isActive(at now: Date) -> Bool { resetsAt.map { $0 > now } ?? true }
    }

    struct Provider: Codable, Sendable, Identifiable {
        let id: String
        let name: String
        let available: Bool
        let updatedAt: Date
        let totals: [Total]
        let quotas: [Quota]
    }

    let version: Int
    let generatedAt: Date
    let totals: [Total]
    let providers: [Provider]

    static let freshnessInterval: TimeInterval = 1_800

    func isStale(at now: Date) -> Bool {
        now.timeIntervalSince(generatedAt) >= Self.freshnessInterval
    }

    func highestActiveQuota(at now: Date) -> Quota? {
        guard !isStale(at: now) else { return nil }
        return providers.filter {
            $0.available && now.timeIntervalSince($0.updatedAt) < Self.freshnessInterval
        }.flatMap { provider in
            provider.quotas.filter { $0.isActive(at: now) }.map { quota in
                Quota(id: quota.id, label: "\(provider.name) · \(quota.label)",
                      usedPercent: quota.usedPercent, resetsAt: quota.resetsAt)
            }
        }.max { $0.usedPercent < $1.usedPercent }
    }

    /// Local transitions must happen even when WidgetKit delays the next network fetch.
    func timelineDates(from now: Date) -> [Date] {
        let expires = generatedAt.addingTimeInterval(Self.freshnessInterval)
        guard expires > now else { return [now] }
        var dates: Set<Date> = [now, expires]
        for provider in providers where provider.available {
            let providerExpires = provider.updatedAt.addingTimeInterval(Self.freshnessInterval)
            if providerExpires > now && providerExpires < expires { dates.insert(providerExpires) }
            for quota in provider.quotas {
                if let reset = quota.resetsAt, reset > now && reset < expires {
                    dates.insert(reset)
                }
            }
        }
        return dates.sorted()
    }

    static func decode(_ data: Data) throws -> Self {
        let snapshot = try JSONDecoder().decode(Self.self, from: data)
        guard snapshot.version == 1,
              snapshot.providers.allSatisfy({ $0.quotas.allSatisfy { $0.usedPercent.isFinite && $0.usedPercent >= 0 } }) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return snapshot
    }
}

/// Persist identifiers only after delivery succeeds; a reset opens a new alert window.
enum UsageAlerts {
    struct Alert: Sendable {
        let id: String
        let title: String
        let body: String
    }

    static func pending(snapshot: UsageSnapshot, threshold: Int, delivered: Set<String>, now: Date) -> [Alert] {
        guard !snapshot.isStale(at: now) else { return [] }
        return snapshot.providers.filter { $0.available && now.timeIntervalSince($0.updatedAt) < UsageSnapshot.freshnessInterval }.flatMap { provider in
            provider.quotas.compactMap { quota in
                guard quota.isActive(at: now), quota.usedPercent >= Double(threshold) else { return nil }
                // Without a provider reset time, suppress repeats for the current UTC day.
                let window = quota.resetsAt.map { Int($0.timeIntervalSince1970) }
                    ?? Int(now.timeIntervalSince1970 / 86_400)
                let id = "\(provider.id)/\(quota.id)/\(window)/\(threshold)"
                guard !delivered.contains(id) else { return nil }
                return Alert(id: id, title: "\(provider.name) usage",
                             body: "\(quota.label) is \(quota.usedPercent.formatted(.number.precision(.fractionLength(0))))% used.")
            }
        }
    }
}
