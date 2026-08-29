import CostbarKit
import Foundation

// Reads the flat, index-addressed snapshot the Zig core exposes into the
// Swift `Dashboard` value tree. Every accessor is checked; a failure anywhere
// aborts the whole snapshot rather than yielding a partial dashboard.

extension Dashboard {
    /// Decodes a whole snapshot handle. Only valid while the handle is alive.
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
                durationMinutes: value.duration_minutes.optional,
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
        let tokenUsageSeries = try (0..<Int(provider.token_usage_series_count)).map { seriesIndex in
            try Dashboard.TokenUsageSeries(
                snapshot: snapshot,
                providerIndex: index,
                index: seriesIndex
            )
        }
        let spendSeries = try (0..<Int(provider.spend_series_count)).map { seriesIndex in
            try Dashboard.SpendSeries(
                snapshot: snapshot,
                providerIndex: index,
                index: seriesIndex
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
                sourceID: provider.id.string,
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
            tokenUsageSeries: tokenUsageSeries,
            spendSeries: spendSeries,
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

private extension Dashboard.TokenUsageSeries {
    init(snapshot: OpaquePointer, providerIndex: Int, index: Int) throws {
        var value = costbar_token_usage_series_view_t()
        try check(costbar_snapshot_token_usage_series(snapshot, providerIndex, index, &value))
        let buckets = try (0..<Int(value.bucket_count)).map { bucketIndex in
            var bucket = costbar_token_usage_bucket_view_t()
            try check(
                costbar_snapshot_token_usage_bucket(
                    snapshot,
                    providerIndex,
                    index,
                    bucketIndex,
                    &bucket
                )
            )
            return Dashboard.TokenUsageBucket(
                period: .init(
                    startUnix: bucket.period_start_unix,
                    endExclusiveUnix: bucket.period_end_exclusive_unix
                ),
                inputTokens: bucket.input_tokens,
                outputTokens: bucket.output_tokens,
                cacheReadTokens: bucket.cache_read_tokens,
                cacheCreationTokens: bucket.cache_creation_tokens,
                reasoningTokens: bucket.reasoning_tokens
            )
        }
        self.init(
            id: value.id.string,
            label: value.label.string,
            period: .init(
                startUnix: value.period_start_unix,
                endExclusiveUnix: value.period_end_exclusive_unix
            ),
            buckets: buckets
        )
    }
}

private extension Dashboard.SpendSeries {
    init(snapshot: OpaquePointer, providerIndex: Int, index: Int) throws {
        var value = costbar_spend_series_view_t()
        try check(costbar_snapshot_spend_series(snapshot, providerIndex, index, &value))
        let buckets = try (0..<Int(value.bucket_count)).map { bucketIndex in
            var bucket = costbar_spend_bucket_view_t()
            try check(
                costbar_snapshot_spend_bucket(
                    snapshot,
                    providerIndex,
                    index,
                    bucketIndex,
                    &bucket
                )
            )
            return Dashboard.SpendBucket(
                period: .init(
                    startUnix: bucket.period_start_unix,
                    endExclusiveUnix: bucket.period_end_exclusive_unix
                ),
                amountMicros: bucket.amount_micros,
                usageQuantity: bucket.usage_quantity
            )
        }
        self.init(
            id: value.id.string,
            label: value.label.string,
            currency: value.currency.string,
            period: .init(
                startUnix: value.period_start_unix,
                endExclusiveUnix: value.period_end_exclusive_unix
            ),
            buckets: buckets
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
