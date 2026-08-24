const std = @import("std");
const model = @import("../model.zig");
const money = @import("../money.zig");

const ServiceCost = struct {
    name: []const u8,
    billed_cost_micros: i64,
};

const OwnedBilling = struct {
    arena: std.heap.ArenaAllocator,
    currency: []const u8,
    month_to_date_micros: i64,
    updated_at_unix: i64,
    services: []ServiceCost,

    fn deinit(self: *OwnedBilling) void {
        self.arena.deinit();
    }
};

pub const Vercel = struct {
    owned_billing: ?OwnedBilling = null,

    pub fn init() Vercel {
        return .{};
    }

    pub fn deinit(self: *Vercel) void {
        if (self.owned_billing) |*owned| owned.deinit();
        self.owned_billing = null;
    }

    pub fn metadata(_: *const Vercel) model.ProviderMetadata {
        return .{
            .id = "vercel",
            .display_name = "Vercel",
            .kind = .developer_tool,
        };
    }

    /// Replaces the current billing state from Vercel's FOCUS v1.3 JSONL
    /// export. BilledCost is the invoice-facing amount after adjustments, so
    /// credit and discount rows remain part of the total instead of being
    /// discarded as negative usage.
    pub fn ingest(
        self: *Vercel,
        allocator: std.mem.Allocator,
        document_id: []const u8,
        payload: []const u8,
        received_at_unix: i64,
    ) !void {
        if (!std.mem.eql(u8, document_id, "charges")) {
            return error.UnsupportedDocument;
        }

        var replacement = try parseCharges(allocator, payload, received_at_unix);
        errdefer replacement.deinit();
        if (self.owned_billing) |*owned| owned.deinit();
        self.owned_billing = replacement;
    }

    pub fn collect(
        self: *Vercel,
        allocator: std.mem.Allocator,
        _: model.Period,
    ) !model.ProviderReport {
        const billing = self.owned_billing orelse return error.NotFetched;
        const resources = try allocator.alloc(model.Resource, 0);
        errdefer allocator.free(resources);
        const line_items = try allocator.alloc(model.CostLineItem, billing.services.len);
        errdefer allocator.free(line_items);

        for (billing.services, 0..) |service, index| {
            line_items[index] = .{
                .id = service.name,
                .description = service.name,
                .service = service.name,
                .amount_micros = service.billed_cost_micros,
                .detail = "FOCUS billed cost",
            };
        }

        return .{
            .summary = .{
                .id = "vercel",
                .display_name = "Vercel",
                .kind = .developer_tool,
                .currency = billing.currency,
                .current_cost_micros = billing.month_to_date_micros,
                .updated_at_unix = billing.updated_at_unix,
            },
            .resources = resources,
            .line_items = line_items,
        };
    }
};

fn parseCharges(
    allocator: std.mem.Allocator,
    payload: []const u8,
    received_at_unix: i64,
) !OwnedBilling {
    var replacement = OwnedBilling{
        .arena = .init(allocator),
        .currency = "USD",
        .month_to_date_micros = 0,
        .updated_at_unix = received_at_unix,
        .services = undefined,
    };
    errdefer replacement.deinit();
    const arena = replacement.arena.allocator();

    var currency: ?[]const u8 = null;
    var services: std.ArrayList(ServiceCost) = .empty;
    var lines = std.mem.splitScalar(u8, payload, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        try accumulateCharge(
            allocator,
            arena,
            line,
            &currency,
            &replacement.month_to_date_micros,
            &services,
        );
    }

    replacement.currency = currency orelse "USD";
    replacement.services = try services.toOwnedSlice(arena);
    return replacement;
}

fn accumulateCharge(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    line: []const u8,
    currency: *?[]const u8,
    total_micros: *i64,
    services: *std.ArrayList(ServiceCost),
) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    });
    defer parsed.deinit();
    const charge = try requireObject(parsed.value);

    const billing_currency = try requireString(
        charge.get("BillingCurrency") orelse return error.InvalidResponse,
    );
    if (billing_currency.len != 3) return error.InvalidCurrency;
    if (currency.*) |existing| {
        if (!std.mem.eql(u8, existing, billing_currency)) {
            return error.MixedCurrencies;
        }
    } else {
        currency.* = try arena.dupe(u8, billing_currency);
    }

    const billed_cost = try parseMoneyValue(
        charge.get("BilledCost") orelse return error.InvalidResponse,
    );
    total_micros.* = std.math.add(i64, total_micros.*, billed_cost) catch
        return error.AmountOverflow;

    const service_name = optionalNonEmptyString(charge.get("ServiceName")) orelse
        optionalNonEmptyString(charge.get("ChargeDescription")) orelse
        "Vercel usage";
    for (services.items) |*service| {
        if (!std.mem.eql(u8, service.name, service_name)) continue;
        service.billed_cost_micros = std.math.add(
            i64,
            service.billed_cost_micros,
            billed_cost,
        ) catch return error.AmountOverflow;
        return;
    }
    try services.append(arena, .{
        .name = try arena.dupe(u8, service_name),
        .billed_cost_micros = billed_cost,
    });
}

fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidResponse;
    return value.object;
}

fn requireString(value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidResponse;
    return value.string;
}

fn optionalNonEmptyString(value: ?std.json.Value) ?[]const u8 {
    const found = value orelse return null;
    if (found != .string or found.string.len == 0) return null;
    return found.string;
}

fn parseMoneyValue(value: std.json.Value) !i64 {
    return switch (value) {
        .number_string, .string => |number| money.parseRoundedMicros(number),
        .integer => |integer| std.math.mul(i64, integer, money.micros_per_unit) catch
            error.AmountOverflow,
        else => error.InvalidAmount,
    };
}

test "Vercel sums FOCUS billed cost by service including credit adjustments" {
    var provider = Vercel.init();
    defer provider.deinit();

    try provider.ingest(std.testing.allocator, "charges",
        \\{"BillingCurrency":"USD","BilledCost":5.25,"EffectiveCost":8.00,"ServiceName":"Functions"}
        \\{"BillingCurrency":"USD","BilledCost":"1.5000004","ServiceName":"Functions"}
        \\{"BillingCurrency":"USD","BilledCost":-2,"ChargeDescription":"Included credits"}
    , 100);

    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 200,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 4_750_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(?i64, null), report.summary.projected_cost_micros);
    try std.testing.expectEqualStrings("USD", report.summary.currency);
    try std.testing.expectEqual(@as(usize, 2), report.line_items.len);
    try std.testing.expectEqualStrings("Functions", report.line_items[0].service);
    try std.testing.expectEqual(@as(i64, 6_750_000), report.line_items[0].amount_micros);
    try std.testing.expectEqual(@as(i64, -2_000_000), report.line_items[1].amount_micros);
}

test "Vercel accepts an empty successful charge export" {
    var provider = Vercel.init();
    defer provider.deinit();

    try provider.ingest(std.testing.allocator, "charges", "", 100);
    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 200,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 0), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(usize, 0), report.line_items.len);
}

test "Vercel rejects mixed billing currencies" {
    var provider = Vercel.init();
    defer provider.deinit();

    try std.testing.expectError(error.MixedCurrencies, provider.ingest(
        std.testing.allocator,
        "charges",
        \\{"BillingCurrency":"USD","BilledCost":1,"ServiceName":"Functions"}
        \\{"BillingCurrency":"EUR","BilledCost":1,"ServiceName":"Functions"}
    ,
        100,
    ));
}
