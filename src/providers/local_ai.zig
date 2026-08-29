const std = @import("std");
const model = @import("../model.zig");

pub fn LocalAI(
    comptime provider_id: []const u8,
    comptime provider_name: []const u8,
) type {
    return struct {
        const Self = @This();

        pub const TokenCounts = struct {
            input_tokens: u64 = 0,
            output_tokens: u64 = 0,
            cache_read_tokens: u64 = 0,
            cache_creation_tokens: u64 = 0,
            reasoning_tokens: u64 = 0,
        };

        pub const UsageWindow = struct {
            id: []const u8,
            label: []const u8,
            period: model.Period,
            token_usage: TokenCounts = .{},
        };

        pub const UsageBucket = struct {
            period: model.Period,
            token_usage: TokenCounts = .{},
        };

        pub const UsageSeries = struct {
            id: []const u8,
            label: []const u8,
            period: model.Period,
            buckets: []const UsageBucket,
        };

        pub const Allowance = struct {
            id: []const u8,
            label: []const u8,
            used_percent: f64,
            resets_at_unix: ?i64 = null,
            duration_minutes: ?i64 = null,
            detail: ?[]const u8 = null,
        };

        pub const Snapshot = struct {
            period: model.Period,
            token_usage: TokenCounts = .{},
            allowance_windows: []const Allowance = &.{},
            token_usage_windows: []const UsageWindow = &.{},
            token_usage_series: []const UsageSeries = &.{},
            models: []const []const u8 = &.{},
            source: []const u8,
            updated_at_unix: i64,
        };

        const OwnedSnapshot = struct {
            arena: std.heap.ArenaAllocator,
            period: model.Period,
            input_tokens: u64,
            output_tokens: u64,
            cache_read_tokens: u64,
            cache_creation_tokens: u64,
            reasoning_tokens: u64,
            source: []const u8,
            updated_at_unix: i64,
            allowances: []const RawAllowance,
            usage_windows: []const RawUsageWindow,
            usage_series: []const RawUsageSeries,
            models: []const []const u8,

            fn deinit(self: *OwnedSnapshot) void {
                self.arena.deinit();
            }
        };

        const RawAllowance = struct {
            id: []const u8,
            label: []const u8,
            used_percent: f64,
            resets_at_unix: ?i64 = null,
            duration_minutes: ?i64 = null,
            detail: ?[]const u8 = null,
        };

        const RawTokens = struct {
            input_tokens: u64 = 0,
            output_tokens: u64 = 0,
            cache_read_tokens: u64 = 0,
            cache_creation_tokens: u64 = 0,
            reasoning_tokens: u64 = 0,
        };

        const RawUsageWindow = struct {
            id: []const u8,
            label: []const u8,
            period: model.Period,
            token_usage: RawTokens = .{},
        };

        const RawUsageBucket = struct {
            period: model.Period,
            token_usage: RawTokens = .{},
        };

        const RawUsageSeries = struct {
            id: []const u8,
            label: []const u8,
            period: model.Period,
            buckets: []const RawUsageBucket = &.{},
        };

        const RawSnapshot = struct {
            period: model.Period,
            token_usage: RawTokens = .{},
            allowance_windows: []const RawAllowance = &.{},
            token_usage_windows: []const RawUsageWindow = &.{},
            token_usage_series: []const RawUsageSeries = &.{},
            models: []const []const u8 = &.{},
            source: []const u8,
            updated_at_unix: ?i64 = null,
        };

        snapshot: ?OwnedSnapshot = null,

        pub fn init() Self {
            return .{};
        }

        pub fn deinit(self: *Self) void {
            if (self.snapshot) |*snapshot| snapshot.deinit();
            self.snapshot = null;
        }

        pub fn metadata(_: *const Self) model.ProviderMetadata {
            return .{
                .id = provider_id,
                .display_name = provider_name,
                .kind = .ai,
            };
        }

        pub fn ingest(
            self: *Self,
            allocator: std.mem.Allocator,
            document_id: []const u8,
            payload: []const u8,
            received_at_unix: i64,
        ) !void {
            if (!std.mem.eql(u8, document_id, "usage")) {
                return error.UnsupportedDocument;
            }
            var replacement = try parseSnapshot(allocator, payload, received_at_unix);
            errdefer replacement.deinit();
            if (self.snapshot) |*existing| existing.deinit();
            self.snapshot = replacement;
        }

        /// Replaces local usage from already-normalized Zig data. This is the
        /// production path; JSON ingestion remains as a compatibility ABI.
        pub fn update(
            self: *Self,
            allocator: std.mem.Allocator,
            input: Snapshot,
        ) !void {
            try input.period.validate();
            var replacement = OwnedSnapshot{
                .arena = .init(allocator),
                .period = input.period,
                .input_tokens = input.token_usage.input_tokens,
                .output_tokens = input.token_usage.output_tokens,
                .cache_read_tokens = input.token_usage.cache_read_tokens,
                .cache_creation_tokens = input.token_usage.cache_creation_tokens,
                .reasoning_tokens = input.token_usage.reasoning_tokens,
                .source = undefined,
                .updated_at_unix = input.updated_at_unix,
                .allowances = undefined,
                .usage_windows = undefined,
                .usage_series = undefined,
                .models = undefined,
            };
            errdefer replacement.deinit();
            const arena = replacement.arena.allocator();
            replacement.source = try arena.dupe(u8, input.source);
            const models = try arena.alloc([]const u8, input.models.len);
            for (input.models, 0..) |name, index| {
                models[index] = try arena.dupe(u8, name);
            }
            replacement.models = models;
            const allowances = try arena.alloc(RawAllowance, input.allowance_windows.len);
            for (input.allowance_windows, 0..) |allowance, index| {
                if (!std.math.isFinite(allowance.used_percent) or
                    allowance.used_percent < 0 or allowance.used_percent > 100)
                {
                    return error.InvalidAllowance;
                }
                allowances[index] = .{
                    .id = try arena.dupe(u8, allowance.id),
                    .label = try arena.dupe(u8, allowance.label),
                    .used_percent = allowance.used_percent,
                    .resets_at_unix = allowance.resets_at_unix,
                    .duration_minutes = allowance.duration_minutes,
                    .detail = if (allowance.detail) |detail|
                        try arena.dupe(u8, detail)
                    else
                        null,
                };
            }
            replacement.allowances = allowances;
            const usage_windows = try arena.alloc(RawUsageWindow, input.token_usage_windows.len);
            for (input.token_usage_windows, 0..) |window, index| {
                try window.period.validate();
                usage_windows[index] = .{
                    .id = try arena.dupe(u8, window.id),
                    .label = try arena.dupe(u8, window.label),
                    .period = window.period,
                    .token_usage = .{
                        .input_tokens = window.token_usage.input_tokens,
                        .output_tokens = window.token_usage.output_tokens,
                        .cache_read_tokens = window.token_usage.cache_read_tokens,
                        .cache_creation_tokens = window.token_usage.cache_creation_tokens,
                        .reasoning_tokens = window.token_usage.reasoning_tokens,
                    },
                };
            }
            replacement.usage_windows = usage_windows;

            const usage_series = try arena.alloc(RawUsageSeries, input.token_usage_series.len);
            for (input.token_usage_series, 0..) |series, series_index| {
                try series.period.validate();
                const buckets = try arena.alloc(RawUsageBucket, series.buckets.len);
                for (series.buckets, 0..) |bucket, bucket_index| {
                    try bucket.period.validate();
                    buckets[bucket_index] = .{
                        .period = bucket.period,
                        .token_usage = .{
                            .input_tokens = bucket.token_usage.input_tokens,
                            .output_tokens = bucket.token_usage.output_tokens,
                            .cache_read_tokens = bucket.token_usage.cache_read_tokens,
                            .cache_creation_tokens = bucket.token_usage.cache_creation_tokens,
                            .reasoning_tokens = bucket.token_usage.reasoning_tokens,
                        },
                    };
                }
                usage_series[series_index] = .{
                    .id = try arena.dupe(u8, series.id),
                    .label = try arena.dupe(u8, series.label),
                    .period = series.period,
                    .buckets = buckets,
                };
            }
            replacement.usage_series = usage_series;
            if (self.snapshot) |*existing| existing.deinit();
            self.snapshot = replacement;
        }

        pub fn collect(
            self: *Self,
            allocator: std.mem.Allocator,
            _: model.Period,
        ) !model.ProviderReport {
            const snapshot = self.snapshot orelse return error.NotFetched;
            const resources = try allocator.alloc(model.Resource, snapshot.models.len);
            errdefer allocator.free(resources);
            for (snapshot.models, 0..) |name, index| {
                resources[index] = .{
                    .id = name,
                    .name = name,
                    .kind = "model",
                    .status = .active,
                };
            }
            const line_items = try allocator.alloc(model.CostLineItem, 0);
            errdefer allocator.free(line_items);

            const allowances: []model.AllowanceWindow = if (snapshot.allowances.len == 0)
                &.{}
            else
                try allocator.alloc(model.AllowanceWindow, snapshot.allowances.len);
            errdefer if (allowances.len > 0) allocator.free(allowances);
            for (snapshot.allowances, 0..) |allowance, index| {
                allowances[index] = .{
                    .id = allowance.id,
                    .label = allowance.label,
                    .used_percent = allowance.used_percent,
                    .resets_at_unix = allowance.resets_at_unix,
                    .duration_minutes = allowance.duration_minutes,
                    .detail = allowance.detail,
                };
            }

            const usage_windows: []model.TokenUsageWindow = if (snapshot.usage_windows.len == 0)
                &.{}
            else
                try allocator.alloc(model.TokenUsageWindow, snapshot.usage_windows.len);
            errdefer if (usage_windows.len > 0) allocator.free(usage_windows);
            for (snapshot.usage_windows, 0..) |window, index| {
                usage_windows[index] = .{
                    .id = window.id,
                    .label = window.label,
                    .period = window.period,
                    .input_tokens = window.token_usage.input_tokens,
                    .output_tokens = window.token_usage.output_tokens,
                    .cache_read_tokens = window.token_usage.cache_read_tokens,
                    .cache_creation_tokens = window.token_usage.cache_creation_tokens,
                    .reasoning_tokens = window.token_usage.reasoning_tokens,
                };
            }

            const usage_series: []model.TokenUsageSeries = if (snapshot.usage_series.len == 0)
                &.{}
            else
                try allocator.alloc(model.TokenUsageSeries, snapshot.usage_series.len);
            var initialized_series: usize = 0;
            errdefer {
                for (usage_series[0..initialized_series]) |series| {
                    if (series.buckets.len > 0) allocator.free(series.buckets);
                }
                if (usage_series.len > 0) allocator.free(usage_series);
            }
            for (snapshot.usage_series, 0..) |series, series_index| {
                const buckets: []model.TokenUsageBucket = if (series.buckets.len == 0)
                    &.{}
                else
                    try allocator.alloc(model.TokenUsageBucket, series.buckets.len);
                errdefer if (buckets.len > 0) allocator.free(buckets);
                for (series.buckets, 0..) |bucket, bucket_index| {
                    buckets[bucket_index] = .{
                        .period = bucket.period,
                        .input_tokens = bucket.token_usage.input_tokens,
                        .output_tokens = bucket.token_usage.output_tokens,
                        .cache_read_tokens = bucket.token_usage.cache_read_tokens,
                        .cache_creation_tokens = bucket.token_usage.cache_creation_tokens,
                        .reasoning_tokens = bucket.token_usage.reasoning_tokens,
                    };
                }
                usage_series[series_index] = .{
                    .id = series.id,
                    .label = series.label,
                    .period = series.period,
                    .buckets = buckets,
                };
                initialized_series += 1;
            }

            return .{
                .summary = .{
                    .id = provider_id,
                    .display_name = provider_name,
                    .kind = .ai,
                    .currency = "USD",
                    .current_cost_micros = 0,
                    .contributes_to_totals = false,
                    .updated_at_unix = snapshot.updated_at_unix,
                },
                .resources = resources,
                .line_items = line_items,
                .allowance_windows = allowances,
                .token_usage = .{
                    .period = snapshot.period,
                    .input_tokens = snapshot.input_tokens,
                    .output_tokens = snapshot.output_tokens,
                    .cache_read_tokens = snapshot.cache_read_tokens,
                    .cache_creation_tokens = snapshot.cache_creation_tokens,
                    .reasoning_tokens = snapshot.reasoning_tokens,
                    .source = snapshot.source,
                    .updated_at_unix = snapshot.updated_at_unix,
                },
                .token_usage_windows = usage_windows,
                .token_usage_series = usage_series,
            };
        }

        fn parseSnapshot(
            allocator: std.mem.Allocator,
            payload: []const u8,
            received_at_unix: i64,
        ) !OwnedSnapshot {
            var result = OwnedSnapshot{
                .arena = .init(allocator),
                .period = undefined,
                .input_tokens = 0,
                .output_tokens = 0,
                .cache_read_tokens = 0,
                .cache_creation_tokens = 0,
                .reasoning_tokens = 0,
                .source = "",
                .updated_at_unix = received_at_unix,
                .allowances = &.{},
                .usage_windows = &.{},
                .usage_series = &.{},
                .models = &.{},
            };
            errdefer result.deinit();
            const raw = try std.json.parseFromSliceLeaky(
                RawSnapshot,
                result.arena.allocator(),
                payload,
                .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
            );
            try raw.period.validate();
            for (raw.allowance_windows) |allowance| {
                if (!std.math.isFinite(allowance.used_percent) or
                    allowance.used_percent < 0 or allowance.used_percent > 100)
                {
                    return error.InvalidAllowance;
                }
            }
            result.period = raw.period;
            result.input_tokens = raw.token_usage.input_tokens;
            result.output_tokens = raw.token_usage.output_tokens;
            result.cache_read_tokens = raw.token_usage.cache_read_tokens;
            result.cache_creation_tokens = raw.token_usage.cache_creation_tokens;
            result.reasoning_tokens = raw.token_usage.reasoning_tokens;
            result.source = raw.source;
            result.updated_at_unix = raw.updated_at_unix orelse received_at_unix;
            result.allowances = raw.allowance_windows;
            for (raw.token_usage_windows) |window| try window.period.validate();
            result.usage_windows = raw.token_usage_windows;
            for (raw.token_usage_series) |series| {
                try series.period.validate();
                for (series.buckets) |bucket| try bucket.period.validate();
            }
            result.usage_series = raw.token_usage_series;
            result.models = raw.models;
            return result;
        }
    };
}
