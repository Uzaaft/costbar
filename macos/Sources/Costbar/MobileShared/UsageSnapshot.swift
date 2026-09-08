import Foundation
import CostbarUsageKit

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

        func isActive(at now: Date) -> Bool {
            costbar_usage_is_active(resetsAt?.timeIntervalSince1970 ?? 0, resetsAt == nil ? 0 : 1, now.timeIntervalSince1970) != 0
        }
    }

    struct Provider: Codable, Sendable, Identifiable {
        let id: String
        let name: String
        let available: Bool
        let updatedAt: Date
        let totals: [Total]
        let quotas: [Quota]

        func highestActiveQuota(at now: Date) -> Quota? {
            let snapshot = UsageSnapshot(version: 1, generatedAt: updatedAt, totals: [], providers: [self])
            let index = snapshot.evaluate(at: now).summary.highest_index
            return index < quotas.count ? quotas[index] : nil
        }

        func hasFreshUsage(at now: Date) -> Bool {
            costbar_usage_provider_is_fresh(updatedAt.timeIntervalSince1970, available ? 1 : 0, now.timeIntervalSince1970) != 0
        }
    }

    let version: Int
    let generatedAt: Date
    let totals: [Total]
    let providers: [Provider]

    func isStale(at now: Date) -> Bool {
        costbar_usage_is_stale(generatedAt.timeIntervalSince1970, now.timeIntervalSince1970) != 0
    }

    func highestActiveQuota(at now: Date) -> Quota? {
        let evaluation = evaluate(at: now)
        guard evaluation.summary.highest_index < evaluation.quotas.count else { return nil }
        let (provider, quota) = evaluation.quotas[evaluation.summary.highest_index]
        return Quota(id: quota.id, label: "\(provider.name) · \(quota.label)",
                     usedPercent: quota.usedPercent, resetsAt: quota.resetsAt)
    }

    /// Zig supplies semantic transition dates; WidgetKit owns scheduling/rendering.
    func timelineDates(from now: Date) -> [Date] {
        var dates = [now]
        var cursor = now
        while true {
            let summary = evaluate(at: cursor).summary
            guard summary.has_next_transition != 0 else { return dates }
            cursor = Date(timeIntervalSince1970: summary.next_transition)
            dates.append(cursor)
        }
    }

    fileprivate struct Evaluation {
        let quotas: [(Provider, Quota)]
        let results: [costbar_usage_result_t]
        let summary: costbar_usage_summary_t
    }

    /// Swift owns every buffer. The C calls borrow them synchronously and retain
    /// no pointers, so neither allocators nor Apple types cross the boundary.
    fileprivate func evaluate(at now: Date, threshold: Int = 80) -> Evaluation {
        let providerInputs = providers.map {
            costbar_usage_provider_t(updated_at: $0.updatedAt.timeIntervalSince1970, available: $0.available ? 1 : 0)
        }
        let quotas = providers.flatMap { provider in provider.quotas.map { (provider, $0) } }
        let quotaInputs = providers.enumerated().flatMap { index, provider in
            provider.quotas.map {
                costbar_usage_quota_t(provider_index: index, used_percent: $0.usedPercent,
                                     resets_at: $0.resetsAt?.timeIntervalSince1970 ?? 0, has_reset: $0.resetsAt == nil ? 0 : 1)
            }
        }
        var results = Array(repeating: costbar_usage_result_t(), count: quotaInputs.count)
        var summary = costbar_usage_summary_t()
        let succeeded = providerInputs.withUnsafeBufferPointer { providerBuffer in
            quotaInputs.withUnsafeBufferPointer { quotaBuffer in
                var input = costbar_usage_snapshot_t(generated_at: generatedAt.timeIntervalSince1970,
                    providers: providerBuffer.baseAddress, provider_count: providerBuffer.count,
                    quotas: quotaBuffer.baseAddress, quota_count: quotaBuffer.count)
                return results.withUnsafeMutableBufferPointer { resultBuffer in
                    costbar_usage_evaluate(&input, now.timeIntervalSince1970, UInt32(exactly: threshold) ?? .max,
                        resultBuffer.baseAddress, resultBuffer.count, &summary)
                }
            }
        }
        precondition(succeeded != 0, "Invalid usage policy buffer layout")
        return Evaluation(quotas: quotas, results: results, summary: summary)
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
        let evaluation = snapshot.evaluate(at: now, threshold: threshold)
        return evaluation.quotas.enumerated().compactMap { index, entry in
            let result = evaluation.results[index]
            guard result.should_alert != 0 else { return nil }
            let (provider, quota) = entry
            let providerID = Array(provider.id.utf8)
            let quotaID = Array(quota.id.utf8)
            var buffer = [UInt8](repeating: 0, count: providerID.count + quotaID.count + 64)
            let count = providerID.withUnsafeBufferPointer { providerBuffer in
                quotaID.withUnsafeBufferPointer { quotaBuffer in
                    buffer.withUnsafeMutableBufferPointer { output in
                        costbar_usage_alert_key(providerBuffer.baseAddress, providerBuffer.count,
                            quotaBuffer.baseAddress, quotaBuffer.count, result.alert_window,
                            UInt32(exactly: threshold) ?? .max, output.baseAddress, output.count)
                    }
                }
            }
            precondition(count > 0, "Insufficient alert identity buffer")
            let id = String(decoding: buffer.prefix(count), as: UTF8.self)
            guard !delivered.contains(id) else { return nil }
            return Alert(id: id, title: "\(provider.name) usage",
                         body: "\(quota.label) is \(quota.usedPercent.formatted(.number.precision(.fractionLength(0))))% used.")
        }
    }
}
