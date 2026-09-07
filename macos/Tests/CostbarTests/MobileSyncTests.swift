import Foundation
import Testing
@testable import Costbar

@Suite
struct MobileSyncTests {
    private func report(contributes: Bool = true, available: Bool = true, financials: [Dashboard.FinancialSummary] = []) -> Dashboard.ProviderReport {
        let summary = Dashboard.ProviderSummary(
            id: "runpod", displayName: "Runpod", kind: "metered",
            status: available ? .available : .unavailable, errorMessage: nil,
            currency: "USD", currentCostMicros: 23_180_000, projectedCostMicros: 99_810_000,
            creditRemainingMicros: nil, contributesToTotals: contributes, updatedAtUnix: 1_800_000_000
        )
        return .init(summary: summary, resources: [], lineItems: [], allowanceWindows: [], tokenUsage: nil,
                     tokenUsageWindows: [], tokenUsageSeries: [], spendSeries: [], financials: financials)
    }

    private func mobile(_ report: Dashboard.ProviderReport) throws -> UsageSnapshot.Provider {
        let snapshot = UsageSnapshot(dashboard: Dashboard(
            period: .init(startUnix: 1_800_000_000, endExclusiveUnix: 1_802_592_000),
            generatedAtUnix: 1_800_000_000, totals: [], providers: [report]
        ))
        return try #require(snapshot.providers.first)
    }

    @Test func preservesSingleCurrencySummary() throws {
        let provider = try mobile(report())
        #expect(provider.totals.first?.micros == 23_180_000)
        #expect(provider.totals.first?.projectedMicros == 99_810_000)
    }

    @Test func keepsExplicitCurrencyBreakdownWithoutDuplicatingSummary() throws {
        let provider = try mobile(report(financials: [
            .init(currency: "EUR", currentCostMicros: 7_000_000, projectedCostMicros: nil, creditRemainingMicros: nil),
            .init(currency: "USD", currentCostMicros: 9_000_000, projectedCostMicros: nil, creditRemainingMicros: nil)
        ]))
        #expect(provider.totals.map(\.currency) == ["EUR", "USD"])
        #expect(provider.totals.map(\.micros) == [7_000_000, 9_000_000])
    }

    @Test func doesNotInventCostsForAgentsOrUnavailableSummaries() throws {
        #expect(try mobile(report(contributes: false)).totals.isEmpty)
        #expect(try mobile(report(available: false)).totals.isEmpty)
    }
}
