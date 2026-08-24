const std = @import("std");
const model = @import("../model.zig");
const money = @import("../money.zig");

const Cost = struct {
    id: []const u8,
    description: []const u8,
    workspace: []const u8,
    amount_micros: i64,
};

const ModelTokens = struct {
    model: []const u8,
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_creation: u64 = 0,
};

const OwnedSnapshot = struct {
    arena: std.heap.ArenaAllocator,
    period: model.Period,
    costs: []Cost,
    models: []ModelTokens,
    updated_at_unix: i64,

    fn deinit(self: *OwnedSnapshot) void {
        self.arena.deinit();
    }
};

pub const AnthropicAPI = struct {
    snapshot: ?OwnedSnapshot = null,

    pub fn init() AnthropicAPI {
        return .{};
    }

    pub fn deinit(self: *AnthropicAPI) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.snapshot = null;
    }

    pub fn metadata(_: *const AnthropicAPI) model.ProviderMetadata {
        return .{ .id = "anthropic-api", .display_name = "Anthropic API", .kind = .ai };
    }

    pub fn ingest(
        self: *AnthropicAPI,
        allocator: std.mem.Allocator,
        document_id: []const u8,
        payload: []const u8,
        received_at_unix: i64,
    ) !void {
        if (!std.mem.eql(u8, document_id, "organization")) {
            return error.UnsupportedDocument;
        }
        var replacement = try parseSnapshot(allocator, payload, received_at_unix);
        errdefer replacement.deinit();
        if (self.snapshot) |*existing| existing.deinit();
        self.snapshot = replacement;
    }

    pub fn collect(
        self: *AnthropicAPI,
        allocator: std.mem.Allocator,
        _: model.Period,
    ) !model.ProviderReport {
        const snapshot = self.snapshot orelse return error.NotFetched;
        const resources = try allocator.alloc(model.Resource, snapshot.models.len);
        errdefer allocator.free(resources);
        for (snapshot.models, 0..) |usage, index| {
            resources[index] = .{
                .id = usage.model,
                .name = usage.model,
                .kind = "model",
                .status = .active,
            };
        }
        const line_items = try allocator.alloc(model.CostLineItem, snapshot.costs.len);
        errdefer allocator.free(line_items);
        var current: i64 = 0;
        for (snapshot.costs, 0..) |cost, index| {
            current = std.math.add(i64, current, cost.amount_micros) catch
                return error.AmountOverflow;
            line_items[index] = .{
                .id = cost.id,
                .description = cost.description,
                .service = cost.workspace,
                .amount_micros = cost.amount_micros,
                .currency = "USD",
            };
        }
        var tokens = model.TokenUsage{
            .period = snapshot.period,
            .source = "Anthropic organization usage API",
            .updated_at_unix = snapshot.updated_at_unix,
        };
        for (snapshot.models) |usage| {
            tokens.input_tokens +|= usage.input;
            tokens.output_tokens +|= usage.output;
            tokens.cache_read_tokens +|= usage.cache_read;
            tokens.cache_creation_tokens +|= usage.cache_creation;
        }

        return .{
            .summary = .{
                .id = "anthropic-api",
                .display_name = "Anthropic API",
                .kind = .ai,
                .currency = "USD",
                .current_cost_micros = current,
                .updated_at_unix = snapshot.updated_at_unix,
            },
            .resources = resources,
            .line_items = line_items,
            .token_usage = tokens,
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
        .costs = &.{},
        .models = &.{},
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

    var costs: std.ArrayList(Cost) = .empty;
    for ((try array(root.get("cost_pages") orelse return error.InvalidResponse)).items) |page_value| {
        const page = try object(page_value);
        for ((try array(page.get("data") orelse return error.InvalidResponse)).items) |bucket_value| {
            const bucket = try object(bucket_value);
            for ((try array(bucket.get("results") orelse return error.InvalidResponse)).items) |entry_value| {
                const entry = try object(entry_value);
                const currency = optionalString(entry.get("currency")) orelse
                    return error.InvalidCurrency;
                if (!std.ascii.eqlIgnoreCase(currency, "USD")) return error.InvalidCurrency;
                const description = optionalString(entry.get("description")) orelse
                    optionalString(entry.get("model")) orelse "API usage";
                const workspace = optionalString(entry.get("workspace_id")) orelse "Organization";
                const micros = try fractionalCentsToMicros(
                    entry.get("amount") orelse return error.InvalidAmount,
                );
                const existing = for (costs.items) |*cost| {
                    if (std.mem.eql(u8, cost.description, description) and
                        std.mem.eql(u8, cost.workspace, workspace)) break cost;
                } else null;
                if (existing) |cost| {
                    cost.amount_micros = std.math.add(i64, cost.amount_micros, micros) catch
                        return error.AmountOverflow;
                } else {
                    try costs.append(arena, .{
                        .id = try std.fmt.allocPrint(arena, "{s}:{s}", .{ workspace, description }),
                        .description = description,
                        .workspace = workspace,
                        .amount_micros = micros,
                    });
                }
            }
        }
    }
    result.costs = try costs.toOwnedSlice(arena);
    std.mem.sort(Cost, result.costs, {}, costDescending);

    var models: std.ArrayList(ModelTokens) = .empty;
    for ((try array(root.get("usage_pages") orelse return error.InvalidResponse)).items) |page_value| {
        const page = try object(page_value);
        for ((try array(page.get("data") orelse return error.InvalidResponse)).items) |bucket_value| {
            const bucket = try object(bucket_value);
            for ((try array(bucket.get("results") orelse return error.InvalidResponse)).items) |entry_value| {
                const entry = try object(entry_value);
                const name = optionalString(entry.get("model")) orelse "Unattributed";
                const existing = for (models.items) |*usage| {
                    if (std.mem.eql(u8, usage.model, name)) break usage;
                } else null;
                const usage = existing orelse blk: {
                    try models.append(arena, .{ .model = name });
                    break :blk &models.items[models.items.len - 1];
                };
                usage.input +|= try optionalU64(entry.get("uncached_input_tokens")) orelse 0;
                usage.output +|= try optionalU64(entry.get("output_tokens")) orelse 0;
                usage.cache_read +|=
                    try optionalU64(entry.get("cache_read_input_tokens")) orelse 0;
                if (entry.get("cache_creation")) |creation_value| {
                    const creation = try object(creation_value);
                    usage.cache_creation +|=
                        try optionalU64(creation.get("ephemeral_1h_input_tokens")) orelse 0;
                    usage.cache_creation +|=
                        try optionalU64(creation.get("ephemeral_5m_input_tokens")) orelse 0;
                }
            }
        }
    }
    result.models = try models.toOwnedSlice(arena);
    std.mem.sort(ModelTokens, result.models, {}, modelAscending);
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

fn optionalU64(value: ?std.json.Value) !?u64 {
    const found = value orelse return null;
    if (found == .null) return null;
    return switch (found) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.InvalidAmount,
        .number_string, .string => |number| @as(?u64, try std.fmt.parseInt(u64, number, 10)),
        else => error.InvalidAmount,
    };
}

fn parsePeriod(value: std.json.Value) !model.Period {
    const value_object = try object(value);
    const period = model.Period{
        .start_unix = try requireI64(value_object.get("start_unix") orelse
            return error.InvalidResponse),
        .end_exclusive_unix = try requireI64(value_object.get("end_exclusive_unix") orelse
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

fn costDescending(_: void, left: Cost, right: Cost) bool {
    return left.amount_micros > right.amount_micros;
}

fn modelAscending(_: void, left: ModelTokens, right: ModelTokens) bool {
    return std.mem.lessThan(u8, left.model, right.model);
}

test "Anthropic API converts fractional cents and reports cache tokens" {
    var provider = AnthropicAPI.init();
    defer provider.deinit();
    try provider.ingest(std.testing.allocator, "organization",
        \\{"period":{"start_unix":1,"end_exclusive_unix":200},
        \\ "cost_pages":[{"data":[{"results":[{"amount":"125.5","currency":"USD","description":"Tokens","workspace_id":"wrk_a"}]}]}],
        \\ "usage_pages":[{"data":[{"results":[{"model":"claude","uncached_input_tokens":80,"output_tokens":10,"cache_read_input_tokens":20,"cache_creation":{"ephemeral_5m_input_tokens":5,"ephemeral_1h_input_tokens":2}}]}]}]}
    , 100);
    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 200,
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1_255_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(u64, 20), report.token_usage.?.cache_read_tokens);
    try std.testing.expectEqual(@as(u64, 7), report.token_usage.?.cache_creation_tokens);
}
