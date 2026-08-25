import CostbarKit
import Foundation

enum CostbarCoreError: Error, LocalizedError {
    case incompatibleABI(expected: UInt32, actual: UInt32)
    case initializationFailed
    case snapshotFailed(costbar_status_t)
    case settingFailed(key: String, status: costbar_status_t)
    case refreshFailed(costbar_status_t)
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
        case .missingPayload:
            "The Costbar core returned an empty snapshot."
        }
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

    func cachedSnapshot(period: Dashboard.Period) throws -> Dashboard? {
        lock.lock()
        defer { lock.unlock() }

        var snapshot: OpaquePointer?
        let status = costbar_core_cached_snapshot_create(
            handle,
            period.startUnix,
            period.endExclusiveUnix,
            &snapshot
        )
        if status == COSTBAR_STATUS_UNSUPPORTED { return nil }
        guard status == COSTBAR_STATUS_OK else {
            throw CostbarCoreError.snapshotFailed(status)
        }
        guard let snapshot else { throw CostbarCoreError.missingPayload }
        defer { costbar_snapshot_destroy(snapshot) }
        return try Dashboard(snapshot: snapshot)
    }

    func refresh(
        credentials: ProviderCredentials,
        period: Dashboard.Period,
        trackCodex: Bool,
        trackClaude: Bool,
        trackOpenCode: Bool,
        useGitHubCLI: Bool
    ) async throws -> RefreshReport {
        try await Task.detached(priority: .utility) { [self] in
            try refreshSynchronously(
                credentials: credentials,
                period: period,
                trackCodex: trackCodex,
                trackClaude: trackClaude,
                trackOpenCode: trackOpenCode,
                useGitHubCLI: useGitHubCLI
            )
        }.value
    }

    private func refreshSynchronously(
        credentials: ProviderCredentials,
        period: Dashboard.Period,
        trackCodex: Bool,
        trackClaude: Bool,
        trackOpenCode: Bool,
        useGitHubCLI: Bool
    ) throws -> RefreshReport {
        lock.lock()
        defer { lock.unlock() }

        for (key, value) in credentials.coreSettings {
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
        let status = costbar_core_refresh(
            handle,
            costbar_refresh_options_t(
                period_start_unix: period.startUnix,
                period_end_exclusive_unix: period.endExclusiveUnix,
                track_codex: trackCodex ? 1 : 0,
                track_claude: trackClaude ? 1 : 0,
                track_opencode: trackOpenCode ? 1 : 0,
                use_github_cli: useGitHubCLI ? 1 : 0
            ),
            &result
        )
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

private extension Dashboard {
    init(snapshot: OpaquePointer) throws {
        var header = costbar_snapshot_header_t()
        try check(costbar_snapshot_header(snapshot, &header))

        let totals = try (0..<Int(header.total_count)).map { index in
            var value = costbar_currency_total_view_t()
            try check(costbar_snapshot_total(snapshot, index, &value))
            return CurrencyTotal(
                currency: value.currency.string,
                currentCostMicros: value.current_cost_micros,
                projectedCostMicros: value.projected_cost_micros.optional,
                creditRemainingMicros: value.credit_remaining_micros.optional,
                projectionComplete: value.projection_complete != 0,
                creditComplete: value.credit_complete != 0
            )
        }
        let providers = try (0..<Int(header.provider_count)).map { index in
            try ProviderReport(snapshot: snapshot, index: index)
        }
        self.init(
            period: .init(
                startUnix: header.period_start_unix,
                endExclusiveUnix: header.period_end_exclusive_unix
            ),
            generatedAtUnix: header.generated_at_unix,
            totals: totals,
            providers: providers
        )
    }
}

private extension Dashboard.ProviderReport {
    init(snapshot: OpaquePointer, index: Int) throws {
        var provider = costbar_provider_view_t()
        try check(costbar_snapshot_provider(snapshot, index, &provider))
        let resources = try (0..<Int(provider.resource_count)).map { resourceIndex in
            var value = costbar_resource_view_t()
            try check(costbar_snapshot_resource(snapshot, index, resourceIndex, &value))
            return Dashboard.Resource(
                id: value.id.string,
                name: value.name.string,
                kind: value.kind.string,
                status: value.status.string,
                quantity: value.quantity
            )
        }
        let lineItems = try (0..<Int(provider.line_item_count)).map { itemIndex in
            var value = costbar_cost_line_item_view_t()
            try check(costbar_snapshot_line_item(snapshot, index, itemIndex, &value))
            return Dashboard.CostLineItem(
                id: value.id.string,
                description: value.description.string,
                service: value.service.string,
                amountMicros: value.amount_micros,
                currency: value.has_currency == 0 ? nil : value.currency.string,
                detail: value.has_detail == 0 ? nil : value.detail.string
            )
        }
        let allowances = try (0..<Int(provider.allowance_count)).map { allowanceIndex in
            var value = costbar_allowance_view_t()
            try check(costbar_snapshot_allowance(snapshot, index, allowanceIndex, &value))
            return Dashboard.AllowanceWindow(
                id: value.id.string,
                label: value.label.string,
                usedPercent: value.used_percent,
                resetsAtUnix: value.resets_at_unix.optional,
                detail: value.has_detail == 0 ? nil : value.detail.string
            )
        }
        let tokenUsage: Dashboard.TokenUsage? = if provider.has_token_usage != 0 {
            try Dashboard.TokenUsage(snapshot: snapshot, providerIndex: index)
        } else {
            nil
        }
        let tokenUsageWindows = try (0..<Int(provider.token_usage_window_count)).map { windowIndex in
            try Dashboard.TokenUsageWindow(
                snapshot: snapshot,
                providerIndex: index,
                index: windowIndex
            )
        }
        let financials = try (0..<Int(provider.financial_count)).map { financialIndex in
            var value = costbar_financial_view_t()
            try check(costbar_snapshot_financial(snapshot, index, financialIndex, &value))
            return Dashboard.FinancialSummary(
                currency: value.currency.string,
                currentCostMicros: value.current_cost_micros,
                projectedCostMicros: value.projected_cost_micros.optional,
                creditRemainingMicros: value.credit_remaining_micros.optional
            )
        }
        self.init(
            summary: .init(
                id: provider.id.string,
                displayName: provider.display_name.string,
                kind: provider.kind.string,
                status: .init(rawValue: provider.status.string) ?? .unavailable,
                errorMessage: provider.has_error_message == 0 ? nil : provider.error_message.string,
                currency: provider.currency.string,
                currentCostMicros: provider.current_cost_micros,
                projectedCostMicros: provider.projected_cost_micros.optional,
                creditRemainingMicros: provider.credit_remaining_micros.optional,
                contributesToTotals: provider.contributes_to_totals != 0,
                updatedAtUnix: provider.updated_at_unix
            ),
            resources: resources,
            lineItems: lineItems,
            allowanceWindows: allowances,
            tokenUsage: tokenUsage,
            tokenUsageWindows: tokenUsageWindows,
            financials: financials
        )
    }
}

private extension Dashboard.TokenUsage {
    init(snapshot: OpaquePointer, providerIndex: Int) throws {
        var value = costbar_token_usage_view_t()
        try check(costbar_snapshot_token_usage(snapshot, providerIndex, &value))
        self.init(
            period: .init(
                startUnix: value.period_start_unix,
                endExclusiveUnix: value.period_end_exclusive_unix
            ),
            inputTokens: value.input_tokens,
            outputTokens: value.output_tokens,
            cacheReadTokens: value.cache_read_tokens,
            cacheCreationTokens: value.cache_creation_tokens,
            reasoningTokens: value.reasoning_tokens,
            source: value.source.string,
            updatedAtUnix: value.updated_at_unix
        )
    }
}

private extension Dashboard.TokenUsageWindow {
    init(snapshot: OpaquePointer, providerIndex: Int, index: Int) throws {
        var value = costbar_token_usage_window_view_t()
        try check(costbar_snapshot_token_usage_window(snapshot, providerIndex, index, &value))
        self.init(
            id: value.id.string,
            label: value.label.string,
            period: .init(
                startUnix: value.period_start_unix,
                endExclusiveUnix: value.period_end_exclusive_unix
            ),
            inputTokens: value.input_tokens,
            outputTokens: value.output_tokens,
            cacheReadTokens: value.cache_read_tokens,
            cacheCreationTokens: value.cache_creation_tokens,
            reasoningTokens: value.reasoning_tokens
        )
    }
}

private func check(_ status: costbar_status_t) throws {
    guard status == COSTBAR_STATUS_OK else {
        throw CostbarCoreError.snapshotFailed(status)
    }
}

private extension costbar_bytes_t {
    var string: String {
        guard let ptr, len > 0 else { return "" }
        return String(bytes: UnsafeBufferPointer(start: ptr, count: len), encoding: .utf8) ?? ""
    }
}

private extension costbar_optional_i64_t {
    var optional: Int64? { present == 0 ? nil : value }
}

private extension ProviderCredentials {
    var coreSettings: [(String, String?)] {
        [
            ("digitalocean.token", digitalOceanToken),
            ("ovh.endpoint", ovhEndpoint),
            ("ovh.application-key", ovhApplicationKey),
            ("ovh.application-secret", ovhApplicationSecret),
            ("ovh.consumer-key", ovhConsumerKey),
            ("ovh.project-id", ovhProjectID),
            ("hetzner.token", hetznerToken),
            ("cloudflare.token", cloudflareToken),
            ("cloudflare.account-id", cloudflareAccountID),
            ("runpod.api-key", runpodAPIKey),
            ("vercel.token", vercelToken),
            ("vercel.team", vercelTeamIDOrSlug),
            ("openrouter.api-key", openRouterAPIKey),
            ("openrouter.management-key", openRouterManagementKey),
            ("openai.admin-key", openAIAdminKey),
            ("anthropic.admin-key", anthropicAdminKey),
            ("github.token", githubToken),
            ("github.organization", githubOrganization),
            ("cursor.admin-key", cursorAdminKey),
        ]
    }
}

private extension UnsafeRawBufferPointer {
    var costbarBytes: costbar_bytes_t {
        costbar_bytes_t(
            ptr: bindMemory(to: UInt8.self).baseAddress,
            len: count
        )
    }
}
