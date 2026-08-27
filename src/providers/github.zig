const std = @import("std");
const model = @import("../model.zig");
const money = @import("../money.zig");

const ProductCost = struct {
    id: []const u8,
    organization: []const u8,
    product: []const u8,
    sku: []const u8,
    amount_micros: i64,
};

pub const OrganizationUsage = struct {
    organization: []const u8,
    payload: []const u8,
};

const OwnedUsage = struct {
    arena: std.heap.ArenaAllocator,
    costs: []ProductCost,
    updated_at_unix: i64,

    fn deinit(self: *OwnedUsage) void {
        self.arena.deinit();
    }
};

pub const GitHub = struct {
    usage: ?OwnedUsage = null,

    pub fn init() GitHub {
        return .{};
    }

    pub fn deinit(self: *GitHub) void {
        if (self.usage) |*usage| usage.deinit();
        self.usage = null;
    }

    pub fn metadata(_: *const GitHub) model.ProviderMetadata {
        return .{ .id = "github", .display_name = "GitHub", .kind = .developer_tool };
    }

    pub fn ingest(
        self: *GitHub,
        allocator: std.mem.Allocator,
        document_id: []const u8,
        payload: []const u8,
        received_at_unix: i64,
    ) !void {
        if (!std.mem.eql(u8, document_id, "billing-usage")) {
            return error.UnsupportedDocument;
        }
        var replacement = try parseUsage(
            allocator,
            &.{.{ .organization = "", .payload = payload }},
            received_at_unix,
        );
        errdefer replacement.deinit();
        if (self.usage) |*existing| existing.deinit();
        self.usage = replacement;
    }

    pub fn ingestOrganizations(
        self: *GitHub,
        allocator: std.mem.Allocator,
        documents: []const OrganizationUsage,
        received_at_unix: i64,
    ) !void {
        if (documents.len == 0) return error.InvalidResponse;
        var replacement = try parseUsage(allocator, documents, received_at_unix);
        errdefer replacement.deinit();
        if (self.usage) |*existing| existing.deinit();
        self.usage = replacement;
    }

    pub fn collect(
        self: *GitHub,
        allocator: std.mem.Allocator,
        _: model.Period,
    ) !model.ProviderReport {
        const usage = self.usage orelse return error.NotFetched;
        const resources = try allocator.alloc(model.Resource, usage.costs.len);
        errdefer allocator.free(resources);
        const line_items = try allocator.alloc(model.CostLineItem, usage.costs.len);
        errdefer allocator.free(line_items);
        var current: i64 = 0;
        for (usage.costs, 0..) |cost, index| {
            current = std.math.add(i64, current, cost.amount_micros) catch
                return error.AmountOverflow;
            resources[index] = .{
                .id = cost.id,
                .name = cost.product,
                .kind = "product",
                .status = .active,
            };
            line_items[index] = .{
                .id = cost.id,
                .description = cost.sku,
                .service = cost.product,
                .amount_micros = cost.amount_micros,
                .currency = "USD",
                .detail = if (cost.organization.len == 0) null else cost.organization,
            };
        }
        return .{
            .summary = .{
                .id = "github",
                .display_name = "GitHub",
                .kind = .developer_tool,
                .currency = "USD",
                .current_cost_micros = current,
                .updated_at_unix = usage.updated_at_unix,
            },
            .resources = resources,
            .line_items = line_items,
        };
    }
};

fn parseUsage(
    allocator: std.mem.Allocator,
    documents: []const OrganizationUsage,
    received_at_unix: i64,
) !OwnedUsage {
    var result = OwnedUsage{
        .arena = .init(allocator),
        .costs = &.{},
        .updated_at_unix = received_at_unix,
    };
    errdefer result.deinit();
    const arena = result.arena.allocator();
    var costs: std.ArrayList(ProductCost) = .empty;
    for (documents) |document| {
        try appendUsageDocument(arena, &costs, document);
    }
    result.costs = try costs.toOwnedSlice(arena);
    std.mem.sort(ProductCost, result.costs, {}, costDescending);
    return result;
}

fn appendUsageDocument(
    arena: std.mem.Allocator,
    costs: *std.ArrayList(ProductCost),
    document: OrganizationUsage,
) !void {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, document.payload, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    });
    if (value != .object) return error.InvalidResponse;
    const items_value = value.object.get("usageItems") orelse return error.InvalidResponse;
    if (items_value != .array) return error.InvalidResponse;
    const organization = try arena.dupe(u8, document.organization);
    for (items_value.array.items) |item_value| {
        if (item_value != .object) return error.InvalidResponse;
        const item = item_value.object;
        const product = optionalString(item.get("product")) orelse "GitHub";
        const sku = optionalString(item.get("sku")) orelse "Usage";
        const amount = try numberMicros(item.get("netAmount") orelse return error.InvalidAmount);
        const existing = for (costs.items) |*cost| {
            if (std.mem.eql(u8, cost.organization, organization) and
                std.mem.eql(u8, cost.product, product) and
                std.mem.eql(u8, cost.sku, sku)) break cost;
        } else null;
        if (existing) |cost| {
            cost.amount_micros = std.math.add(i64, cost.amount_micros, amount) catch
                return error.AmountOverflow;
        } else {
            const id = if (organization.len == 0)
                try std.fmt.allocPrint(arena, "{s}:{s}", .{ product, sku })
            else
                try std.fmt.allocPrint(
                    arena,
                    "{s}:{s}:{s}",
                    .{ organization, product, sku },
                );
            try costs.append(arena, .{
                .id = id,
                .organization = organization,
                .product = product,
                .sku = sku,
                .amount_micros = amount,
            });
        }
    }
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

fn costDescending(_: void, left: ProductCost, right: ProductCost) bool {
    return left.amount_micros > right.amount_micros;
}

test "GitHub aggregates enhanced billing usage by product and SKU" {
    var provider = GitHub.init();
    defer provider.deinit();
    try provider.ingest(std.testing.allocator, "billing-usage",
        \\{"usageItems":[
        \\ {"product":"Actions","sku":"Actions Linux","netAmount":0.8},
        \\ {"product":"Actions","sku":"Actions Linux","netAmount":0.2},
        \\ {"product":"Copilot","sku":"Premium requests","netAmount":2.5}]}
    , 100);
    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 200,
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 3_500_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(usize, 2), report.line_items.len);
}

test "GitHub keeps organization costs separate while aggregating selected organizations" {
    var provider = GitHub.init();
    defer provider.deinit();
    try provider.ingestOrganizations(std.testing.allocator, &.{
        .{
            .organization = "alpha",
            .payload =
            \\{"usageItems":[{"product":"Actions","sku":"Linux","netAmount":1.25}]}
            ,
        },
        .{
            .organization = "beta",
            .payload =
            \\{"usageItems":[{"product":"Actions","sku":"Linux","netAmount":2.75}]}
            ,
        },
    }, 100);
    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 200,
    });
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 4_000_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(usize, 2), report.line_items.len);
    try std.testing.expectEqualStrings("beta", report.line_items[0].detail.?);
    try std.testing.expectEqualStrings("alpha", report.line_items[1].detail.?);
}
