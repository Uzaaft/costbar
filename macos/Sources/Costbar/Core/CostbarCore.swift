import CostbarKit
import Foundation

enum CostbarCoreError: Error, LocalizedError {
    case incompatibleABI(expected: UInt32, actual: UInt32)
    case initializationFailed
    case snapshotFailed(costbar_status_t)
    case settingFailed(key: String, status: costbar_status_t)
    case refreshFailed(costbar_status_t)
    case githubCLIOrganizationDiscoveryFailed(costbar_status_t)
    case missingPayload

    var errorDescription: String? {
        switch self {
        case let .incompatibleABI(expected, actual):
            "Core ABI mismatch (expected \(expected), found \(actual))."
        case .initializationFailed:
            "The Costbar core could not be initialized."
        case let .snapshotFailed(status):
            "The Costbar core returned status \(status.rawValue)."
        case let .settingFailed(key, status):
            "Could not configure \(key) (status \(status.rawValue))."
        case let .refreshFailed(status):
            "Could not refresh the Zig core (status \(status.rawValue))."
        case let .githubCLIOrganizationDiscoveryFailed(status):
            "Could not read organizations from GitHub CLI (status \(status.rawValue))."
        case .missingPayload:
            "The Costbar core returned an empty snapshot."
        }
    }
}

/// One refresh pass through the Zig core.
struct CoreRefreshRequest: Sendable {
    let credentials: ProviderCredentials
    let period: Dashboard.Period
    let trackedLocalSources: Set<LocalSource>
    let useGitHubCLI: Bool
    let codexHome: String?
    let codexAccountID: String?
    let sourceIDs: Set<String>?
    let writesCache: Bool
    let cacheKey: String?
    var cursorSession: String? = nil

    func tracks(_ source: LocalSource) -> UInt8 {
        trackedLocalSources.contains(source) ? 1 : 0
    }
}

final class CostbarCore: @unchecked Sendable {
    struct RefreshReport: Sendable {
        let configuredCount: Int
        let refreshedCount: Int
        let errors: String?
    }

    private let handle: OpaquePointer
    private let lock = NSLock()

    init() throws {
        let actualABI = costbar_abi_version()
        guard actualABI == COSTBAR_ABI_VERSION else {
            throw CostbarCoreError.incompatibleABI(
                expected: COSTBAR_ABI_VERSION,
                actual: actualABI
            )
        }
        guard let handle = costbar_core_create() else {
            throw CostbarCoreError.initializationFailed
        }
        self.handle = handle
    }

    deinit {
        costbar_core_destroy(handle)
    }

    static func githubCLIOrganizations() async throws -> [String] {
        try await Task.detached(priority: .utility) {
            var value = costbar_bytes_t(ptr: nil, len: 0)
            let status = costbar_github_cli_organizations(&value)
            guard status == COSTBAR_STATUS_OK else {
                throw CostbarCoreError.githubCLIOrganizationDiscoveryFailed(status)
            }
            defer { costbar_bytes_free(value) }
            guard let pointer = value.ptr else { return [] }
            let raw = String(
                bytes: UnsafeBufferPointer(start: pointer, count: value.len),
                encoding: .utf8
            ) ?? ""
            return raw.split(whereSeparator: \.isNewline).map(String.init)
        }.value
    }

    func snapshot(period: Dashboard.Period) throws -> Dashboard {
        lock.lock()
        defer { lock.unlock() }

        var snapshot: OpaquePointer?
        let status = costbar_core_snapshot_create(
            handle,
            period.startUnix,
            period.endExclusiveUnix,
            &snapshot
        )
        guard status == COSTBAR_STATUS_OK else {
            throw CostbarCoreError.snapshotFailed(status)
        }
        guard let snapshot else { throw CostbarCoreError.missingPayload }
        defer { costbar_snapshot_destroy(snapshot) }
        return try Dashboard(snapshot: snapshot)
    }

    func cachedSnapshot(
        period: Dashboard.Period,
        cacheKey: String? = nil
    ) throws -> Dashboard? {
        lock.lock()
        defer { lock.unlock() }

        var snapshot: OpaquePointer?
        let status: costbar_status_t
        if let cacheKey {
            let key = Data(cacheKey.utf8)
            status = key.withUnsafeBytes { buffer in
                costbar_core_cached_account_snapshot_create(
                    handle,
                    buffer.costbarBytes,
                    period.startUnix,
                    period.endExclusiveUnix,
                    &snapshot
                )
            }
        } else {
            status = costbar_core_cached_snapshot_create(
                handle,
                period.startUnix,
                period.endExclusiveUnix,
                &snapshot
            )
        }
        if status == COSTBAR_STATUS_UNSUPPORTED { return nil }
        guard status == COSTBAR_STATUS_OK else {
            throw CostbarCoreError.snapshotFailed(status)
        }
        guard let snapshot else { throw CostbarCoreError.missingPayload }
        defer { costbar_snapshot_destroy(snapshot) }
        return try Dashboard(snapshot: snapshot)
    }

    func refresh(_ request: CoreRefreshRequest) async throws -> RefreshReport {
        try await Task.detached(priority: .utility) { [self] in
            try refreshSynchronously(request)
        }.value
    }

    private func refreshSynchronously(_ request: CoreRefreshRequest) throws -> RefreshReport {
        lock.lock()
        defer { lock.unlock() }

        let settings = request.credentials.coreSettings + [
            ("codex.home", request.codexHome),
            ("codex.account-id", request.codexAccountID),
            ("cursor-local.enabled", request.tracks(.cursor) == 1 ? "1" : "0"),
            ("cursor-local.session", request.cursorSession),
        ]
        for (key, value) in settings {
            let keyData = Data(key.utf8)
            let valueData = Data((value ?? "").utf8)
            let status = keyData.withUnsafeBytes { keyBuffer in
                valueData.withUnsafeBytes { valueBuffer in
                    costbar_core_set_setting(
                        handle,
                        keyBuffer.costbarBytes,
                        valueBuffer.costbarBytes
                    )
                }
            }
            guard status == COSTBAR_STATUS_OK else {
                throw CostbarCoreError.settingFailed(key: key, status: status)
            }
        }

        var result = costbar_refresh_result_t(
            configured_count: 0,
            refreshed_count: 0,
            errors: costbar_bytes_t(ptr: nil, len: 0)
        )
        let sourceList = request.sourceIDs?.sorted().joined(separator: "\n") ?? ""
        let sourceData = Data(sourceList.utf8)
        let cacheKeyData = Data((request.cacheKey ?? "").utf8)
        let status = sourceData.withUnsafeBytes { sourceBuffer in
            cacheKeyData.withUnsafeBytes { cacheKeyBuffer in
                costbar_core_refresh(
                    handle,
                    costbar_refresh_options_t(
                        period_start_unix: request.period.startUnix,
                        period_end_exclusive_unix: request.period.endExclusiveUnix,
                        track_codex: request.tracks(.codex),
                        track_claude: request.tracks(.claude),
                        track_opencode: request.tracks(.opencode),
                        use_github_cli: request.useGitHubCLI ? 1 : 0,
                        has_source_filter: request.sourceIDs == nil ? 0 : 1,
                        write_cache: request.writesCache ? 1 : 0,
                        source_ids: sourceBuffer.costbarBytes,
                        cache_key: cacheKeyBuffer.costbarBytes
                    ),
                    &result
                )
            }
        }
        guard status == COSTBAR_STATUS_OK else {
            throw CostbarCoreError.refreshFailed(status)
        }
        defer { costbar_bytes_free(result.errors) }
        let errors = result.errors.ptr.flatMap {
            String(
                bytes: UnsafeBufferPointer(start: $0, count: result.errors.len),
                encoding: .utf8
            )
        }
        return RefreshReport(
            configuredCount: Int(result.configured_count),
            refreshedCount: Int(result.refreshed_count),
            errors: errors
        )
    }
}

/// Fans a provider's normal refresh path out across its configured accounts.
/// Each account gets an isolated core so credential overrides never bleed into
/// another account's request or cache.
