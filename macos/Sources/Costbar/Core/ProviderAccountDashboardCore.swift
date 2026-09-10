import CostbarKit
import Foundation

protocol AccountUsageCore: Sendable {
    func snapshot(period: Dashboard.Period) throws -> Dashboard
    func cachedSnapshot(period: Dashboard.Period, cacheKey: String?) throws -> Dashboard?
    func refresh(_ request: CoreRefreshRequest) async throws -> CostbarCore.RefreshReport
}

extension CostbarCore: AccountUsageCore {}

@MainActor
final class ProviderAccountDashboardCore {
    private struct AccountRequest: Sendable {
        let type: ProviderAccountType
        let account: ProviderAccount
    }

    private struct Outcome: Sendable {
        let account: ProviderAccount
        let report: Dashboard.ProviderReport
        let configuredCount: Int
        let refreshedCount: Int
        let error: String?
    }

    private struct CodexRequest: Sendable {
        let account: VisibleCodexAccount?
        let homePath: String
        let cacheKey: String
        var id: String { account.map { "codex/\($0.id)" } ?? "codex" }
        var displayName: String { account.map { "Codex · \($0.displayName)" } ?? "Codex" }

        func identified(_ report: Dashboard.ProviderReport) -> Dashboard.ProviderReport {
            if account != nil && report.summary.status == .notConfigured {
                return unavailable("Usage is unavailable. Check this account’s sign-in on your Mac.")
            }
            return report.replacingSummary(report.summary.identified(id: id, displayName: displayName, sourceID: "codex"))
        }

        func unavailable(_ message: String) -> Dashboard.ProviderReport {
            .placeholder(summary: .init(id: id, displayName: displayName, sourceID: "codex",
                kind: "developer_tool", status: .unavailable, errorMessage: message,
                currency: "", currentCostMicros: 0, projectedCostMicros: nil,
                creditRemainingMicros: nil, contributesToTotals: false, updatedAtUnix: 0))
        }
    }

    private struct CodexOutcome: Sendable {
        let target: CodexRequest
        let report: Dashboard.ProviderReport
        let configuredCount: Int
        let refreshedCount: Int
        let error: String?
    }

    private struct MutableTotal {
        let currency: String
        var current: Int64
        var projected: Int64?
        var credit: Int64?
        var projectionComplete: Bool
        var creditComplete: Bool
    }

    private let localCore: any AccountUsageCore
    private let loadCodexAccounts: () throws -> CodexAccountSnapshot
    private let coreFactory: () throws -> any AccountUsageCore
    private var codexCores: [String: any AccountUsageCore] = [:]
    private var accountCores: [String: any AccountUsageCore] = [:]
    private var latestDashboard: Dashboard?

    init(
        loadCodexAccounts: @escaping () throws -> CodexAccountSnapshot = { try CodexAccountManager().snapshot() },
        coreFactory: @escaping () throws -> any AccountUsageCore = { try CostbarCore() }
    ) throws {
        localCore = try coreFactory()
        self.loadCodexAccounts = loadCodexAccounts
        self.coreFactory = coreFactory
    }

    func cachedSnapshot(
        period: Dashboard.Period,
        accountData: [ProviderAccountData]
    ) throws -> Dashboard? {
        var reports: [Dashboard.ProviderReport] = []
        for request in Self.accountRequests(in: accountData) {
            let account = request.account
            let core = try accountCore(for: account.id)
            guard let cached = try core.cachedSnapshot(
                period: period,
                cacheKey: account.id
            ), let report = cached.providers.first(where: {
                $0.summary.providerTypeID == request.type.sourceID
            }) else { continue }
            reports.append(report.identified(as: account, type: request.type))
        }
        if let targets = try? codexRequests() {
            for target in targets {
                let core = try codexCore(for: target.id)
                if let cached = try core.cachedSnapshot(period: period, cacheKey: target.cacheKey),
                   let report = cached.providers.first(where: { $0.summary.providerTypeID == "codex" && $0.summary.status != .notConfigured }) {
                    reports.append(target.identified(report))
                }
            }
        }
        if let cachedLocal = try localCore.cachedSnapshot(
            period: period,
            cacheKey: "local-v1"
        ) {
            reports.append(contentsOf: cachedLocal.providers.filter {
                $0.summary.providerTypeID != LocalSource.codex.sourceID &&
                    LocalSource.allSourceIDs.contains($0.summary.providerTypeID) &&
                    $0.summary.status != .notConfigured
            })
        }
        if reports.isEmpty,
           let legacy = try localCore.cachedSnapshot(period: period, cacheKey: nil) {
            var migratedTypes: Set<ProviderAccountType> = []
            for request in Self.accountRequests(in: accountData) {
                guard migratedTypes.insert(request.type).inserted else { continue }
                if let report = legacy.providers.first(where: {
                    $0.summary.providerTypeID == request.type.sourceID
                }) {
                    reports.append(report.identified(as: request.account, type: request.type))
                }
            }
            reports.append(contentsOf: legacy.providers.filter {
                LocalSource.allSourceIDs.contains($0.summary.providerTypeID) &&
                    $0.summary.status != .notConfigured
            })
        }
        guard !reports.isEmpty else { return nil }
        let cached = Self.dashboard(
            period: period,
            generatedAtUnix: reports.map(\.summary.updatedAtUnix).max() ?? 0,
            reports: reports
        )
        latestDashboard = cached
        return cached
    }

    func snapshot(period: Dashboard.Period) throws -> Dashboard {
        if let latestDashboard,
           latestDashboard.period.startUnix == period.startUnix,
           latestDashboard.period.endExclusiveUnix == period.endExclusiveUnix {
            return latestDashboard
        }
        let base = try localCore.snapshot(period: period)
        var reports = base.providers.filter {
            LocalSource.allSourceIDs.contains($0.summary.providerTypeID)
        }
        if let targets = try? codexRequests() {
            reports.removeAll { $0.summary.providerTypeID == "codex" }
            for target in targets {
                let core = try codexCore(for: target.id)
                if let report = try core.snapshot(period: period).providers.first(where: { $0.summary.providerTypeID == "codex" }) {
                    reports.append(target.identified(report))
                }
            }
        }
        return Self.dashboard(period: period, generatedAtUnix: base.generatedAtUnix, reports: reports)
    }

    func refresh(_ request: DashboardRefreshRequest) async throws -> CostbarCore.RefreshReport {
        let allAccounts = Self.accountRequests(in: request.accountData)
        let selectedAccounts = allAccounts.filter { account in
            request.sourceIDs?.contains(account.type.sourceID) ?? true
        }
        if request.sourceIDs == nil {
            let currentIDs = Set(allAccounts.map(\.account.id))
            accountCores = accountCores.filter { currentIDs.contains($0.key) }
        }
        for request in selectedAccounts where accountCores[request.account.id] == nil {
            _ = try accountCore(for: request.account.id)
        }

        var outcomes: [Outcome] = []
        await withTaskGroup(of: Outcome.self) { group in
            for accountRequest in selectedAccounts {
                guard let core = accountCores[accountRequest.account.id] else { continue }
                group.addTask {
                    await Self.refresh(accountRequest, using: core, request: request)
                }
            }
            for await outcome in group {
                outcomes.append(outcome)
            }
        }

        var configuredCount = outcomes.reduce(0) { $0 + $1.configuredCount }
        var refreshedCount = outcomes.reduce(0) { $0 + $1.refreshedCount }
        var errors = outcomes.compactMap(\.error)
        var replacements = Dictionary(uniqueKeysWithValues: outcomes.map {
            ($0.account.id, $0.report)
        })

        let selectedLocalSources = Set(LocalSource.allCases.filter { source in
            request.sourceIDs?.contains(source.sourceID) ?? true
        })
        var codexTargets: [CodexRequest]?
        if selectedLocalSources.contains(.codex), request.trackedLocalSources.contains(.codex) {
            do {
                let targets = try codexRequests()
                codexTargets = targets
                let currentIDs = Set(targets.map(\.id))
                codexCores = codexCores.filter { currentIDs.contains($0.key) }
                var collectors: [(CodexRequest, any AccountUsageCore)] = []
                for target in targets { collectors.append((target, try codexCore(for: target.id))) }
                await withTaskGroup(of: CodexOutcome.self) { group in
                    for (target, core) in collectors {
                        group.addTask { await Self.refreshCodex(target, using: core, request: request) }
                    }
                    for await outcome in group {
                        configuredCount += outcome.configuredCount
                        refreshedCount += outcome.refreshedCount
                        if let error = outcome.error { errors.append(error) }
                        replacements[outcome.target.id] = outcome.report
                    }
                }
            } catch {
                errors.append("Codex: \(error.localizedDescription)")
            }
        }

        let selectedOtherLocalSources = selectedLocalSources.subtracting([.codex])
        if !selectedOtherLocalSources.isEmpty {
            let selectedOtherLocalIDs = Set(selectedOtherLocalSources.map(\.sourceID))
            do {
                let localResult = try await localCore.refresh(.init(
                    credentials: .empty,
                    period: request.period,
                    trackedLocalSources: request.trackedLocalSources.subtracting([.codex]),
                    useGitHubCLI: false,
                    codexHome: nil,
                    codexAccountID: nil,
                    sourceIDs: selectedOtherLocalIDs,
                    writesCache: true,
                    cacheKey: "local-v1"
                ))
                configuredCount += localResult.configuredCount
                refreshedCount += localResult.refreshedCount
                if let error = localResult.errors { errors.append(error) }
                let local = try localCore.snapshot(period: request.period)
                for report in local.providers
                    where selectedOtherLocalIDs.contains(report.summary.providerTypeID) {
                    replacements[report.id] = report
                }
            } catch {
                errors.append("Local accounts: \(error.localizedDescription)")
            }
        }

        let previous = Dictionary(uniqueKeysWithValues: (latestDashboard?.providers ?? []).map {
            ($0.id, $0)
        })
        var reports = allAccounts.map { accountRequest in
            let account = accountRequest.account
            return replacements[account.id] ?? previous[account.id] ?? Self.placeholder(
                for: account,
                type: accountRequest.type
            )
        }
        if request.trackedLocalSources.contains(.codex) {
            if let targets = codexTargets {
                for target in targets {
                    reports.append(replacements[target.id] ?? previous[target.id] ?? target.unavailable("Usage has not refreshed yet."))
                }
            } else {
                reports.append(contentsOf: (latestDashboard?.providers ?? []).filter { $0.summary.providerTypeID == "codex" })
            }
        } else if request.sourceIDs == nil {
            codexCores.removeAll()
            reports.append(Self.localPlaceholder(.codex))
        }
        for source in LocalSource.allCases where source != .codex {
            if let report = replacements[source.sourceID] ?? previous[source.sourceID] {
                reports.append(report)
            } else if request.sourceIDs == nil {
                reports.append(Self.localPlaceholder(source))
            }
        }

        latestDashboard = Self.dashboard(
            period: request.period,
            generatedAtUnix: Int64(Date.now.timeIntervalSince1970),
            reports: reports
        )
        return .init(
            configuredCount: configuredCount,
            refreshedCount: refreshedCount,
            errors: errors.isEmpty ? nil : errors.joined(separator: "\n")
        )
    }

    private nonisolated static func refresh(
        _ accountRequest: AccountRequest,
        using core: any AccountUsageCore,
        request: DashboardRefreshRequest
    ) async -> Outcome {
        let account = accountRequest.account
        let type = accountRequest.type
        do {
            let result = try await core.refresh(.init(
                credentials: account.credentials(for: type),
                period: request.period,
                trackedLocalSources: [],
                useGitHubCLI: account.usesGitHubCLI,
                codexHome: nil,
                codexAccountID: nil,
                sourceIDs: [type.sourceID],
                writesCache: true,
                cacheKey: account.id
            ))
            let dashboard = try core.snapshot(period: request.period)
            guard let source = dashboard.providers.first(where: {
                $0.summary.providerTypeID == type.sourceID
            }) else {
                return .init(
                    account: account,
                    report: placeholder(
                        for: account,
                        type: type,
                        error: "Missing provider report"
                    ),
                    configuredCount: result.configuredCount,
                    refreshedCount: result.refreshedCount,
                    error: "\(account.displayName): missing provider report"
                )
            }
            return .init(
                account: account,
                report: source.identified(as: account, type: type),
                configuredCount: result.configuredCount,
                refreshedCount: result.refreshedCount,
                error: result.errors.map { "\(account.displayName): \($0)" }
            )
        } catch {
            return .init(
                account: account,
                report: placeholder(for: account, type: type, error: error.localizedDescription),
                configuredCount: 0,
                refreshedCount: 0,
                error: "\(account.displayName): \(error.localizedDescription)"
            )
        }
    }

    private nonisolated static func placeholder(
        for account: ProviderAccount,
        type: ProviderAccountType,
        error: String? = nil
    ) -> Dashboard.ProviderReport {
        .placeholder(summary: .init(
            id: account.id,
            displayName: account.displayName,
            sourceID: type.sourceID,
            kind: type.dashboardKind,
            status: error == nil ? .notConfigured : .unavailable,
            errorMessage: error,
            currency: "",
            currentCostMicros: 0,
            projectedCostMicros: nil,
            creditRemainingMicros: nil,
            contributesToTotals: true,
            updatedAtUnix: 0
        ))
    }

    private static func localPlaceholder(_ source: LocalSource) -> Dashboard.ProviderReport {
        .placeholder(summary: .init(
            id: source.sourceID,
            displayName: source.displayName,
            sourceID: source.sourceID,
            kind: "developer_tool",
            status: .notConfigured,
            errorMessage: nil,
            currency: "",
            currentCostMicros: 0,
            projectedCostMicros: nil,
            creditRemainingMicros: nil,
            contributesToTotals: false,
            updatedAtUnix: 0
        ))
    }

    private static func dashboard(
        period: Dashboard.Period,
        generatedAtUnix: Int64,
        reports: [Dashboard.ProviderReport]
    ) -> Dashboard {
        var totals: [MutableTotal] = []
        for report in reports
            where report.summary.status == .available && report.summary.contributesToTotals {
            if report.financials.isEmpty {
                add(
                    currency: report.summary.currency,
                    current: report.summary.currentCostMicros,
                    projected: report.summary.projectedCostMicros,
                    credit: report.summary.creditRemainingMicros,
                    to: &totals
                )
            } else {
                for financial in report.financials {
                    add(
                        currency: financial.currency,
                        current: financial.currentCostMicros,
                        projected: financial.projectedCostMicros,
                        credit: financial.creditRemainingMicros,
                        to: &totals
                    )
                }
            }
        }
        return Dashboard(
            period: period,
            generatedAtUnix: generatedAtUnix,
            totals: totals.map {
                .init(
                    currency: $0.currency,
                    currentCostMicros: $0.current,
                    projectedCostMicros: $0.projected,
                    creditRemainingMicros: $0.credit,
                    projectionComplete: $0.projectionComplete,
                    creditComplete: $0.creditComplete
                )
            },
            providers: reports
        )
    }

    private static func add(
        currency: String,
        current: Int64,
        projected: Int64?,
        credit: Int64?,
        to totals: inout [MutableTotal]
    ) {
        guard !currency.isEmpty else { return }
        if let index = totals.firstIndex(where: { $0.currency == currency }) {
            totals[index].current = totals[index].current.saturatingAdding(current)
            if let projected {
                totals[index].projected = (totals[index].projected ?? 0).saturatingAdding(projected)
            } else {
                totals[index].projectionComplete = false
            }
            if let credit {
                totals[index].credit = (totals[index].credit ?? 0).saturatingAdding(credit)
            } else {
                totals[index].creditComplete = false
            }
        } else {
            totals.append(.init(
                currency: currency,
                current: current,
                projected: projected,
                credit: credit,
                projectionComplete: projected != nil,
                creditComplete: credit != nil
            ))
        }
    }

    private func accountCore(for id: String) throws -> any AccountUsageCore {
        if let core = accountCores[id] { return core }
        let core = try coreFactory()
        accountCores[id] = core
        return core
    }

    private func codexCore(for id: String) throws -> any AccountUsageCore {
        if let core = codexCores[id] { return core }
        let core = try coreFactory()
        codexCores[id] = core
        return core
    }

    private func codexRequests() throws -> [CodexRequest] {
        let snapshot = try loadCodexAccounts()
        guard !snapshot.accounts.isEmpty else {
            return [.init(account: nil, homePath: snapshot.ambientHomePath, cacheKey: "codex-system")]
        }
        let ordered = snapshot.activeAccount.map { selected in
            [selected] + snapshot.accounts.filter { $0.id != selected.id }
        } ?? snapshot.accounts
        return ordered.map { .init(account: $0, homePath: $0.homePath, cacheKey: $0.cacheKey) }
    }

    private nonisolated static func refreshCodex(
        _ target: CodexRequest, using core: any AccountUsageCore, request: DashboardRefreshRequest
    ) async -> CodexOutcome {
        do {
            let result = try await core.refresh(.init(credentials: .empty, period: request.period,
                trackedLocalSources: [.codex], useGitHubCLI: false, codexHome: target.homePath,
                codexAccountID: target.account?.accountID, sourceIDs: ["codex"],
                writesCache: true, cacheKey: target.cacheKey))
            guard let report = try core.snapshot(period: request.period).providers.first(where: { $0.summary.providerTypeID == "codex" }) else {
                throw CostbarCoreError.missingPayload
            }
            return .init(target: target, report: target.identified(report), configuredCount: result.configuredCount,
                         refreshedCount: result.refreshedCount, error: result.errors.map { "\(target.displayName): \($0)" })
        } catch {
            return .init(target: target, report: target.unavailable(error.localizedDescription), configuredCount: 1,
                         refreshedCount: 0, error: "\(target.displayName): \(error.localizedDescription)")
        }
    }

    private static func accountRequests(
        in providerData: [ProviderAccountData]
    ) -> [AccountRequest] {
        providerData.flatMap { data in
            let active = data.activeAccount
            let ordered = active.map { selected in
                [selected] + data.accounts.filter { $0.id != selected.id }
            }
                ?? data.accounts
            return ordered.map { AccountRequest(type: data.type, account: $0) }
        }
    }
}

private extension Dashboard.ProviderReport {
    func identified(
        as account: ProviderAccount,
        type: ProviderAccountType
    ) -> Dashboard.ProviderReport {
        replacingSummary(summary.identified(
            id: account.id,
            displayName: account.displayName,
            sourceID: type.sourceID
        ))
    }
}
