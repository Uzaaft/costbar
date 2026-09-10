import Foundation
import Testing
@testable import Costbar

@Suite
struct HeadlineWindowTests {
    @Test func claudeKeepsTheSessionWindowWhenWeeklyIsFirst() {
        let report = report(
            type: "claude",
            windows: [
                window(id: "weekly_all", percent: 90),
                window(id: "session", percent: 12),
            ]
        )
        #expect(report.headlineWindow?.id == "session")
        #expect(report.headlineWindow?.usedPercent == 12)
    }

    @Test func missingSessionDoesNotPromoteWeekly() {
        let report = report(
            type: "claude",
            windows: [window(id: "weekly_all", percent: 90)]
        )
        #expect(report.headlineWindow == nil)
    }

    @Test func cursorLocalPrefersAutoOverIncluded() {
        let report = report(
            type: "cursor-local",
            windows: [
                window(id: "included", percent: 40),
                window(id: "auto", percent: 9.5),
            ]
        )
        #expect(report.headlineWindow?.id == "auto")
    }

    @Test func hottestQuotaIsTheTightestAgentWindowNotTheHeadline() {
        let dashboard = Dashboard(
            period: .init(startUnix: 1, endExclusiveUnix: 2),
            generatedAtUnix: 1,
            totals: [
                .init(
                    currency: "USD",
                    currentCostMicros: 40_830_000,
                    projectedCostMicros: nil,
                    creditRemainingMicros: nil,
                    projectionComplete: false,
                    creditComplete: false
                ),
            ],
            providers: [
                report(type: "codex", windows: [
                    window(id: "primary", percent: 12),
                    window(id: "secondary", percent: 100),
                ]),
                report(type: "claude", windows: [
                    window(id: "session", percent: 1),
                    window(id: "weekly_all", percent: 61),
                ]),
            ]
        )
        #expect(dashboard.hottestAgentQuota?.usedPercent == 100)
        #expect(dashboard.menuBarTitle(for: .codex) == "100%")
        #expect(dashboard.menuBarTitle(for: .claude) == "61%")
        #expect(dashboard.menuBarTitle(for: .cost).contains("$"))
        #expect(!dashboard.menuBarTitle(for: .cost).contains("%"))
    }

    @Test func menuBarClaudeTitleIsDashWithoutClaudeQuota() {
        let dashboard = Dashboard(
            period: .init(startUnix: 1, endExclusiveUnix: 2),
            generatedAtUnix: 1,
            totals: [],
            providers: [report(type: "codex", windows: [window(id: "primary", percent: 42)])]
        )
        #expect(dashboard.menuBarTitle(for: .claude) == "—")
        #expect(dashboard.menuBarTitle(for: .codex) == "42%")
        #expect(dashboard.menuBarTitle(for: .cost) == "—")
    }

    @MainActor
    @Test func menuBarSettingsRememberTheChosenMetric() {
        let suite = "com.costbar.tests.menubar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MenuBarSettingsStore(defaults: defaults)
        #expect(store.metric == .cost)
        store.metric = .claude
        #expect(MenuBarSettingsStore(defaults: defaults).metric == .claude)
    }

    @Test func codingAgentReportsPreferCursorLocal() {
        let local = report(type: "cursor-local", windows: [window(id: "auto", percent: 10)])
        let team = report(type: "cursor", windows: [])
        let dashboard = Dashboard(
            period: .init(startUnix: 1, endExclusiveUnix: 2),
            generatedAtUnix: 1,
            totals: [],
            providers: [team, local]
        )
        #expect(CodingAgent.reports(in: dashboard).map(\.summary.providerTypeID) == ["cursor-local"])
    }

    private func window(id: String, percent: Double) -> Dashboard.AllowanceWindow {
        .init(id: id, label: id, usedPercent: percent, resetsAtUnix: nil, durationMinutes: 300, detail: nil)
    }

    private func report(type: String, windows: [Dashboard.AllowanceWindow]) -> Dashboard.ProviderReport {
        .init(
            summary: .init(
                id: type,
                displayName: type,
                sourceID: type,
                kind: "ai",
                status: .available,
                errorMessage: nil,
                currency: "USD",
                currentCostMicros: 0,
                projectedCostMicros: nil,
                creditRemainingMicros: nil,
                contributesToTotals: false,
                updatedAtUnix: 1
            ),
            resources: [],
            lineItems: [],
            allowanceWindows: windows,
            tokenUsage: nil,
            tokenUsageWindows: [],
            tokenUsageSeries: [],
            spendSeries: [],
            financials: []
        )
    }
}
