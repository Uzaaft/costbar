const std = @import("std");
const model = @import("../model.zig");
const money = @import("../money.zig");

const ModelUsage = struct {
    name: []const u8,
    provider_name: []const u8,
    in_current_period: bool,
    amount_micros: i64,
    input_tokens: u64,
    output_tokens: u64,
    reasoning_tokens: u64,
};

const TimedUsage = struct {
    start_unix: i64,
    end_exclusive_unix: i64,
    model_name: []const u8,
    amount_micros: i64,
    input_tokens: u64,
    output_tokens: u64,
    reasoning_tokens: u64,
};

const rolling_windows = [_]struct {
    id: []const u8,
    label: []const u8,
    duration_seconds: i64,
}{
    .{ .id = "day", .label = "Last 24 hours", .duration_seconds = std.time.s_per_day },
    .{ .id = "week", .label = "Last week", .duration_seconds = 7 * std.time.s_per_day },
    .{ .id = "thirty-days", .label = "Last month", .duration_seconds = 30 * std.time.s_per_day },
};

const OwnedSnapshot = struct {
    arena: std.heap.ArenaAllocator,
    month_to_date_micros: i64,
    credit_remaining_micros: ?i64,
    key_limit_micros: ?i64,
    key_limit_used_micros: i64,
    key_limit_reset: ?[]const u8,
    updated_at_unix: i64,
    activity_period: model.Period,
    history_period: model.Period,
    activity_present: bool,
    models: []ModelUsage,
    usage_buckets: []TimedUsage,

    fn deinit(self: *OwnedSnapshot) void {
        self.arena.deinit();
    }
};

pub const OpenRouter = struct {
    snapshot: ?OwnedSnapshot = null,

    pub fn init() OpenRouter {
        return .{};
    }

    pub fn deinit(self: *OpenRouter) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.snapshot = null;
    }

    pub fn metadata(_: *const OpenRouter) model.ProviderMetadata {
        return .{
            .id = "openrouter",
            .display_name = "OpenRouter",
            .kind = .ai,
        };
    }

    pub fn ingest(
        self: *OpenRouter,
        allocator: std.mem.Allocator,
        document_id: []const u8,
        payload: []const u8,
        received_at_unix: i64,
    ) !void {
        if (!std.mem.eql(u8, document_id, "snapshot")) {
            return error.UnsupportedDocument;
        }

        var replacement = try parseSnapshot(allocator, payload, received_at_unix);
        errdefer replacement.deinit();
        if (self.snapshot) |*existing| existing.deinit();
        self.snapshot = replacement;
    }

    pub fn collect(
        self: *OpenRouter,
        allocator: std.mem.Allocator,
        _: model.Period,
    ) !model.ProviderReport {
        const snapshot = self.snapshot orelse return error.NotFetched;
        const resources = try allocator.alloc(model.Resource, snapshot.models.len);
        errdefer allocator.free(resources);
        for (snapshot.models, 0..) |entry, index| {
            resources[index] = .{
                .id = entry.name,
                .name = entry.name,
                .kind = "model",
                .status = .active,
            };
        }

        var activity_total: i64 = 0;
        for (snapshot.models) |entry| {
            if (!entry.in_current_period) continue;
            activity_total = std.math.add(i64, activity_total, entry.amount_micros) catch
                return error.AmountOverflow;
        }
        const residual = std.math.sub(
            i64,
            snapshot.month_to_date_micros,
            activity_total,
        ) catch return error.AmountOverflow;
        const needs_residual = residual != 0;
        var current_model_count: usize = 0;
        for (snapshot.models) |entry| {
            current_model_count += @intFromBool(entry.in_current_period);
        }
        const line_items = try allocator.alloc(
            model.CostLineItem,
            current_model_count + @intFromBool(needs_residual),
        );
        errdefer allocator.free(line_items);
        var line_item_index: usize = 0;
        for (snapshot.models) |entry| {
            if (!entry.in_current_period) continue;
            line_items[line_item_index] = .{
                .id = entry.name,
                .description = entry.name,
                .service = entry.provider_name,
                .amount_micros = entry.amount_micros,
                .detail = "Account analytics · UTC",
            };
            line_item_index += 1;
        }
        if (needs_residual) {
            line_items[line_item_index] = .{
                .id = "openrouter-current-day-or-other",
                .description = "Current day or other usage",
                .service = "OpenRouter",
                .amount_micros = residual,
            };
        }

        const allowance_count: usize = if (snapshot.key_limit_micros) |limit|
            @intFromBool(limit > 0)
        else
            0;
        const allowance_windows = try allocator.alloc(model.AllowanceWindow, allowance_count);
        if (allowance_count == 1) {
            const limit = snapshot.key_limit_micros.?;
            allowance_windows[0] = .{
                .id = "openrouter-key-limit",
                .label = "API key limit",
                .used_percent = @min(
                    @max(
                        @as(f64, @floatFromInt(snapshot.key_limit_used_micros)) /
                            @as(f64, @floatFromInt(limit)) * 100,
                        0,
                    ),
                    100,
                ),
                .detail = snapshot.key_limit_reset,
            };
        }
        errdefer if (allowance_windows.len > 0) allocator.free(allowance_windows);

        var tokens = model.TokenUsage{
            .period = snapshot.activity_period,
            .source = "OpenRouter Analytics API",
            .updated_at_unix = snapshot.updated_at_unix,
        };
        for (snapshot.models) |entry| {
            if (!entry.in_current_period) continue;
            tokens.input_tokens +|= entry.input_tokens;
            tokens.output_tokens +|= entry.output_tokens;
            tokens.reasoning_tokens +|= entry.reasoning_tokens;
        }

        const token_usage_windows: []model.TokenUsageWindow = if (snapshot.activity_present)
            try allocator.alloc(model.TokenUsageWindow, rolling_windows.len)
        else
            &.{};
        errdefer if (token_usage_windows.len > 0) allocator.free(token_usage_windows);
        for (rolling_windows, 0..) |definition, index| {
            const window_end = snapshot.history_period.end_exclusive_unix;
            const window_start = @max(
                snapshot.history_period.start_unix,
                window_end -| definition.duration_seconds,
            );
            token_usage_windows[index] = .{
                .id = definition.id,
                .label = definition.label,
                .period = .{
                    .start_unix = window_start,
                    .end_exclusive_unix = window_end,
                },
            };
            for (snapshot.usage_buckets) |bucket| {
                if (bucket.start_unix >= window_end or
                    bucket.end_exclusive_unix <= window_start) continue;
                token_usage_windows[index].input_tokens +|= bucket.input_tokens;
                token_usage_windows[index].output_tokens +|= bucket.output_tokens;
                token_usage_windows[index].reasoning_tokens +|= bucket.reasoning_tokens;
            }
        }

        var dated_model_count: usize = 0;
        for (snapshot.models) |entry| {
            const has_dated_spend = for (snapshot.usage_buckets) |bucket| {
                if (std.mem.eql(u8, bucket.model_name, entry.name)) break true;
            } else false;
            dated_model_count += @intFromBool(has_dated_spend);
        }
        const spend_series: []model.SpendSeries = if (dated_model_count == 0)
            &.{}
        else
            try allocator.alloc(model.SpendSeries, dated_model_count);
        errdefer if (spend_series.len > 0) allocator.free(spend_series);
        var spend_series_index: usize = 0;
        for (snapshot.models) |entry| {
            var bucket_count: usize = 0;
            for (snapshot.usage_buckets) |bucket| {
                bucket_count += @intFromBool(std.mem.eql(u8, bucket.model_name, entry.name));
            }
            if (bucket_count == 0) continue;
            const buckets = try allocator.alloc(model.SpendBucket, bucket_count);
            errdefer allocator.free(buckets);
            var bucket_index: usize = 0;
            for (snapshot.usage_buckets) |bucket| {
                if (!std.mem.eql(u8, bucket.model_name, entry.name)) continue;
                buckets[bucket_index] = .{
                    .period = .{
                        .start_unix = bucket.start_unix,
                        .end_exclusive_unix = bucket.end_exclusive_unix,
                    },
                    .amount_micros = bucket.amount_micros,
                    .usage_quantity = bucket.input_tokens +| bucket.output_tokens +|
                        bucket.reasoning_tokens,
                };
                bucket_index += 1;
            }
            spend_series[spend_series_index] = .{
                .id = entry.name,
                .label = entry.name,
                .currency = "USD",
                .period = snapshot.history_period,
                .buckets = buckets,
            };
            spend_series_index += 1;
        }

        return .{
            .summary = .{
                .id = "openrouter",
                .display_name = "OpenRouter",
                .kind = .ai,
                .currency = "USD",
                .current_cost_micros = snapshot.month_to_date_micros,
                .credit_remaining_micros = snapshot.credit_remaining_micros,
                .updated_at_unix = snapshot.updated_at_unix,
            },
            .resources = resources,
            .line_items = line_items,
            .allowance_windows = allowance_windows,
            .token_usage = if (snapshot.activity_present) tokens else null,
            .token_usage_windows = token_usage_windows,
            .spend_series = spend_series,
        };
    }
};

fn parseSnapshot(
    allocator: std.mem.Allocator,
    payload: []const u8,
    received_at_unix: i64,
) !OwnedSnapshot {
    var result = OwnedSnapshot{
        .arena = .init(allocator),
        .month_to_date_micros = 0,
        .credit_remaining_micros = null,
        .key_limit_micros = null,
        .key_limit_used_micros = 0,
        .key_limit_reset = null,
        .updated_at_unix = received_at_unix,
        .activity_period = .{ .start_unix = 0, .end_exclusive_unix = 1 },
        .history_period = .{ .start_unix = 0, .end_exclusive_unix = 1 },
        .activity_present = false,
        .models = &.{},
        .usage_buckets = &.{},
    };
    errdefer result.deinit();
    const arena = result.arena.allocator();
    const root_value = try std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    });
    const root = try requireObject(root_value);
    const key = try responseDataObject(root.get("key") orelse return error.InvalidResponse);
    result.month_to_date_micros = try optionalMoney(key.get("usage_monthly")) orelse
        try optionalMoney(key.get("usage")) orelse
        0;
    result.key_limit_micros = try optionalMoney(key.get("limit"));
    result.key_limit_reset = optionalString(key.get("limit_reset"));
    result.key_limit_used_micros = if (result.key_limit_reset) |reset|
        if (std.mem.eql(u8, reset, "daily"))
            try optionalMoney(key.get("usage_daily")) orelse 0
        else if (std.mem.eql(u8, reset, "weekly"))
            try optionalMoney(key.get("usage_weekly")) orelse 0
        else
            result.month_to_date_micros
    else
        result.month_to_date_micros;

    if (root.get("credits")) |credits_response| {
        const credits = try responseDataObject(credits_response);
        const purchased = try optionalMoney(credits.get("total_credits"));
        const used = try optionalMoney(credits.get("total_usage"));
        if (purchased != null and used != null) {
            result.credit_remaining_micros = @max(
                std.math.sub(i64, purchased.?, used.?) catch return error.AmountOverflow,
                0,
            );
        }
    }

    if (root.get("activity_period")) |period_value| {
        const period = try requireObject(period_value);
        result.activity_period = .{
            .start_unix = try requireI64(period.get("start_unix") orelse
                return error.InvalidResponse),
            .end_exclusive_unix = try requireI64(period.get("end_exclusive_unix") orelse
                return error.InvalidResponse),
        };
        try result.activity_period.validate();
    }
    result.history_period = result.activity_period;
    if (root.get("history_period")) |period_value| {
        const period = try requireObject(period_value);
        result.history_period = .{
            .start_unix = try requireI64(period.get("start_unix") orelse
                return error.InvalidResponse),
            .end_exclusive_unix = try requireI64(period.get("end_exclusive_unix") orelse
                return error.InvalidResponse),
        };
        try result.history_period.validate();
    }

    var models: std.ArrayList(ModelUsage) = .empty;
    var usage_buckets: std.ArrayList(TimedUsage) = .empty;
    const analytics_response = root.get("analytics");
    const usage_response = analytics_response orelse root.get("activity");
    if (usage_response) |response_value| {
        const response_root = try requireObject(response_value);
        const data_value = if (analytics_response != null) blk: {
            const response_data = try requireObject(
                response_root.get("data") orelse return error.InvalidResponse,
            );
            break :blk response_data.get("data") orelse return error.InvalidResponse;
        } else response_root.get("data") orelse return error.InvalidResponse;
        if (data_value != .array) return error.InvalidResponse;
        result.activity_present = true;
        for (data_value.array.items) |item_value| {
            const item = try requireObject(item_value);
            const hour_value = optionalString(item.get("date__hour")) orelse
                optionalString(item.get("created_at__hour"));
            const date_value = hour_value orelse
                optionalString(item.get("date__day")) orelse
                optionalString(item.get("created_at__day")) orelse
                optionalString(item.get("date"));
            const bucket_start_unix: ?i64 = if (date_value) |date|
                parseAnalyticsTimestamp(date) catch continue
            else
                null;
            const bucket_seconds: i64 = if (hour_value != null)
                std.time.s_per_hour
            else
                std.time.s_per_day;
            const in_current_period = if (bucket_start_unix) |timestamp|
                timestamp >= result.activity_period.start_unix and
                    timestamp < result.activity_period.end_exclusive_unix
            else
                true;
            const in_history_period = if (bucket_start_unix) |timestamp|
                timestamp >= result.history_period.start_unix and
                    timestamp < result.history_period.end_exclusive_unix
            else
                false;
            if (!in_current_period and !in_history_period) continue;
            const name = optionalString(item.get("model")) orelse "Unknown model";
            const provider_name = optionalString(item.get("provider_name")) orelse "OpenRouter";
            const amount = try optionalMoney(item.get("total_usage")) orelse
                try optionalMoney(item.get("usage")) orelse
                0;
            const input = try optionalU64(item.get("tokens_prompt")) orelse
                try optionalU64(item.get("prompt_tokens")) orelse
                0;
            const output = try optionalU64(item.get("tokens_completion")) orelse
                try optionalU64(item.get("completion_tokens")) orelse
                0;
            const reasoning = try optionalU64(item.get("reasoning_tokens")) orelse 0;

            if (bucket_start_unix) |timestamp| {
                if (in_history_period) {
                    const existing_bucket = for (usage_buckets.items) |*bucket| {
                        if (bucket.start_unix == timestamp and
                            std.mem.eql(u8, bucket.model_name, name)) break bucket;
                    } else null;
                    if (existing_bucket) |bucket| {
                        bucket.amount_micros = std.math.add(i64, bucket.amount_micros, amount) catch
                            return error.AmountOverflow;
                        bucket.input_tokens +|= input;
                        bucket.output_tokens +|= output;
                        bucket.reasoning_tokens +|= reasoning;
                    } else {
                        try usage_buckets.append(arena, .{
                            .start_unix = timestamp,
                            .end_exclusive_unix = timestamp + bucket_seconds,
                            .model_name = name,
                            .amount_micros = amount,
                            .input_tokens = input,
                            .output_tokens = output,
                            .reasoning_tokens = reasoning,
                        });
                    }
                }
            }

            const existing = for (models.items) |*entry| {
                if (std.mem.eql(u8, entry.name, name)) break entry;
            } else null;
            if (existing) |entry| {
                if (in_current_period) {
                    entry.in_current_period = true;
                    entry.amount_micros = std.math.add(i64, entry.amount_micros, amount) catch
                        return error.AmountOverflow;
                    entry.input_tokens +|= input;
                    entry.output_tokens +|= output;
                    entry.reasoning_tokens +|= reasoning;
                }
            } else {
                try models.append(arena, .{
                    .name = name,
                    .provider_name = provider_name,
                    .in_current_period = in_current_period,
                    .amount_micros = if (in_current_period) amount else 0,
                    .input_tokens = if (in_current_period) input else 0,
                    .output_tokens = if (in_current_period) output else 0,
                    .reasoning_tokens = if (in_current_period) reasoning else 0,
                });
            }
        }
    }
    result.models = try models.toOwnedSlice(arena);
    std.mem.sort(ModelUsage, result.models, {}, byAmountDescending);
    result.usage_buckets = try usage_buckets.toOwnedSlice(arena);
    std.mem.sort(TimedUsage, result.usage_buckets, {}, byTimeAscending);
    if (analytics_response != null) {
        result.month_to_date_micros = 0;
        for (result.models) |entry| {
            result.month_to_date_micros = std.math.add(
                i64,
                result.month_to_date_micros,
                entry.amount_micros,
            ) catch return error.AmountOverflow;
        }
    }
    return result;
}

fn parseAnalyticsTimestamp(value: []const u8) !i64 {
    if (value.len < 10 or value[4] != '-' or value[7] != '-') {
        return error.InvalidDate;
    }
    const year = try std.fmt.parseInt(i64, value[0..4], 10);
    const month = try std.fmt.parseInt(i64, value[5..7], 10);
    const day = try std.fmt.parseInt(i64, value[8..10], 10);
    if (month < 1 or month > 12 or day < 1 or day > 31) return error.InvalidDate;
    const adjusted_year = year - @intFromBool(month <= 2);
    const era = @divFloor(adjusted_year, 400);
    const year_of_era = adjusted_year - era * 400;
    const shifted_month = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    const day_start = (era * 146_097 + day_of_era - 719_468) * 86_400;
    if (value.len == 10) return day_start;
    if (value.len < 13 or (value[10] != 'T' and value[10] != ' ')) {
        return error.InvalidDate;
    }
    const hour = try std.fmt.parseInt(i64, value[11..13], 10);
    if (hour < 0 or hour > 23) return error.InvalidDate;
    return day_start + hour * std.time.s_per_hour;
}

fn byAmountDescending(_: void, left: ModelUsage, right: ModelUsage) bool {
    if (left.amount_micros != right.amount_micros) {
        return left.amount_micros > right.amount_micros;
    }
    return std.mem.lessThan(u8, left.name, right.name);
}

fn byTimeAscending(_: void, left: TimedUsage, right: TimedUsage) bool {
    if (left.start_unix != right.start_unix) {
        return left.start_unix < right.start_unix;
    }
    return std.mem.lessThan(u8, left.model_name, right.model_name);
}

fn responseDataObject(value: std.json.Value) !std.json.ObjectMap {
    const response = try requireObject(value);
    return requireObject(response.get("data") orelse return error.InvalidResponse);
}

fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidResponse;
    return value.object;
}

fn optionalString(value: ?std.json.Value) ?[]const u8 {
    const found = value orelse return null;
    if (found == .null) return null;
    if (found != .string) return null;
    return found.string;
}

fn optionalMoney(value: ?std.json.Value) !?i64 {
    const found = value orelse return null;
    if (found == .null) return null;
    return switch (found) {
        .number_string, .string => |number| try money.parseRoundedMicros(number),
        .integer => |integer| std.math.mul(i64, integer, money.micros_per_unit) catch
            error.AmountOverflow,
        else => error.InvalidAmount,
    };
}

fn optionalU64(value: ?std.json.Value) !?u64 {
    const found = value orelse return null;
    if (found == .null) return null;
    return switch (found) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.InvalidAmount,
        .number_string, .string => |number| try std.fmt.parseInt(u64, number, 10),
        else => error.InvalidAmount,
    };
}

fn requireI64(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |integer| integer,
        .number_string, .string => |number| try std.fmt.parseInt(i64, number, 10),
        else => error.InvalidResponse,
    };
}

test "OpenRouter reports monthly spend, credits, limits, and model tokens" {
    var provider = OpenRouter.init();
    defer provider.deinit();
    try provider.ingest(std.testing.allocator, "snapshot",
        \\{
        \\  "key":{"data":{"usage_monthly":25.5,"limit":100,"limit_remaining":74.5,"limit_reset":"monthly"}},
        \\  "credits":{"data":{"total_credits":100.5,"total_usage":25.75}},
        \\  "activity_period":{"start_unix":1,"end_exclusive_unix":200},
        \\  "activity":{"data":[
        \\    {"model":"anthropic/claude","provider_name":"Anthropic","usage":10.25,"prompt_tokens":50,"completion_tokens":25,"reasoning_tokens":5},
        \\    {"model":"anthropic/claude","provider_name":"Anthropic","usage":5,"prompt_tokens":20,"completion_tokens":10,"reasoning_tokens":0}
        \\  ]}
        \\}
    , 100);

    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 200,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 25_500_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(?i64, 74_750_000), report.summary.credit_remaining_micros);
    try std.testing.expectApproxEqAbs(@as(f64, 25.5), report.allowance_windows[0].used_percent, 0.001);
    try std.testing.expectEqual(@as(u64, 70), report.token_usage.?.input_tokens);
    try std.testing.expectEqual(@as(u64, 35), report.token_usage.?.output_tokens);
    try std.testing.expectEqual(@as(usize, 2), report.line_items.len);
    try std.testing.expectEqual(@as(i64, 10_250_000), report.line_items[1].amount_micros);
}

test "OpenRouter filters management activity to the requested period" {
    var provider = OpenRouter.init();
    defer provider.deinit();
    try provider.ingest(std.testing.allocator, "snapshot",
        \\{
        \\  "key":{"data":{"usage_monthly":2}},
        \\  "activity_period":{"start_unix":1785535200,"end_exclusive_unix":1788213600},
        \\  "activity":{"data":[
        \\    {"date":"2026-08-10","model":"inside","usage":1},
        \\    {"date":"2026-08-10","model":"inside","usage":0.25},
        \\    {"date":"2026-08-11","model":"another","usage":0.5},
        \\    {"date":"2026-07-10","model":"outside","usage":1}
        \\  ]}
        \\}
    , 100);
    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1785535200,
        .end_exclusive_unix = 1788213600,
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), report.resources.len);
    try std.testing.expectEqualStrings("inside", report.resources[0].name);
    try std.testing.expectEqual(@as(usize, 2), report.spend_series.len);
    const inside = report.spend_series[0];
    try std.testing.expectEqualStrings("inside", inside.label);
    try std.testing.expectEqualStrings("USD", inside.currency);
    try std.testing.expectEqual(@as(usize, 1), inside.buckets.len);
    try std.testing.expectEqual(@as(i64, 1_250_000), inside.buckets[0].amount_micros);
    const another = report.spend_series[1];
    try std.testing.expectEqualStrings("another", another.label);
    try std.testing.expectEqual(@as(i64, 500_000), another.buckets[0].amount_micros);
}

test "OpenRouter analytics includes current-day model spend and tokens" {
    var provider = OpenRouter.init();
    defer provider.deinit();
    try provider.ingest(std.testing.allocator, "snapshot",
        \\{
        \\  "key":{"data":{"usage_monthly":0}},
        \\  "activity_period":{"start_unix":1785535200,"end_exclusive_unix":1788213600},
        \\  "analytics":{"data":{"data":[
        \\    {"created_at__day":"2026-08-25T00:00:00.000Z","model":"google/gemini-3.7-flash","total_usage":0.003,"tokens_prompt":"30000","tokens_completion":"900","reasoning_tokens":"100"},
        \\    {"date__day":"2026-08-25","model":"openrouter/ox-alpha","total_usage":0.002,"tokens_prompt":100,"tokens_completion":50,"reasoning_tokens":0}
        \\  ],"metadata":{"row_count":2,"truncated":false}}}
        \\}
    , 1787664000);
    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1785535200,
        .end_exclusive_unix = 1788213600,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 5_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(usize, 2), report.resources.len);
    try std.testing.expectEqual(@as(u64, 30_100), report.token_usage.?.input_tokens);
    try std.testing.expectEqual(@as(u64, 950), report.token_usage.?.output_tokens);
    try std.testing.expectEqual(@as(u64, 100), report.token_usage.?.reasoning_tokens);
    try std.testing.expectEqual(@as(usize, 2), report.spend_series.len);
    try std.testing.expectEqual(@as(i64, 1787616000), report.spend_series[0].buckets[0].period.start_unix);
    try std.testing.expectEqual(@as(i64, 3_000), report.spend_series[0].buckets[0].amount_micros);
    try std.testing.expectEqual(@as(usize, 2), report.line_items.len);
}

test "OpenRouter exposes hourly rolling usage for 24 hours week and month" {
    var provider = OpenRouter.init();
    defer provider.deinit();
    try provider.ingest(std.testing.allocator, "snapshot",
        \\{
        \\  "key":{"data":{"usage_monthly":0}},
        \\  "activity_period":{"start_unix":1785542400,"end_exclusive_unix":1788220800},
        \\  "history_period":{"start_unix":1785072000,"end_exclusive_unix":1787664000},
        \\  "analytics":{"data":{"data":[
        \\    {"date__hour":"2026-07-30 12:00:00","model":"test/model","total_usage":0.008,"tokens_prompt":"40"},
        \\    {"date__hour":"2026-08-17 12:00:00","model":"test/model","total_usage":0.004,"tokens_prompt":"30"},
        \\    {"date__hour":"2026-08-24 12:00:00","model":"test/model","total_usage":0.002,"tokens_prompt":"20"},
        \\    {"date__hour":"2026-08-25 13:00:00","model":"test/model","total_usage":0.001,"tokens_prompt":"10"}
        \\  ],"metadata":{"row_count":4,"truncated":false}}}
        \\}
    , 1787664000);
    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1785542400,
        .end_exclusive_unix = 1788220800,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 7_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(u64, 60), report.token_usage.?.input_tokens);
    try std.testing.expectEqual(@as(usize, 3), report.token_usage_windows.len);
    try std.testing.expectEqualStrings("day", report.token_usage_windows[0].id);
    try std.testing.expectEqual(@as(u64, 10), report.token_usage_windows[0].input_tokens);
    try std.testing.expectEqualStrings("week", report.token_usage_windows[1].id);
    try std.testing.expectEqual(@as(u64, 30), report.token_usage_windows[1].input_tokens);
    try std.testing.expectEqualStrings("thirty-days", report.token_usage_windows[2].id);
    try std.testing.expectEqual(@as(u64, 100), report.token_usage_windows[2].input_tokens);
    try std.testing.expectEqual(@as(usize, 1), report.spend_series.len);
    try std.testing.expectEqual(@as(usize, 4), report.spend_series[0].buckets.len);
    try std.testing.expectEqual(@as(u64, 40), report.spend_series[0].buckets[0].usage_quantity);
    try std.testing.expectEqual(
        @as(i64, std.time.s_per_hour),
        report.spend_series[0].buckets[0].period.end_exclusive_unix -
            report.spend_series[0].buckets[0].period.start_unix,
    );
}

test "OpenRouter preserves free model volume in chart buckets" {
    var provider = OpenRouter.init();
    defer provider.deinit();
    try provider.ingest(std.testing.allocator, "snapshot",
        \\{
        \\  "key":{"data":{"usage_monthly":0}},
        \\  "activity_period":{"start_unix":1785542400,"end_exclusive_unix":1788220800},
        \\  "history_period":{"start_unix":1785072000,"end_exclusive_unix":1787664000},
        \\  "analytics":{"data":{"data":[
        \\    {"date__hour":"2026-08-25 13:00:00","model":"openrouter/free","total_usage":0,"tokens_prompt":"2644827","tokens_completion":"40928","reasoning_tokens":"12"}
        \\  ],"metadata":{"row_count":1,"truncated":false}}}
        \\}
    , 1787664000);
    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1785542400,
        .end_exclusive_unix = 1788220800,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), report.spend_series.len);
    try std.testing.expectEqual(@as(i64, 0), report.spend_series[0].buckets[0].amount_micros);
    try std.testing.expectEqual(
        @as(u64, 2_685_767),
        report.spend_series[0].buckets[0].usage_quantity,
    );
}
