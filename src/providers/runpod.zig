const std = @import("std");
const model = @import("../model.zig");
const money = @import("../money.zig");

pub const Account = struct {
    currency: []const u8 = "USD",
    credit_remaining_micros: i64,
    current_spend_per_hour_micros: i64,
    month_to_date_micros: i64,
    pod_micros: i64,
    serverless_micros: i64,
    network_volume_micros: i64,
    updated_at_unix: i64,
};

pub const Runpod = struct {
    account: ?Account = null,

    pub fn init() Runpod {
        return .{};
    }

    pub fn deinit(_: *Runpod) void {}

    pub fn metadata(_: *const Runpod) model.ProviderMetadata {
        return .{
            .id = "runpod",
            .display_name = "Runpod",
            .kind = .ai,
        };
    }

    /// Replaces the provider state from one atomic snapshot containing the
    /// account GraphQL response and all three Runpod billing response arrays.
    pub fn ingest(
        self: *Runpod,
        allocator: std.mem.Allocator,
        document_id: []const u8,
        payload: []const u8,
        received_at_unix: i64,
    ) !void {
        if (!std.mem.eql(u8, document_id, "snapshot")) {
            return error.UnsupportedDocument;
        }

        self.account = try parseSnapshot(allocator, payload, received_at_unix);
    }

    pub fn collect(
        self: *Runpod,
        allocator: std.mem.Allocator,
        period: model.Period,
    ) !model.ProviderReport {
        const account = self.account orelse return error.NotFetched;
        const resources = try allocator.alloc(model.Resource, 0);
        errdefer allocator.free(resources);
        const line_items = try allocator.alloc(model.CostLineItem, 3);
        errdefer allocator.free(line_items);

        line_items[0] = .{
            .id = "runpod-pods",
            .description = "Pod compute and attached storage",
            .service = "Pods",
            .amount_micros = account.pod_micros,
        };
        line_items[1] = .{
            .id = "runpod-serverless",
            .description = "Serverless workers",
            .service = "Serverless",
            .amount_micros = account.serverless_micros,
        };
        line_items[2] = .{
            .id = "runpod-network-volumes",
            .description = "Network volume storage",
            .service = "Network volumes",
            .amount_micros = account.network_volume_micros,
        };

        return .{
            .summary = .{
                .id = "runpod",
                .display_name = "Runpod",
                .kind = .ai,
                .currency = account.currency,
                .current_cost_micros = account.month_to_date_micros,
                .projected_cost_micros = projectedCost(account, period),
                .credit_remaining_micros = account.credit_remaining_micros,
                .updated_at_unix = account.updated_at_unix,
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
) !Account {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    });
    defer parsed.deinit();

    const snapshot = try requireObject(parsed.value);
    const account_document = try requireObject(
        snapshot.get("account") orelse return error.InvalidResponse,
    );
    if (account_document.get("errors")) |errors_value| {
        if (errors_value != .array) return error.InvalidResponse;
        if (errors_value.array.items.len > 0) return error.ApiFailure;
    }
    const data = try requireObject(
        account_document.get("data") orelse return error.InvalidResponse,
    );
    const myself = try requireObject(
        data.get("myself") orelse return error.InvalidResponse,
    );

    const balance = try parseMoneyValue(
        myself.get("clientBalance") orelse return error.InvalidResponse,
    );
    const hourly_spend = try parseMoneyValue(
        myself.get("currentSpendPerHr") orelse return error.InvalidResponse,
    );
    if (hourly_spend < 0) return error.InvalidAmount;

    const pod_micros = try sumBillingRecords(
        snapshot.get("pods") orelse return error.InvalidResponse,
    );
    const serverless_micros = try sumBillingRecords(
        snapshot.get("endpoints") orelse return error.InvalidResponse,
    );
    const network_volume_micros = try sumBillingRecords(
        snapshot.get("networkVolumes") orelse return error.InvalidResponse,
    );
    const compute_micros = std.math.add(i64, pod_micros, serverless_micros) catch
        return error.AmountOverflow;
    const month_to_date_micros = std.math.add(
        i64,
        compute_micros,
        network_volume_micros,
    ) catch return error.AmountOverflow;

    return .{
        .credit_remaining_micros = @max(balance, 0),
        .current_spend_per_hour_micros = hourly_spend,
        .month_to_date_micros = month_to_date_micros,
        .pod_micros = pod_micros,
        .serverless_micros = serverless_micros,
        .network_volume_micros = network_volume_micros,
        .updated_at_unix = received_at_unix,
    };
}

fn sumBillingRecords(value: std.json.Value) !i64 {
    if (value != .array) return error.InvalidResponse;

    var total: i64 = 0;
    for (value.array.items) |record_value| {
        const record = try requireObject(record_value);
        const amount = try parseMoneyValue(
            record.get("amount") orelse return error.InvalidResponse,
        );
        if (amount < 0) return error.InvalidAmount;
        total = std.math.add(i64, total, amount) catch return error.AmountOverflow;
    }
    return total;
}

fn requireObject(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidResponse;
    return value.object;
}

fn parseMoneyValue(value: std.json.Value) !i64 {
    return switch (value) {
        .number_string => |number| money.parseRoundedMicros(number),
        .string => |number| money.parseRoundedMicros(number),
        .integer => |integer| std.math.mul(i64, integer, money.micros_per_unit) catch
            error.AmountOverflow,
        else => error.InvalidAmount,
    };
}

fn projectedCost(account: Account, period: model.Period) ?i64 {
    const remaining_seconds = period.end_exclusive_unix - account.updated_at_unix;
    if (remaining_seconds <= 0) return account.month_to_date_micros;

    const projected_remaining = @divTrunc(
        @as(i128, account.current_spend_per_hour_micros) * remaining_seconds,
        60 * 60,
    );
    const projected = @as(i128, account.month_to_date_micros) + projected_remaining;
    if (projected > std.math.maxInt(i64)) return std.math.maxInt(i64);
    return @intCast(projected);
}

test "Runpod maps billing history, current burn, and prepaid credit" {
    var provider = Runpod.init();
    defer provider.deinit();

    try provider.ingest(std.testing.allocator, "snapshot",
        \\{"account":{"data":{"myself":{"clientBalance":42.125,"currentSpendPerHr":1.5}}},"pods":[{"amount":10.25},{"amount":2}],"endpoints":[{"amount":0.75}],"networkVolumes":[{"amount":4}]}
    , 3_700);

    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 100,
        .end_exclusive_unix = 7_300,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 17_000_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(?i64, 18_500_000), report.summary.projected_cost_micros);
    try std.testing.expectEqual(@as(?i64, 42_125_000), report.summary.credit_remaining_micros);
    try std.testing.expectEqual(@as(usize, 3), report.line_items.len);
    try std.testing.expectEqual(@as(i64, 12_250_000), report.line_items[0].amount_micros);
}

test "Runpod rounds provider precision to fixed-point micros" {
    var provider = Runpod.init();
    defer provider.deinit();

    try provider.ingest(std.testing.allocator, "snapshot",
        \\{"account":{"data":{"myself":{"clientBalance":42.1250004,"currentSpendPerHr":1.23456789}}},"pods":[{"amount":0.0000006}],"endpoints":[{"amount":1.2345678}],"networkVolumes":[]}
    , 100);

    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 100,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 1_234_569), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(?i64, 42_125_000), report.summary.credit_remaining_micros);
    try std.testing.expectEqual(@as(i64, 1), try money.parseRoundedMicros("6e-7"));
}

test "Runpod rejects GraphQL errors without replacing its last snapshot" {
    var provider = Runpod{ .account = .{
        .credit_remaining_micros = 5_000_000,
        .current_spend_per_hour_micros = 0,
        .month_to_date_micros = 1_000_000,
        .pod_micros = 1_000_000,
        .serverless_micros = 0,
        .network_volume_micros = 0,
        .updated_at_unix = 1,
    } };
    defer provider.deinit();

    try std.testing.expectError(error.ApiFailure, provider.ingest(
        std.testing.allocator,
        "snapshot",
        \\{"account":{"errors":[{"message":"not authorized"}]},"pods":[],"endpoints":[],"networkVolumes":[]}
    ,
        2,
    ));
    try std.testing.expectEqual(@as(i64, 1_000_000), provider.account.?.month_to_date_micros);
}
