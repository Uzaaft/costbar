const std = @import("std");

pub const Period = struct {
    start_unix: i64,
    end_exclusive_unix: i64,

    pub fn validate(self: Period) !void {
        if (self.end_exclusive_unix <= self.start_unix) {
            return error.InvalidPeriod;
        }
    }
};

pub const ProviderKind = enum {
    cloud,
    ai,
    developer_tool,
    other,
};

pub const ProviderMetadata = struct {
    id: []const u8,
    display_name: []const u8,
    kind: ProviderKind,
};

pub const ProviderStatus = enum {
    available,
    not_configured,
    unavailable,
};

pub const ResourceStatus = enum {
    active,
    inactive,
    warning,
    unknown,
};

pub const Resource = struct {
    id: []const u8,
    name: []const u8,
    kind: []const u8,
    status: ResourceStatus,
    quantity: u64 = 1,
};

pub const CostLineItem = struct {
    id: []const u8,
    description: []const u8,
    /// Group this item belongs to, usually the billed product ("Droplets").
    service: []const u8,
    /// One million micros equals one whole currency unit. A fixed six-decimal
    /// representation preserves metered cloud costs without floating point.
    amount_micros: i64,
    /// Present when a report can contain more than one currency. Single-
    /// currency providers inherit the currency from their summary.
    currency: ?[]const u8 = null,
    /// Optional secondary label, e.g. "744 Hours" or "monthly · Paid".
    detail: ?[]const u8 = null,
};

pub const FinancialSummary = struct {
    currency: []const u8,
    current_cost_micros: i64,
    projected_cost_micros: ?i64 = null,
    credit_remaining_micros: ?i64 = null,
};

/// A provider-defined rolling allowance such as a five-hour coding-agent
/// window or a weekly model quota. Percentages are deliberately independent
/// of token totals: subscription vendors can weight models, tools, and cached
/// context differently when consuming an allowance.
pub const AllowanceWindow = struct {
    id: []const u8,
    label: []const u8,
    used_percent: f64,
    resets_at_unix: ?i64 = null,
    detail: ?[]const u8 = null,
};

/// Token counts observed for a provider over one explicit period. These may be
/// authoritative API totals or local-only session-log totals; `source` makes
/// that distinction visible instead of presenting estimates as billing data.
pub const TokenUsage = struct {
    period: Period,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_creation_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,
    source: []const u8,
    updated_at_unix: i64,

    pub fn total(self: TokenUsage) u64 {
        var result = self.input_tokens;
        result +|= self.output_tokens;
        result +|= self.cache_read_tokens;
        result +|= self.cache_creation_tokens;
        result +|= self.reasoning_tokens;
        return result;
    }
};

/// A named rolling slice of the same local token history as `TokenUsage`.
/// Providers can expose comparable windows without leaking their log schema
/// into the dashboard or native UI.
pub const TokenUsageWindow = struct {
    id: []const u8,
    label: []const u8,
    period: Period,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_creation_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,

    pub fn total(self: TokenUsageWindow) u64 {
        var result = self.input_tokens;
        result +|= self.output_tokens;
        result +|= self.cache_read_tokens;
        result +|= self.cache_creation_tokens;
        result +|= self.reasoning_tokens;
        return result;
    }
};

/// One bucket in a token history series. Periods are explicit so consumers can
/// label rolling windows without knowing how the provider grouped its data.
pub const TokenUsageBucket = struct {
    period: Period,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_creation_tokens: u64 = 0,
    reasoning_tokens: u64 = 0,

    pub fn total(self: TokenUsageBucket) u64 {
        var result = self.input_tokens;
        result +|= self.output_tokens;
        result +|= self.cache_read_tokens;
        result +|= self.cache_creation_tokens;
        result +|= self.reasoning_tokens;
        return result;
    }
};

/// A fixed-resolution history matching one selectable local-usage window.
pub const TokenUsageSeries = struct {
    id: []const u8,
    label: []const u8,
    period: Period,
    buckets: []TokenUsageBucket,
};

/// One provider usage bucket in an explicit period. `amount_micros` carries
/// billed spend while `usage_quantity` optionally carries a provider-native
/// volume used to visualize activity that has no charge.
pub const SpendBucket = struct {
    period: Period,
    amount_micros: i64,
    usage_quantity: u64 = 0,
};

/// Provider-reported spend history at a provider-defined resolution.
pub const SpendSeries = struct {
    id: []const u8,
    label: []const u8,
    currency: []const u8,
    period: Period,
    buckets: []SpendBucket,
};

pub const ProviderSummary = struct {
    id: []const u8,
    display_name: []const u8,
    kind: ProviderKind,
    status: ProviderStatus = .available,
    error_message: ?[]const u8 = null,
    currency: []const u8,
    current_cost_micros: i64,
    projected_cost_micros: ?i64 = null,
    credit_remaining_micros: ?i64 = null,
    /// False for usage-only providers that do not expose billable cost.
    contributes_to_totals: bool = true,
    updated_at_unix: i64,
};

/// A provider allocates the two slices with the allocator supplied to
/// `Provider.collect`. Strings are borrowed from the provider and must remain
/// valid until this report is released.
pub const ProviderReport = struct {
    summary: ProviderSummary,
    resources: []Resource,
    line_items: []CostLineItem,
    allowance_windows: []AllowanceWindow = &.{},
    token_usage: ?TokenUsage = null,
    token_usage_windows: []TokenUsageWindow = &.{},
    token_usage_series: []TokenUsageSeries = &.{},
    spend_series: []SpendSeries = &.{},
    /// Optional multi-currency financial values. When empty, the legacy
    /// financial fields on `summary` remain authoritative.
    financials: []FinancialSummary = &.{},

    pub fn deinit(self: ProviderReport, allocator: std.mem.Allocator) void {
        allocator.free(self.resources);
        allocator.free(self.line_items);
        if (self.allowance_windows.len > 0) allocator.free(self.allowance_windows);
        if (self.token_usage_windows.len > 0) allocator.free(self.token_usage_windows);
        for (self.token_usage_series) |series| {
            if (series.buckets.len > 0) allocator.free(series.buckets);
        }
        if (self.token_usage_series.len > 0) allocator.free(self.token_usage_series);
        for (self.spend_series) |series| {
            if (series.buckets.len > 0) allocator.free(series.buckets);
        }
        if (self.spend_series.len > 0) allocator.free(self.spend_series);
        if (self.financials.len > 0) allocator.free(self.financials);
    }
};

pub const CurrencyTotal = struct {
    currency: []const u8,
    current_cost_micros: i64,
    projected_cost_micros: ?i64,
    credit_remaining_micros: ?i64,
    projection_complete: bool,
    credit_complete: bool,
};

pub const Dashboard = struct {
    period: Period,
    generated_at_unix: i64,
    totals: []CurrencyTotal,
    providers: []ProviderReport,

    pub fn deinit(self: Dashboard, allocator: std.mem.Allocator) void {
        for (self.providers) |report| report.deinit(allocator);
        allocator.free(self.providers);
        allocator.free(self.totals);
    }
};

test "period rejects an empty interval" {
    try std.testing.expectError(error.InvalidPeriod, (Period{
        .start_unix = 10,
        .end_exclusive_unix = 10,
    }).validate());
}

test "token usage totals every token class without overflow" {
    const usage = TokenUsage{
        .period = .{ .start_unix = 1, .end_exclusive_unix = 2 },
        .input_tokens = std.math.maxInt(u64),
        .output_tokens = 1,
        .source = "local",
        .updated_at_unix = 1,
    };
    try std.testing.expectEqual(std.math.maxInt(u64), usage.total());
}
