const std = @import("std");
const model = @import("../model.zig");
const money = @import("../money.zig");

const Cost = struct {
    id: []const u8,
    description: []const u8,
    project: []const u8,
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

pub const OpenAIAPI = struct {
    snapshot: ?OwnedSnapshot = null,

    pub fn init() OpenAIAPI {
        return .{};
    }

    pub fn deinit(self: *OpenAIAPI) void {
        if (self.snapshot) |*snapshot| snapshot.deinit();
        self.snapshot = null;
    }

    pub fn metadata(_: *const OpenAIAPI) model.ProviderMetadata {
        return .{ .id = "openai-api", .display_name = "OpenAI API", .kind = .ai };
    }

    pub fn ingest(
        self: *OpenAIAPI,
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
        self: *OpenAIAPI,
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
                .service = cost.project,
                .amount_micros = cost.amount_micros,
                .currency = "USD",
            };
        }

        var tokens = model.TokenUsage{
            .period = snapshot.period,
            .source = "OpenAI organization usage API",
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
                .id = "openai-api",
                .display_name = "OpenAI API",
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
    try parseCostPages(arena, root.get("cost_pages") orelse return error.InvalidResponse, &costs);
    result.costs = try costs.toOwnedSlice(arena);
    std.mem.sort(Cost, result.costs, {}, costDescending);

    var models: std.ArrayList(ModelTokens) = .empty;
    try parseUsagePages(arena, root.get("usage_pages") orelse return error.InvalidResponse, &models);
    result.models = try models.toOwnedSlice(arena);
    std.mem.sort(ModelTokens, result.models, {}, modelAscending);
    return result;
}

fn parseCostPages(
    arena: std.mem.Allocator,
    pages_value: std.json.Value,
    costs: *std.ArrayList(Cost),
) !void {
    const pages = try array(pages_value);
    for (pages.items) |page_value| {
        const page = try object(page_value);
        for ((try array(page.get("data") orelse return error.InvalidResponse)).items) |bucket_value| {
            const bucket = try object(bucket_value);
            for ((try array(bucket.get("results") orelse return error.InvalidResponse)).items) |entry_value| {
                const entry = try object(entry_value);
                const amount = try object(entry.get("amount") orelse return error.InvalidResponse);
                const currency = optionalString(amount.get("currency")) orelse
                    return error.InvalidCurrency;
                if (!std.ascii.eqlIgnoreCase(currency, "USD")) return error.InvalidCurrency;
                const description = optionalString(entry.get("line_item")) orelse "API usage";
                const project = optionalString(entry.get("project_id")) orelse "Organization";
                const micros = try numberMicros(amount.get("value") orelse return error.InvalidAmount);
                const existing = for (costs.items) |*cost| {
                    if (std.mem.eql(u8, cost.description, description) and
                        std.mem.eql(u8, cost.project, project)) break cost;
                } else null;
                if (existing) |cost| {
                    cost.amount_micros = std.math.add(i64, cost.amount_micros, micros) catch
                        return error.AmountOverflow;
                } else {
                    try costs.append(arena, .{
                        .id = try std.fmt.allocPrint(arena, "{s}:{s}", .{ project, description }),
                        .description = description,
                        .project = project,
                        .amount_micros = micros,
                    });
                }
            }
        }
    }
}

fn parseUsagePages(
    arena: std.mem.Allocator,
    pages_value: std.json.Value,
    models: *std.ArrayList(ModelTokens),
) !void {
    const pages = try array(pages_value);
    for (pages.items) |page_value| {
        const page = try object(page_value);
        for ((try array(page.get("data") orelse return error.InvalidResponse)).items) |bucket_value| {
            const bucket = try object(bucket_value);
            for ((try array(bucket.get("results") orelse return error.InvalidResponse)).items) |entry_value| {
                const entry = try object(entry_value);
                const name = optionalString(entry.get("model")) orelse "Unattributed";
                const cached = try optionalU64(entry.get("input_cached_tokens")) orelse 0;
                const input = try optionalU64(entry.get("input_uncached_tokens")) orelse blk: {
                    const total = try optionalU64(entry.get("input_tokens")) orelse 0;
                    break :blk total -| cached;
                };
                const existing = for (models.items) |*usage| {
                    if (std.mem.eql(u8, usage.model, name)) break usage;
                } else null;
                const usage = existing orelse blk: {
                    try models.append(arena, .{ .model = name });
                    break :blk &models.items[models.items.len - 1];
                };
                usage.input +|= input;
                usage.output +|= try optionalU64(entry.get("output_tokens")) orelse 0;
                usage.cache_read +|= cached;
                usage.cache_creation +|=
                    try optionalU64(entry.get("input_cache_write_tokens")) orelse 0;
            }
        }
    }
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

fn numberMicros(value: std.json.Value) !i64 {
    return switch (value) {
        .number_string, .string => |number| money.parseRoundedMicros(number),
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

test "OpenAI API aggregates organization cost and model tokens" {
    var provider = OpenAIAPI.init();
    defer provider.deinit();
    try provider.ingest(std.testing.allocator, "organization",
        \\{"period":{"start_unix":1,"end_exclusive_unix":200},
        \\ "cost_pages":[{"data":[{"results":[{"amount":{"value":1.25,"currency":"usd"},"line_item":"Responses","project_id":"proj_a"}]}]}],
        \\ "usage_pages":[{"data":[{"results":[{"model":"gpt","input_tokens":100,"input_cached_tokens":20,"output_tokens":10}]}]}]}
    , 100);
    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 200,
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1_250_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(u64, 80), report.token_usage.?.input_tokens);
    try std.testing.expectEqual(@as(u64, 20), report.token_usage.?.cache_read_tokens);
}
