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
        pollingInterval: .seconds(60),
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
func dashboardStorePollsAfterItsInitialBackgroundRefresh() async throws {
    let refreshed = dashboardFixture(generatedAtUnix: 456)
    let core = StubDashboardCore(cached: nil, snapshot: refreshed)
    let store = DashboardStore(
        credentials: StubDashboardCredentials(),
        pollingInterval: .milliseconds(10),
        coreFactory: { core }
    )
    defer { store.stopPolling() }

    for _ in 0 ..< 100 where core.refreshCount < 2 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(core.refreshCount >= 2)
    #expect(store.dashboard?.generatedAtUnix == 456)
}

private enum StubError: Error {
    case refreshFailed
}

@MainActor
private final class StubDashboardCredentials: DashboardCredentials {
    func load() throws -> ProviderCredentials { .empty }
}

@MainActor
private final class StubDashboardCore: DashboardCore {
    let cached: Dashboard?
    let snapshotValue: Dashboard
    var refreshCount = 0
    var refreshError: (any Error)?

    init(cached: Dashboard?, snapshot: Dashboard) {
        self.cached = cached
        snapshotValue = snapshot
    }

    func cachedSnapshot(period _: Dashboard.Period) throws -> Dashboard? {
        cached
    }

    func snapshot(period _: Dashboard.Period) throws -> Dashboard {
        snapshotValue
    }

    func refresh(
        credentials _: ProviderCredentials,
        period _: Dashboard.Period,
        trackCodex _: Bool,
        trackClaude _: Bool,
        trackOpenCode _: Bool,
        useGitHubCLI _: Bool
    ) async throws -> CostbarCore.RefreshReport {
        refreshCount += 1
        if let refreshError { throw refreshError }
        return .init(configuredCount: 0, refreshedCount: 0, errors: nil)
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
