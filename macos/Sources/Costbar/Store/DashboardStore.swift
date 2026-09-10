import Foundation

struct DashboardRefreshRequest: Sendable {
    let accountData: [ProviderAccountData]
    let period: Dashboard.Period
    let trackedLocalSources: Set<LocalSource>
    /// The sources this refresh is limited to, or `nil` to refresh everything.
    let sourceIDs: Set<String>?
}

@MainActor
protocol DashboardCore: AnyObject {
    func cachedSnapshot(
        period: Dashboard.Period,
        accountData: [ProviderAccountData]
    ) throws -> Dashboard?
    func snapshot(period: Dashboard.Period) throws -> Dashboard
    func refresh(_ request: DashboardRefreshRequest) async throws -> CostbarCore.RefreshReport
}

extension ProviderAccountDashboardCore: DashboardCore {}

@MainActor
protocol DashboardCredentials: AnyObject {
    func loadAccountData() throws -> [ProviderAccountData]
}

extension CredentialStore: DashboardCredentials {}

/// Where the dashboard on screen came from, and so how far to trust it.
enum DashboardDataSource: Sendable {
    case notConfigured
    /// Read from the last run's cache; nothing fetched yet.
    case cached
    case live
    /// Some or all providers failed, so older figures are still showing.
    case stale
    case unavailable

    var label: String {
        switch self {
        case .notConfigured: "Not configured"
        case .cached: "Cached"
        case .live: "Live"
        case .stale: "Out of date"
        case .unavailable: "Unavailable"
        }
    }
}

@MainActor
final class DashboardStore: ObservableObject {
    @Published private(set) var dashboard: Dashboard?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var dataSource = DashboardDataSource.notConfigured
    @Published private(set) var lastUpdatedAt: Date?

    private var core: (any DashboardCore)?
    private let credentials: any DashboardCredentials
    private let pollingSchedule: () -> PollingSchedule
    private var refreshTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var refreshRequested = false
    private let publishSnapshot: (Dashboard) -> Void
    var activityBusy: () -> Bool

    init(
        credentials: any DashboardCredentials = CredentialStore(),
        pollingSchedule: @escaping () -> PollingSchedule = { PollingSettings.schedule() },
        automaticallyRefreshes: Bool = true,
        publishSnapshot: @escaping (Dashboard) -> Void = { MobileSyncStore.shared.publish($0) },
        activityBusy: @escaping () -> Bool = { false },
        coreFactory: () throws -> any DashboardCore = { try ProviderAccountDashboardCore() }
    ) {
        self.credentials = credentials
        self.pollingSchedule = pollingSchedule
        self.publishSnapshot = publishSnapshot
        self.activityBusy = activityBusy
        do {
            let core = try coreFactory()
            self.core = core
            let period = Dashboard.Period.currentMonth()
            let savedAccountData: [ProviderAccountData]
            do {
                savedAccountData = try credentials.loadAccountData()
            } catch {
                savedAccountData = []
                errorMessage = error.localizedDescription
            }
            if let cached = try core.cachedSnapshot(period: period, accountData: savedAccountData) {
                dashboard = cached
                dataSource = .cached
                lastUpdatedAt = Date(timeIntervalSince1970: TimeInterval(cached.generatedAtUnix))
            }
            if automaticallyRefreshes {
                refresh()
                startPolling()
            }
        } catch {
            core = nil
            errorMessage = error.localizedDescription
        }
    }

    func refresh() {
        guard let core else { return }
        guard !isRefreshing else {
            refreshRequested = true
            return
        }
        refreshTask?.cancel()
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await refresh(core: core, sourceIDs: nil)
        }
    }

    private func refresh(core: any DashboardCore, sourceIDs: Set<String>?) async {
        defer {
            isRefreshing = false
            if refreshRequested {
                refreshRequested = false
                refresh()
            }
        }
        let period = Dashboard.Period.currentMonth()
        let hadDashboard = dashboard != nil
        let isFullRefresh = sourceIDs == nil
        var errors: [String] = []
        var configuredProviderCount = 0
        var refreshedProviderCount = 0
        var completedRefresh = false
        var preservedCachedCosts = false
        var saved: [ProviderAccountData]?

        do {
            saved = try credentials.loadAccountData()
        } catch {
            errors.append(error.localizedDescription)
        }

        if let saved {
            do {
                let report = try await core.refresh(.init(
                    accountData: saved,
                    period: period,
                    trackedLocalSources: LocalAISettings.trackedSources(),
                    sourceIDs: sourceIDs
                ))
                completedRefresh = true
                configuredProviderCount = report.configuredCount
                refreshedProviderCount = report.refreshedCount
                if let message = report.errors { errors.append(message) }
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        let shouldPublishSnapshot = !hadDashboard || (
            completedRefresh &&
                (refreshedProviderCount > 0 ||
                    (isFullRefresh && configuredProviderCount == 0))
        )
        if shouldPublishSnapshot {
            do {
                let refreshedDashboard = try core.snapshot(period: period)
                if let currentDashboard = dashboard,
                   !currentDashboard.totals.isEmpty,
                   refreshedDashboard.totals.isEmpty {
                    preservedCachedCosts = true
                    errors.append(
                        "Cost providers returned no totals; showing the last cached overview."
                    )
                } else {
                    dashboard = refreshedDashboard
                    lastUpdatedAt = .now
                    publishSnapshot(refreshedDashboard)
                }
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        if preservedCachedCosts {
            dataSource = .stale
        } else if !completedRefresh {
            dataSource = hadDashboard ? .stale : .unavailable
        } else if configuredProviderCount == 0 {
            if isFullRefresh { dataSource = .notConfigured }
        } else if refreshedProviderCount == configuredProviderCount {
            dataSource = .live
        } else {
            dataSource = .stale
        }
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func pollingSettingsDidChange() {
        guard pollingTask != nil else { return }
        startPolling()
    }

    private func poll(sourceIDs: Set<String>) async {
        guard let core, !isRefreshing else { return }
        isRefreshing = true
        await refresh(core: core, sourceIDs: sourceIDs)
    }

    private func startPolling() {
        pollingTask?.cancel()
        let schedule = pollingSchedule().clampedForBusyLocalSources(activityBusy())
        pollingTask = Task { [weak self] in
            await RefreshPolling.run(schedule: schedule) { [weak self] sourceIDs in
                await self?.poll(sourceIDs: sourceIDs)
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}
