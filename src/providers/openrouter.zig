const std = @import("std");
const model = @import("../model.zig");
const money = @import("../money.zig");

const ModelUsage = struct {
    name: []const u8,
    provider_name: []const u8,
    amount_micros: i64,
    input_tokens: u64,
    output_tokens: u64,
    reasoning_tokens: u64,
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
    activity_present: bool,
    models: []ModelUsage,

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
            activity_total = std.math.add(i64, activity_total, entry.amount_micros) catch
                return error.AmountOverflow;
        }
        const residual = std.math.sub(
            i64,
            snapshot.month_to_date_micros,
            activity_total,
        ) catch return error.AmountOverflow;
        const needs_residual = residual != 0;
        const line_items = try allocator.alloc(
            model.CostLineItem,
            snapshot.models.len + @intFromBool(needs_residual),
        );
        errdefer allocator.free(line_items);
        for (snapshot.models, 0..) |entry, index| {
            line_items[index] = .{
                .id = entry.name,
                .description = entry.name,
                .service = entry.provider_name,
                .amount_micros = entry.amount_micros,
                .detail = "Completed UTC days",
            };
        }
        if (needs_residual) {
            line_items[snapshot.models.len] = .{
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
            .source = "OpenRouter activity API",
            .updated_at_unix = snapshot.updated_at_unix,
        };
        for (snapshot.models) |entry| {
            tokens.input_tokens +|= entry.input_tokens;
            tokens.output_tokens +|= entry.output_tokens;
            tokens.reasoning_tokens +|= entry.reasoning_tokens;
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
        .activity_present = false,
        .models = &.{},
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

    var models: std.ArrayList(ModelUsage) = .empty;
    if (root.get("activity")) |activity_response| {
        const activity_root = try requireObject(activity_response);
        const data_value = activity_root.get("data") orelse return error.InvalidResponse;
        if (data_value != .array) return error.InvalidResponse;
        result.activity_present = true;
        for (data_value.array.items) |item_value| {
            const item = try requireObject(item_value);
            const name = optionalString(item.get("model")) orelse "Unknown model";
            const provider_name = optionalString(item.get("provider_name")) orelse "OpenRouter";
            const amount = try optionalMoney(item.get("usage")) orelse 0;
            const input = try optionalU64(item.get("prompt_tokens")) orelse 0;
            const output = try optionalU64(item.get("completion_tokens")) orelse 0;
            const reasoning = try optionalU64(item.get("reasoning_tokens")) orelse 0;

            const existing = for (models.items) |*entry| {
                if (std.mem.eql(u8, entry.name, name)) break entry;
            } else null;
            if (existing) |entry| {
                entry.amount_micros = std.math.add(i64, entry.amount_micros, amount) catch
                    return error.AmountOverflow;
                entry.input_tokens +|= input;
                entry.output_tokens +|= output;
                entry.reasoning_tokens +|= reasoning;
            } else {
                try models.append(arena, .{
                    .name = name,
                    .provider_name = provider_name,
                    .amount_micros = amount,
                    .input_tokens = input,
                    .output_tokens = output,
                    .reasoning_tokens = reasoning,
                });
            }
        }
    }
    result.models = try models.toOwnedSlice(arena);
    std.mem.sort(ModelUsage, result.models, {}, byAmountDescending);
    return result;
}

fn byAmountDescending(_: void, left: ModelUsage, right: ModelUsage) bool {
    if (left.amount_micros != right.amount_micros) {
        return left.amount_micros > right.amount_micros;
    }
    return std.mem.lessThan(u8, left.name, right.name);
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
