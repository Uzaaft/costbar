import Foundation
import Testing
@testable import Costbar

private let codexTestTimestamp = Int64(Date.now.timeIntervalSince1970)

@MainActor
@Suite
struct CodexMultiAccountTests {
    private let period = Dashboard.Period(startUnix: 1_800_000_000, endExclusiveUnix: 1_802_592_000)
    private let now = Date(timeIntervalSince1970: Double(codexTestTimestamp))

    private func account(_ number: Int) -> VisibleCodexAccount {
        .init(id: "managed-\(number)", email: "account\(number)@example.com", accountID: "workspace-\(number)",
              workspaceLabel: "Workspace \(number)", homePath: "/test/codex-\(number)",
              managedAccountID: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(number)"),
              isSystem: number == 1, isActive: number == 1)
    }

    private func accounts(_ values: [VisibleCodexAccount], active: String? = nil) -> CodexAccountSnapshot {
        .init(accounts: values, activeAccountID: active ?? values.first?.id,
              systemAccountID: values.first?.id, ambientHomePath: "/test/system")
    }

    @Test func refreshesAndSyncsBothAccountsWithIsolatedUsageAndAlertIdentities() async throws {
        let first = account(1), second = account(2)
        let recorder = CodexRefreshRecorder()
        let core = try ProviderAccountDashboardCore(loadCodexAccounts: { accounts([first, second]) },
            coreFactory: { FakeAccountUsageCore(recorder: recorder) })
        let result = try await core.refresh(.init(accountData: [], period: period, trackedLocalSources: [.codex], sourceIDs: ["codex"]))
        #expect(result.refreshedCount == 2)
        let requests = recorder.requests
        #expect(Set(requests.compactMap(\.codexHome)) == [first.homePath, second.homePath])
        #expect(Set(requests.compactMap(\.codexAccountID)) == ["workspace-1", "workspace-2"])
        #expect(Set(requests.compactMap(\.cacheKey)) == [first.cacheKey, second.cacheKey])
        let dashboard = try core.snapshot(period: period)
        let phone = UsageSnapshot(dashboard: dashboard)
        #expect(phone.providers.map(\.id) == ["codex/managed-1", "codex/managed-2"])
        #expect(phone.providers.map { $0.quotas.first?.usedPercent } == [85, 95])
        #expect(phone.providers[0].name.contains(first.displayName))
        #expect(phone.providers[1].name.contains(second.displayName))
        let alerts = UsageAlerts.pending(snapshot: phone, threshold: 80, delivered: [], now: now)
        #expect(alerts.count == 2)
        #expect(Set(alerts.map(\.id)).count == 2)
        let delivered = try #require(alerts.first?.id)
        #expect(UsageAlerts.pending(snapshot: phone, threshold: 80, delivered: [delivered], now: now).count == 1)
    }

    @Test func cacheLoadsBothAccountsAndActiveSelectionOnlyChangesTheirOrder() async throws {
        let first = account(1), second = account(2)
        var current = accounts([first, second])
        let recorder = CodexRefreshRecorder()
        let core = try ProviderAccountDashboardCore(loadCodexAccounts: { current },
            coreFactory: { FakeAccountUsageCore(recorder: recorder) })
        let cached = try #require(try core.cachedSnapshot(period: period, accountData: []))
        #expect(cached.providers.map(\.id) == ["codex/managed-1", "codex/managed-2"])
        current = accounts([first, second], active: second.id)
        _ = try await core.refresh(.init(accountData: [], period: period, trackedLocalSources: [.codex], sourceIDs: ["codex"]))
        #expect(try core.snapshot(period: period).providers.map(\.id) == ["codex/managed-2", "codex/managed-1"])
        // A refresh of an unrelated source must retain both accounts.
        _ = try await core.refresh(.init(accountData: [], period: period, trackedLocalSources: [.codex], sourceIDs: []))
        #expect(try core.snapshot(period: period).providers.map(\.id) == ["codex/managed-2", "codex/managed-1"])
        current = accounts([second])
        _ = try await core.refresh(.init(accountData: [], period: period, trackedLocalSources: [.codex], sourceIDs: ["codex"]))
        #expect(try core.snapshot(period: period).providers.map(\.id) == ["codex/managed-2"])
    }

    @Test func failedAccountRemainsVisibleWithoutHidingHealthyAccount() async throws {
        let first = account(1), second = account(2)
        let recorder = CodexRefreshRecorder()
        let core = try ProviderAccountDashboardCore(loadCodexAccounts: { accounts([first, second]) },
            coreFactory: { FakeAccountUsageCore(recorder: recorder, failingHome: second.homePath) })
        _ = try await core.refresh(.init(accountData: [], period: period, trackedLocalSources: [.codex], sourceIDs: ["codex"]))
        let phone = UsageSnapshot(dashboard: try core.snapshot(period: period))
        #expect(phone.providers.count == 2)
        #expect(phone.providers.map(\.available) == [true, false])
        #expect(phone.providers[0].quotas.first?.usedPercent == 85)
        #expect(phone.providers[1].quotas.isEmpty)
        #expect(phone.providers.filter(\.showsAllowances).count == 2)
    }
}

private final class CodexRefreshRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CoreRefreshRequest] = []
    var requests: [CoreRefreshRequest] { lock.withLock { stored } }
    func record(_ request: CoreRefreshRequest) { lock.withLock { stored.append(request) } }
}

private final class FakeAccountUsageCore: AccountUsageCore, @unchecked Sendable {
    private let recorder: CodexRefreshRecorder
    private let failingHome: String?
    private let lock = NSLock()
    private var latestRequest: CoreRefreshRequest?

    init(recorder: CodexRefreshRecorder, failingHome: String? = nil) {
        self.recorder = recorder
        self.failingHome = failingHome
    }

    func refresh(_ request: CoreRefreshRequest) async throws -> CostbarCore.RefreshReport {
        recorder.record(request)
        if request.codexHome == failingHome && failingHome != nil { throw CocoaError(.fileReadNoPermission) }
        lock.withLock { latestRequest = request }
        return .init(configuredCount: 1, refreshedCount: 1, errors: nil)
    }

    func snapshot(period: Dashboard.Period) throws -> Dashboard {
        let home = lock.withLock { latestRequest?.codexHome }
        return fixture(period: period, second: home?.hasSuffix("2") == true)
    }

    func cachedSnapshot(period: Dashboard.Period, cacheKey: String?) throws -> Dashboard? {
        guard let cacheKey, cacheKey.hasPrefix("codex-") else { return nil }
        return fixture(period: period, second: cacheKey.hasSuffix("2"))
    }

    private func fixture(period: Dashboard.Period, second: Bool) -> Dashboard {
        let summary = Dashboard.ProviderSummary(id: "codex", displayName: "Codex", kind: "developer_tool",
            status: .available, errorMessage: nil, currency: "", currentCostMicros: 0,
            projectedCostMicros: nil, creditRemainingMicros: nil, contributesToTotals: false,
            updatedAtUnix: codexTestTimestamp)
        let report = Dashboard.ProviderReport(summary: summary, resources: [], lineItems: [],
            allowanceWindows: [.init(id: "weekly", label: "7 day", usedPercent: second ? 95 : 85,
                resetsAtUnix: codexTestTimestamp + 600, durationMinutes: 10_080, detail: nil)],
            tokenUsage: nil, tokenUsageWindows: [], tokenUsageSeries: [], spendSeries: [], financials: [])
        return Dashboard(period: period, generatedAtUnix: codexTestTimestamp, totals: [], providers: [report])
    }
}
