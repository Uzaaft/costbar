import Foundation

@MainActor
protocol DashboardCore: AnyObject {
    func cachedSnapshot(period: Dashboard.Period) throws -> Dashboard?
    func snapshot(period: Dashboard.Period) throws -> Dashboard
    func refresh(
        credentials: ProviderCredentials,
        period: Dashboard.Period,
        trackCodex: Bool,
        trackClaude: Bool,
        trackOpenCode: Bool,
        useGitHubCLI: Bool
    ) async throws -> CostbarCore.RefreshReport
}

extension CostbarCore: DashboardCore {}

@MainActor
protocol DashboardCredentials: AnyObject {
    func load() throws -> ProviderCredentials
}

extension CredentialStore: DashboardCredentials {}

@MainActor
final class DashboardStore: ObservableObject {
    @Published private(set) var dashboard: Dashboard?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var dataSourceLabel = "not configured"
    @Published private(set) var lastUpdatedAt: Date?

    private var core: (any DashboardCore)?
    private let credentials: any DashboardCredentials
    private let pollingInterval: Duration
    private var refreshTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?

    init(
        credentials: any DashboardCredentials = CredentialStore(),
        pollingInterval: Duration = .seconds(300),
        automaticallyRefreshes: Bool = true,
        coreFactory: () throws -> any DashboardCore = { try CostbarCore() }
    ) {
        self.credentials = credentials
        self.pollingInterval = pollingInterval
        do {
            let core = try coreFactory()
            self.core = core
            let period = Dashboard.Period.currentMonth()
            if let cached = try core.cachedSnapshot(period: period) {
                dashboard = cached
                dataSourceLabel = "cached"
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

    var menuBarTitle: String {
        guard let total = dashboard?.primaryTotal else { return "Costbar" }
        return total.currentCostMicros.currencyText(code: total.currency)
    }

    func refresh() {
        guard let core, !isRefreshing else { return }
        refreshTask?.cancel()
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await refresh(core: core)
        }
    }

    private func refresh(core: any DashboardCore) async {
        defer { isRefreshing = false }
        let period = Dashboard.Period.currentMonth()
        let hadDashboard = dashboard != nil
        var errors: [String] = []
        var configuredProviderCount = 0
        var refreshedProviderCount = 0
        var completedRefresh = false
        var saved: ProviderCredentials?

        do {
            saved = try credentials.load()
        } catch {
            errors.append(error.localizedDescription)
        }

        if let saved {
            do {
                let report = try await core.refresh(
                    credentials: saved,
                    period: period,
                    trackCodex: LocalAISettings.tracksCodex(),
                    trackClaude: LocalAISettings.tracksClaude(),
                    trackOpenCode: LocalAISettings.tracksOpenCode(),
                    useGitHubCLI: CLIAuthSettings.usesGitHubCLI()
                )
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
                (configuredProviderCount == 0 || refreshedProviderCount > 0)
        )
        if shouldPublishSnapshot {
            do {
                dashboard = try core.snapshot(period: period)
                lastUpdatedAt = .now
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        dataSourceLabel = if !completedRefresh {
            hadDashboard ? "stale" : "unavailable"
        } else if configuredProviderCount == 0 {
            "not configured"
        } else if refreshedProviderCount == configuredProviderCount {
            "live"
        } else {
            "stale"
        }
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private func startPolling() {
        pollingTask?.cancel()
        let interval = pollingInterval
        pollingTask = Task { [weak self] in
            await RefreshPolling.run(every: interval) { [weak self] in
                self?.refresh()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }
}

@MainActor
enum RefreshPolling {
    static func run(every interval: Duration, action: @escaping () -> Void) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            action()
        }
    }
}
