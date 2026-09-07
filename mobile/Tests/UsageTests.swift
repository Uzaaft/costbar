import Foundation
import Testing
@testable import CostbarUsage

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func snapshot(percent: Double = 85, reset: Date? = now.addingTimeInterval(600), available: Bool = true, age: Double = 0) -> UsageSnapshot {
    UsageSnapshot(version: 1, generatedAt: now.addingTimeInterval(-age), totals: [
        .init(currency: "USD", micros: 123_450_000, projectedMicros: nil),
        .init(currency: "EUR", micros: 45_000_000, projectedMicros: 60_000_000)
    ], providers: [.init(id: "codex/personal", name: "Codex", available: available, updatedAt: now.addingTimeInterval(-age), totals: [], quotas: [
        .init(id: "weekly", label: "Weekly", usedPercent: percent, resetsAt: reset)
    ])])
}

@Test func snapshotRoundTripPreservesCurrenciesAndQuota() throws {
    let original = snapshot()
    let decoded = try UsageSnapshot.decode(JSONEncoder().encode(original))
    #expect(decoded.totals.map(\.currency) == ["USD", "EUR"])
    #expect(decoded.totals.first?.micros == 123_450_000)
    #expect(decoded.totals.first?.formatted == "$123.45")
    #expect(decoded.totals.last?.projectedFormatted == "€60.00")
    #expect(decoded.providers.first?.quotas.first?.usedPercent == 85)
}

@Test func alertsDeduplicateAndReset() throws {
    let initial = UsageAlerts.pending(snapshot: snapshot(), threshold: 80, delivered: [], now: now)
    #expect(initial.count == 1)
    let id = try #require(initial.first?.id)
    #expect(UsageAlerts.pending(snapshot: snapshot(), threshold: 80, delivered: [id], now: now).isEmpty)
    #expect(UsageAlerts.pending(snapshot: snapshot(reset: now.addingTimeInterval(1_200)), threshold: 80, delivered: [id], now: now).count == 1)
}

@Test func doesNotAlertForStaleUnavailableExpiredOrBelowThreshold() {
    for value in [snapshot(age: 1_801), snapshot(available: false), snapshot(reset: now), snapshot(percent: 79.9)] {
        #expect(UsageAlerts.pending(snapshot: value, threshold: 80, delivered: [], now: now).isEmpty)
    }
    #expect(UsageAlerts.pending(snapshot: snapshot(percent: 80), threshold: 80, delivered: [], now: now).count == 1)
}

@Test func rejectsUnknownSchemaAndNegativeQuota() throws {
    let future = UsageSnapshot(version: 2, generatedAt: now, totals: [], providers: [])
    #expect(throws: (any Error).self) { try UsageSnapshot.decode(JSONEncoder().encode(future)) }
    #expect(throws: (any Error).self) { try UsageSnapshot.decode(JSONEncoder().encode(snapshot(percent: -1))) }
}

@Test func widgetExpiresCachedUsageWithoutAnotherFetch() {
    let value = snapshot(age: 1_200)
    let dates = value.timelineDates(from: now)
    #expect(dates == [now, now.addingTimeInterval(600)])
    #expect(value.highestActiveQuota(at: now)?.label == "Codex · Weekly")
    #expect(value.isStale(at: dates[1]))
    #expect(value.highestActiveQuota(at: dates[1]) == nil)
    #expect(UsageAlerts.pending(snapshot: value, threshold: 80, delivered: [], now: dates[1]).isEmpty)
    #expect(value.timelineDates(from: dates[1]) == [dates[1]])
}

@Test func widgetChangesQuotaAtResetAndProviderExpiry() {
    let value = UsageSnapshot(version: 1, generatedAt: now, totals: [], providers: [
        .init(id: "codex", name: "Codex", available: true, updatedAt: now, totals: [], quotas: [
            .init(id: "session", label: "Session", usedPercent: 95, resetsAt: now.addingTimeInterval(120))
        ]),
        .init(id: "claude", name: "Claude", available: true, updatedAt: now.addingTimeInterval(-1_500), totals: [], quotas: [
            .init(id: "weekly", label: "Weekly", usedPercent: 70, resetsAt: nil)
        ])
    ])
    let dates = value.timelineDates(from: now)
    #expect(dates == [now, now.addingTimeInterval(120), now.addingTimeInterval(300), now.addingTimeInterval(1_800)])
    #expect(value.highestActiveQuota(at: dates[0])?.label == "Codex · Session")
    #expect(value.highestActiveQuota(at: dates[1])?.label == "Claude · Weekly")
    #expect(value.highestActiveQuota(at: dates[2]) == nil)
    #expect(value.highestActiveQuota(at: dates[3]) == nil)
}
