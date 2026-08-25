const std = @import("std");
const model = @import("../model.zig");
const money = @import("../money.zig");

const Usage = struct {
    name: []const u8,
    amount_micros: i64,
};

const OwnedSnapshot = struct {
    arena: std.heap.ArenaAllocator,
    period: model.Period,
    usage: []Usage,
    credit_remaining_micros: i64,
    updated_at_unix: i64,

    fn deinit(self: *OwnedSnapshot) void {
        self.arena.deinit();
    }
};

pub const XAIAPI = struct {
    snapshot: ?OwnedSnapshot = null,

    pub fn init() XAIAPI {
        return .{};
    }

    pub fn deinit(self: *XAIAPI) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.snapshot = null;
    }

    pub fn metadata(_: *const XAIAPI) model.ProviderMetadata {
        return .{ .id = "xai-api", .display_name = "xAI (Grok) API", .kind = .ai };
    }

    pub fn ingest(
        self: *XAIAPI,
        allocator: std.mem.Allocator,
        document_id: []const u8,
        payload: []const u8,
        received_at_unix: i64,
    ) !void {
        if (!std.mem.eql(u8, document_id, "billing")) {
            return error.UnsupportedDocument;
        }
        var replacement = try parseSnapshot(allocator, payload, received_at_unix);
        errdefer replacement.deinit();
        if (self.snapshot) |*existing| existing.deinit();
        self.snapshot = replacement;
    }

    pub fn collect(
        self: *XAIAPI,
        allocator: std.mem.Allocator,
        _: model.Period,
    ) !model.ProviderReport {
        const snapshot = self.snapshot orelse return error.NotFetched;
        const resources = try allocator.alloc(model.Resource, snapshot.usage.len);
        errdefer allocator.free(resources);
        const line_items = try allocator.alloc(model.CostLineItem, snapshot.usage.len);
        errdefer allocator.free(line_items);
        var current: i64 = 0;
        for (snapshot.usage, 0..) |entry, index| {
            current = std.math.add(i64, current, entry.amount_micros) catch
                return error.AmountOverflow;
            resources[index] = .{
                .id = entry.name,
                .name = entry.name,
                .kind = "model",
                .status = .active,
            };
            line_items[index] = .{
                .id = entry.name,
                .description = entry.name,
                .service = "API usage",
                .amount_micros = entry.amount_micros,
                .currency = "USD",
            };
        }
        return .{
            .summary = .{
                .id = "xai-api",
                .display_name = "xAI (Grok) API",
                .kind = .ai,
                .currency = "USD",
                .current_cost_micros = current,
                .credit_remaining_micros = snapshot.credit_remaining_micros,
                .updated_at_unix = snapshot.updated_at_unix,
            },
            .resources = resources,
            .line_items = line_items,
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
        .period = undefined,
        .usage = &.{},
        .credit_remaining_micros = 0,
        .updated_at_unix = received_at_unix,
    };
    errdefer result.deinit();
    const arena = result.arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    });
    const root = try object(value);
    result.period = try parsePeriod(root.get("period") orelse return error.InvalidResponse);
    const usage_response = try object(root.get("usage") orelse return error.InvalidResponse);
    if (optionalBool(usage_response.get("limitReached")) orelse false) {
        return error.TruncatedResponse;
    }

    var entries: std.ArrayList(Usage) = .empty;
    for ((try array(usage_response.get("timeSeries") orelse return error.InvalidResponse)).items) |series_value| {
        const series = try object(series_value);
        const name = try seriesName(series);
        var amount: i64 = 0;
        for ((try array(series.get("dataPoints") orelse return error.InvalidResponse)).items) |point_value| {
            const point = try object(point_value);
            const values = try array(point.get("values") orelse return error.InvalidResponse);
            if (values.items.len == 0) return error.InvalidResponse;
            amount = std.math.add(i64, amount, try numberMicros(values.items[0])) catch
                return error.AmountOverflow;
        }
        if (amount == 0) continue;
        const existing = for (entries.items) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) break entry;
        } else null;
        if (existing) |entry| {
            entry.amount_micros = std.math.add(i64, entry.amount_micros, amount) catch
                return error.AmountOverflow;
        } else {
            try entries.append(arena, .{ .name = name, .amount_micros = amount });
        }
    }
    result.usage = try entries.toOwnedSlice(arena);
    std.mem.sort(Usage, result.usage, {}, amountDescending);

    const balance = try object(root.get("balance") orelse return error.InvalidResponse);
    const total = try object(balance.get("total") orelse return error.InvalidResponse);
    const ledger_micros = try centsMicros(total.get("val") orelse return error.InvalidAmount);
    result.credit_remaining_micros = @max(
        std.math.negate(ledger_micros) catch return error.AmountOverflow,
        0,
    );
    return result;
}

fn seriesName(series: std.json.ObjectMap) ![]const u8 {
    if (series.get("groupLabels")) |labels_value| {
        const labels = try array(labels_value);
        if (labels.items.len > 0) {
            return optionalString(labels.items[0]) orelse return error.InvalidResponse;
        }
    }
    if (series.get("group")) |group_value| {
        const group = try array(group_value);
        if (group.items.len > 0) {
            return optionalString(group.items[0]) orelse return error.InvalidResponse;
        }
    }
    return "Unattributed API usage";
}

fn parsePeriod(value: std.json.Value) !model.Period {
    const period_object = try object(value);
    const period = model.Period{
        .start_unix = try requireI64(period_object.get("start_unix") orelse
            return error.InvalidResponse),
        .end_exclusive_unix = try requireI64(period_object.get("end_exclusive_unix") orelse
            return error.InvalidResponse),
    };
    try period.validate();
    return period;
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidResponse;
    return value.object;
}

fn array(value: std.json.Value) !std.json.Array {
    if (value != .array) return error.InvalidResponse;
    return value.array;
}

fn optionalString(value: ?std.json.Value) ?[]const u8 {
    const found = value orelse return null;
    return if (found == .string) found.string else null;
}

fn optionalBool(value: ?std.json.Value) ?bool {
    const found = value orelse return null;
    return if (found == .bool) found.bool else null;
}

fn requireI64(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |integer| integer,
        .number_string, .string => |number| std.fmt.parseInt(i64, number, 10),
        else => error.InvalidResponse,
    };
}

fn numberMicros(value: std.json.Value) !i64 {
    return switch (value) {
        .number_string, .string => |number| money.parseRoundedMicros(number),
        .integer => |integer| std.math.mul(i64, integer, money.micros_per_unit) catch
            error.AmountOverflow,
        else => error.InvalidAmount,
    };
}

fn centsMicros(value: std.json.Value) !i64 {
    const cents = switch (value) {
        .number_string, .string => |number| try std.fmt.parseInt(i64, number, 10),
        .integer => |integer| integer,
        else => return error.InvalidAmount,
    };
    return std.math.mul(i64, cents, money.micros_per_unit / 100) catch
        error.AmountOverflow;
}

fn amountDescending(_: void, left: Usage, right: Usage) bool {
    return left.amount_micros > right.amount_micros;
}

test "xAI API aggregates management usage and inverts the credit ledger" {
    var provider = XAIAPI.init();
    defer provider.deinit();
    try provider.ingest(std.testing.allocator, "billing",
        \\{"period":{"start_unix":1,"end_exclusive_unix":200},
        \\ "usage":{"timeSeries":[
        \\  {"groupLabels":["Chat grok-4"],"dataPoints":[{"values":[0.75]},{"values":[0.25]}]},
        \\  {"groupLabels":["Image"],"dataPoints":[{"values":[0.5]}]}],"limitReached":false},
        \\ "balance":{"total":{"val":"-1000"}}}
    , 100);
    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 200,
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1_500_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(?i64, 10_000_000), report.summary.credit_remaining_micros);
    try std.testing.expectEqualStrings("Chat grok-4", report.line_items[0].description);
}

test "xAI API rejects truncated usage reports" {
    var provider = XAIAPI.init();
    defer provider.deinit();
    try std.testing.expectError(error.TruncatedResponse, provider.ingest(std.testing.allocator, "billing",
        \\{"period":{"start_unix":1,"end_exclusive_unix":2},"usage":{"timeSeries":[],"limitReached":true},"balance":{"total":{"val":"0"}}}
    , 1));
}
