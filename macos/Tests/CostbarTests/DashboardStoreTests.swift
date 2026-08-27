import Foundation
import Testing
@testable import Costbar

@Test
func githubCLIAuthenticationIsExplicitlyOptIn() throws {
    let suite = "com.costbar.tests.cli-auth.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(!CLIAuthSettings.usesGitHubCLI(defaults: defaults))
    CLIAuthSettings.saveGitHubCLI(true, defaults: defaults)
    #expect(CLIAuthSettings.usesGitHubCLI(defaults: defaults))
}

@MainActor
@Test
func dashboardStorePublishesTheZigCacheBeforeRefreshing() throws {
    let cached = dashboardFixture(generatedAtUnix: 123)
    let core = StubDashboardCore(cached: cached, snapshot: cached)
    let store = DashboardStore(
        credentials: StubDashboardCredentials(),
        automaticallyRefreshes: false,
        coreFactory: { core }
    )

    #expect(store.dashboard?.generatedAtUnix == 123)
    #expect(store.dataSourceLabel == "cached")
    #expect(store.lastUpdatedAt == Date(timeIntervalSince1970: 123))
}

@MainActor
@Test
func dashboardStorePreservesCachedDataWhenBackgroundRefreshFails() async throws {
    let cached = dashboardFixture(generatedAtUnix: 123)
    let core = StubDashboardCore(cached: cached, snapshot: cached)
    core.refreshError = StubError.refreshFailed
    let store = DashboardStore(
        credentials: StubDashboardCredentials(),
        pollingSchedule: { .uniform(.seconds(60)) },
        coreFactory: { core }
    )
    defer { store.stopPolling() }

    try await Task.sleep(for: .milliseconds(30))
    #expect(store.dashboard?.generatedAtUnix == 123)
    #expect(store.dataSourceLabel == "stale")
    #expect(store.lastUpdatedAt == Date(timeIntervalSince1970: 123))
}

@MainActor
@Test
func dashboardStoreDoesNotReplaceCachedCostsWithTokenOnlyRefresh() async throws {
    let cached = dashboardFixture(generatedAtUnix: 123)
    let tokenOnly = Dashboard(
        period: .currentMonth(),
        generatedAtUnix: 456,
        totals: [],
        providers: []
    )
    let core = StubDashboardCore(cached: cached, snapshot: tokenOnly)
    core.refreshReport = .init(configuredCount: 2, refreshedCount: 2, errors: nil)
    let store = DashboardStore(
        credentials: StubDashboardCredentials(),
        pollingSchedule: { .uniform(.seconds(60)) },
        coreFactory: { core }
    )
    defer { store.stopPolling() }

    for _ in 0 ..< 100 where core.refreshCount == 0 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(store.dashboard?.generatedAtUnix == 123)
    #expect(store.dataSourceLabel == "stale")
    #expect(store.lastUpdatedAt == Date(timeIntervalSince1970: 123))
    #expect(store.errorMessage?.contains("showing the last cached overview") == true)
}

@MainActor
@Test
func dashboardStorePollsAfterItsInitialBackgroundRefresh() async throws {
    let refreshed = dashboardFixture(generatedAtUnix: 456)
    let core = StubDashboardCore(cached: nil, snapshot: refreshed)
    let store = DashboardStore(
        credentials: StubDashboardCredentials(),
        pollingSchedule: { .uniform(.milliseconds(10)) },
        coreFactory: { core }
    )
    defer { store.stopPolling() }

    for _ in 0 ..< 100 where core.refreshCount < 2 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(core.refreshCount >= 2)
    #expect(store.dashboard?.generatedAtUnix == 456)
    #expect(core.sourceSelections[0] == nil)
    #expect(core.sourceSelections.dropFirst().contains { selection in
        selection == Set(PollingSource.all.map(\.id))
    })
}

@Test
func pollingSettingsPersistDefaultAndSparseOverrides() throws {
    let suite = "com.costbar.tests.polling.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(PollingSettings.defaultInterval(defaults: defaults) == 300)
    #expect(PollingSettings.overrides(defaults: defaults).isEmpty)

    PollingSettings.save(
        defaultInterval: 900,
        overrides: ["codex": 60, "hetzner": 3_600, "unknown": 300],
        defaults: defaults
    )

    #expect(PollingSettings.defaultInterval(defaults: defaults) == 900)
    #expect(PollingSettings.overrides(defaults: defaults) == [
        "codex": 60,
        "hetzner": 3_600,
    ])
    let schedule = PollingSettings.schedule(defaults: defaults)
    #expect(schedule.intervals["codex"] == .seconds(60))
    #expect(schedule.intervals["hetzner"] == .seconds(3_600))
    #expect(schedule.intervals["digitalocean"] == .seconds(900))
}

@MainActor
@Test
func pollingGroupsOnlyTheSourcesThatAreDue() async throws {
    let refreshed = dashboardFixture(generatedAtUnix: 789)
    let core = StubDashboardCore(cached: nil, snapshot: refreshed)
    let store = DashboardStore(
        credentials: StubDashboardCredentials(),
        pollingSchedule: {
            .init(intervals: [
            "codex": .milliseconds(10),
            "hetzner": .milliseconds(30),
            ])
        },
        coreFactory: { core }
    )
    defer { store.stopPolling() }

    for _ in 0 ..< 100 where core.sourceSelections.count < 4 {
        try await Task.sleep(for: .milliseconds(10))
    }

    let selections = core.sourceSelections.dropFirst().compactMap { $0 }
    #expect(selections.count >= 3)
    #expect(selections[0].contains("codex"))
    #expect(selections.contains { $0.contains("hetzner") })
}

private enum StubError: Error {
    case refreshFailed
}

@MainActor
private final class StubDashboardCredentials: DashboardCredentials {
    func loadAccountData() throws -> [ProviderAccountData] { [] }
}

@MainActor
private final class StubDashboardCore: DashboardCore {
    let cached: Dashboard?
    let snapshotValue: Dashboard
    var refreshCount = 0
    var refreshError: (any Error)?
    var refreshReport = CostbarCore.RefreshReport(
        configuredCount: 0,
        refreshedCount: 0,
        errors: nil
    )
    var sourceSelections: [Set<String>?] = []

    init(cached: Dashboard?, snapshot: Dashboard) {
        self.cached = cached
        snapshotValue = snapshot
    }

    func cachedSnapshot(
        period _: Dashboard.Period,
        accountData _: [ProviderAccountData]
    ) throws -> Dashboard? {
        cached
    }

    func snapshot(period _: Dashboard.Period) throws -> Dashboard {
        snapshotValue
    }

    func refresh(_ request: DashboardRefreshRequest) async throws -> CostbarCore.RefreshReport {
        refreshCount += 1
        sourceSelections.append(request.sourceIDs)
        if let refreshError { throw refreshError }
        return refreshReport
    }
}

private func dashboardFixture(generatedAtUnix: Int64) -> Dashboard {
    Dashboard(
        period: .currentMonth(),
        generatedAtUnix: generatedAtUnix,
        totals: [
            .init(
                currency: "USD",
                currentCostMicros: 1_000_000,
                projectedCostMicros: nil,
                creditRemainingMicros: nil,
                projectionComplete: false,
                creditComplete: false
            ),
        ],
        providers: []
    )
}
