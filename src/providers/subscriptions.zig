const std = @import("std");
const model = @import("../model.zig");
const money = @import("../money.zig");

const Cadence = enum {
    monthly,
    quarterly,
    yearly,
};

const Subscription = struct {
    id: []const u8,
    name: []const u8,
    currency: []const u8,
    cadence: Cadence,
    monthly_micros: i64,
};

const OwnedSubscriptions = struct {
    arena: std.heap.ArenaAllocator,
    items: []Subscription,
    updated_at_unix: i64,

    fn deinit(self: *OwnedSubscriptions) void {
        self.arena.deinit();
    }
};

pub const Subscriptions = struct {
    owned: ?OwnedSubscriptions = null,

    pub fn init() Subscriptions {
        return .{};
    }

    pub fn deinit(self: *Subscriptions) void {
        if (self.owned) |*owned| owned.deinit();
        self.owned = null;
    }

    pub fn metadata(_: *const Subscriptions) model.ProviderMetadata {
        return .{
            .id = "subscriptions",
            .display_name = "Subscriptions",
            .kind = .subscription,
        };
    }

    pub fn ingest(
        self: *Subscriptions,
        allocator: std.mem.Allocator,
        document_id: []const u8,
        payload: []const u8,
        received_at_unix: i64,
    ) !void {
        if (!std.mem.eql(u8, document_id, "subscriptions")) {
            return error.UnsupportedDocument;
        }
        var replacement = try parseSubscriptions(allocator, payload, received_at_unix);
        errdefer replacement.deinit();
        if (self.owned) |*existing| existing.deinit();
        self.owned = replacement;
    }

    pub fn collect(
        self: *Subscriptions,
        allocator: std.mem.Allocator,
        _: model.Period,
    ) !model.ProviderReport {
        const owned = self.owned orelse return error.NotFetched;
        if (owned.items.len == 0) return error.NoSubscriptions;

        const resources = try allocator.alloc(model.Resource, owned.items.len);
        errdefer allocator.free(resources);
        const line_items = try allocator.alloc(model.CostLineItem, owned.items.len);
        errdefer allocator.free(line_items);
        var financials: std.ArrayList(model.FinancialSummary) = .empty;
        errdefer financials.deinit(allocator);

        for (owned.items, 0..) |item, index| {
            resources[index] = .{
                .id = item.id,
                .name = item.name,
                .kind = "subscription",
                .status = .active,
            };
            line_items[index] = .{
                .id = item.id,
                .description = item.name,
                .service = item.currency,
                .amount_micros = item.monthly_micros,
                .currency = item.currency,
                .detail = cadenceLabel(item.cadence),
            };

            const existing = for (financials.items) |*financial| {
                if (std.mem.eql(u8, financial.currency, item.currency)) break financial;
            } else null;
            if (existing) |financial| {
                financial.current_cost_micros = std.math.add(
                    i64,
                    financial.current_cost_micros,
                    item.monthly_micros,
                ) catch return error.AmountOverflow;
                financial.projected_cost_micros = financial.current_cost_micros;
            } else {
                try financials.append(allocator, .{
                    .currency = item.currency,
                    .current_cost_micros = item.monthly_micros,
                    .projected_cost_micros = item.monthly_micros,
                });
            }
        }

        const owned_financials = try financials.toOwnedSlice(allocator);
        errdefer allocator.free(owned_financials);
        std.mem.sort(model.FinancialSummary, owned_financials, {}, financialByCurrency);
        const primary = for (owned_financials) |financial| {
            if (std.mem.eql(u8, financial.currency, "USD")) break financial;
        } else owned_financials[0];
        return .{
            .summary = .{
                .id = "subscriptions",
                .display_name = "Subscriptions",
                .kind = .subscription,
                .currency = primary.currency,
                .current_cost_micros = primary.current_cost_micros,
                .projected_cost_micros = primary.projected_cost_micros,
                .updated_at_unix = owned.updated_at_unix,
            },
            .resources = resources,
            .line_items = line_items,
            .financials = owned_financials,
        };
    }
};

fn parseSubscriptions(
    allocator: std.mem.Allocator,
    payload: []const u8,
    received_at_unix: i64,
) !OwnedSubscriptions {
    const RawSubscription = struct {
        id: []const u8,
        name: []const u8,
        amount: []const u8,
        currency: []const u8,
        cadence: Cadence,
    };
    const Response = struct { subscriptions: []const RawSubscription };

    var owned = OwnedSubscriptions{
        .arena = .init(allocator),
        .items = &.{},
        .updated_at_unix = received_at_unix,
    };
    errdefer owned.deinit();
    const arena = owned.arena.allocator();
    const response = try std.json.parseFromSliceLeaky(Response, arena, payload, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    owned.items = try arena.alloc(Subscription, response.subscriptions.len);
    for (response.subscriptions, 0..) |raw, index| {
        if (raw.id.len == 0 or raw.name.len == 0) return error.InvalidSubscription;
        try validateCurrency(raw.currency);
        const amount = try money.parseMicros(raw.amount);
        if (amount < 0) return error.InvalidAmount;
        owned.items[index] = .{
            .id = raw.id,
            .name = raw.name,
            .currency = raw.currency,
            .cadence = raw.cadence,
            .monthly_micros = try monthlyEquivalent(amount, raw.cadence),
        };
    }
    return owned;
}

fn monthlyEquivalent(amount: i64, cadence: Cadence) !i64 {
    const divisor: i64 = switch (cadence) {
        .monthly => 1,
        .quarterly => 3,
        .yearly => 12,
    };
    const half = @divTrunc(divisor, 2);
    const adjusted = std.math.add(i64, amount, half) catch return error.AmountOverflow;
    return @divTrunc(adjusted, divisor);
}

fn validateCurrency(currency: []const u8) !void {
    if (currency.len != 3) return error.InvalidCurrency;
    for (currency) |character| {
        if (!std.ascii.isUpper(character)) return error.InvalidCurrency;
    }
}

fn cadenceLabel(cadence: Cadence) []const u8 {
    return switch (cadence) {
        .monthly => "monthly",
        .quarterly => "quarterly · monthly equivalent",
        .yearly => "yearly · monthly equivalent",
    };
}

fn financialByCurrency(_: void, left: model.FinancialSummary, right: model.FinancialSummary) bool {
    return std.mem.lessThan(u8, left.currency, right.currency);
}

test "subscriptions normalize cadences and retain separate currencies" {
    var provider = Subscriptions.init();
    defer provider.deinit();
    try provider.ingest(std.testing.allocator, "subscriptions",
        \\{"subscriptions":[
        \\  {"id":"codex","name":"Codex","amount":"20","currency":"USD","cadence":"monthly"},
        \\  {"id":"claude","name":"Claude","amount":"240","currency":"USD","cadence":"yearly"},
        \\  {"id":"tool","name":"Tool","amount":"300","currency":"NOK","cadence":"quarterly"}
        \\]}
    , 100);

    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 200,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), report.financials.len);
    try std.testing.expectEqualStrings("NOK", report.financials[0].currency);
    try std.testing.expectEqual(@as(i64, 100_000_000), report.financials[0].current_cost_micros);
    try std.testing.expectEqual(@as(i64, 40_000_000), report.financials[1].current_cost_micros);
    try std.testing.expectEqualStrings("USD", report.line_items[0].currency.?);
}
