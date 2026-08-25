const std = @import("std");
const model = @import("../model.zig");
const money = @import("../money.zig");

const ModelUsage = struct {
    id: []const u8,
    model: []const u8,
    kind: []const u8,
    amount_micros: i64 = 0,
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_creation: u64 = 0,
};

const OwnedUsage = struct {
    arena: std.heap.ArenaAllocator,
    period: model.Period,
    models: []ModelUsage,
    updated_at_unix: i64,

    fn deinit(self: *OwnedUsage) void {
        self.arena.deinit();
    }
};

pub const Cursor = struct {
    usage: ?OwnedUsage = null,

    pub fn init() Cursor {
        return .{};
    }

    pub fn deinit(self: *Cursor) void {
        if (self.usage) |*usage| usage.deinit();
        self.usage = null;
    }

    pub fn metadata(_: *const Cursor) model.ProviderMetadata {
        return .{ .id = "cursor", .display_name = "Cursor", .kind = .ai };
    }

    pub fn ingest(
        self: *Cursor,
        allocator: std.mem.Allocator,
        document_id: []const u8,
        payload: []const u8,
        received_at_unix: i64,
    ) !void {
        if (!std.mem.eql(u8, document_id, "usage-events")) {
            return error.UnsupportedDocument;
        }
        var replacement = try parseUsage(allocator, payload, received_at_unix);
        errdefer replacement.deinit();
        if (self.usage) |*existing| existing.deinit();
        self.usage = replacement;
    }

    pub fn collect(
        self: *Cursor,
        allocator: std.mem.Allocator,
        _: model.Period,
    ) !model.ProviderReport {
        const usage = self.usage orelse return error.NotFetched;
        const resources = try allocator.alloc(model.Resource, usage.models.len);
        errdefer allocator.free(resources);
        const line_items = try allocator.alloc(model.CostLineItem, usage.models.len);
        errdefer allocator.free(line_items);
        var current: i64 = 0;
        var tokens = model.TokenUsage{
            .period = usage.period,
            .source = "Cursor team usage events API",
            .updated_at_unix = usage.updated_at_unix,
        };
        for (usage.models, 0..) |entry, index| {
            current = std.math.add(i64, current, entry.amount_micros) catch
                return error.AmountOverflow;
            resources[index] = .{
                .id = entry.id,
                .name = entry.model,
                .kind = entry.kind,
                .status = .active,
                .quantity = entry.input +| entry.output +| entry.cache_read +| entry.cache_creation,
            };
            line_items[index] = .{
                .id = entry.id,
                .description = entry.model,
                .service = entry.kind,
                .amount_micros = entry.amount_micros,
                .currency = "USD",
            };
            tokens.input_tokens +|= entry.input;
            tokens.output_tokens +|= entry.output;
            tokens.cache_read_tokens +|= entry.cache_read;
            tokens.cache_creation_tokens +|= entry.cache_creation;
        }
        return .{
            .summary = .{
                .id = "cursor",
                .display_name = "Cursor",
                .kind = .ai,
                .currency = "USD",
                .current_cost_micros = current,
                .updated_at_unix = usage.updated_at_unix,
            },
            .resources = resources,
            .line_items = line_items,
            .token_usage = tokens,
        };
    }
};

fn parseUsage(
    allocator: std.mem.Allocator,
    payload: []const u8,
    received_at_unix: i64,
) !OwnedUsage {
    var result = OwnedUsage{
        .arena = .init(allocator),
        .period = undefined,
        .models = &.{},
        .updated_at_unix = received_at_unix,
    };
    errdefer result.deinit();
    const arena = result.arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    });
    if (value != .object) return error.InvalidResponse;
    result.period = try parsePeriod(value.object.get("period") orelse return error.InvalidResponse);
    const pages_value = value.object.get("pages") orelse return error.InvalidResponse;
    if (pages_value != .array) return error.InvalidResponse;
    var models: std.ArrayList(ModelUsage) = .empty;
    for (pages_value.array.items) |page_value| {
        if (page_value != .object) return error.InvalidResponse;
        const events_value = page_value.object.get("usageEvents") orelse return error.InvalidResponse;
        if (events_value != .array) return error.InvalidResponse;
        for (events_value.array.items) |event_value| {
            if (event_value != .object) return error.InvalidResponse;
            const event = event_value.object;
            const name = optionalString(event.get("model")) orelse "Other";
            const kind = optionalString(event.get("kind")) orelse
                if (optionalBool(event.get("isTokenBasedCall")) orelse false)
                    "Usage-based"
                else
                    "Subscription included";
            const existing = for (models.items) |*entry| {
                if (std.mem.eql(u8, entry.model, name) and
                    std.mem.eql(u8, entry.kind, kind)) break entry;
            } else null;
            const entry = existing orelse blk: {
                try models.append(arena, .{
                    .id = try std.fmt.allocPrint(arena, "{s}:{s}", .{ kind, name }),
                    .model = name,
                    .kind = kind,
                });
                break :blk &models.items[models.items.len - 1];
            };
            if (event.get("chargedCents")) |charged| {
                if (charged != .null) {
                    entry.amount_micros = std.math.add(
                        i64,
                        entry.amount_micros,
                        try fractionalCentsToMicros(charged),
                    ) catch return error.AmountOverflow;
                }
            }
            if (event.get("tokenUsage")) |tokens_value| {
                if (tokens_value == .null) continue;
                if (tokens_value != .object) return error.InvalidResponse;
                const tokens = tokens_value.object;
                entry.input +|= try optionalU64(tokens.get("inputTokens")) orelse 0;
                entry.output +|= try optionalU64(tokens.get("outputTokens")) orelse 0;
                entry.cache_read +|= try optionalU64(tokens.get("cacheReadTokens")) orelse 0;
                entry.cache_creation +|=
                    try optionalU64(tokens.get("cacheWriteTokens")) orelse 0;
            }
        }
    }
    result.models = try models.toOwnedSlice(arena);
    std.mem.sort(ModelUsage, result.models, {}, amountDescending);
    return result;
}

fn fractionalCentsToMicros(value: std.json.Value) !i64 {
    const microcents = switch (value) {
        .number_string, .string => |number| try money.parseRoundedMicros(number),
        .integer => |integer| std.math.mul(i64, integer, money.micros_per_unit) catch
            return error.AmountOverflow,
        else => return error.InvalidAmount,
    };
    const adjustment: i64 = if (microcents > 0) 50 else if (microcents < 0) -50 else 0;
    return @divTrunc(std.math.add(i64, microcents, adjustment) catch
        return error.AmountOverflow, 100);
}

fn parsePeriod(value: std.json.Value) !model.Period {
    if (value != .object) return error.InvalidResponse;
    const period = model.Period{
        .start_unix = try requireI64(value.object.get("start_unix") orelse
            return error.InvalidResponse),
        .end_exclusive_unix = try requireI64(value.object.get("end_exclusive_unix") orelse
            return error.InvalidResponse),
    };
    try period.validate();
    return period;
}

fn requireI64(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |integer| integer,
        .number_string, .string => |number| std.fmt.parseInt(i64, number, 10),
        else => error.InvalidResponse,
    };
}

fn optionalString(value: ?std.json.Value) ?[]const u8 {
    const found = value orelse return null;
    return if (found == .string) found.string else null;
}

fn optionalBool(value: ?std.json.Value) ?bool {
    const found = value orelse return null;
    return if (found == .bool) found.bool else null;
}

fn optionalU64(value: ?std.json.Value) !?u64 {
    const found = value orelse return null;
    if (found == .null) return null;
    return switch (found) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.InvalidAmount,
        .number_string, .string => |number| @as(?u64, try std.fmt.parseInt(u64, number, 10)),
        else => error.InvalidAmount,
    };
}

fn amountDescending(_: void, left: ModelUsage, right: ModelUsage) bool {
    return left.amount_micros > right.amount_micros;
}

test "Cursor aggregates charged cents and token classes by model" {
    var provider = Cursor.init();
    defer provider.deinit();
    try provider.ingest(std.testing.allocator, "usage-events",
        \\{"period":{"start_unix":1,"end_exclusive_unix":200},"pages":[{"usageEvents":[
        \\ {"model":"claude","kind":"Usage-based","chargedCents":125.5,"tokenUsage":{"inputTokens":80,"outputTokens":10,"cacheReadTokens":20,"cacheWriteTokens":5}},
        \\ {"model":"claude","kind":"Usage-based","chargedCents":24.5,"tokenUsage":{"inputTokens":20,"outputTokens":5}},
        \\ {"model":"grok","kind":"Included in Business","tokenUsage":{"inputTokens":3,"outputTokens":1}}]}]}
    , 100);
    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 200,
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1_500_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(u64, 103), report.token_usage.?.input_tokens);
    try std.testing.expectEqual(@as(u64, 20), report.token_usage.?.cache_read_tokens);
    try std.testing.expectEqual(@as(usize, 2), report.line_items.len);
    try std.testing.expectEqualStrings("Usage-based", report.line_items[0].service);
}
