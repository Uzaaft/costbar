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

const BillingItem = struct {
    id: []const u8,
    label: []const u8,
    kind: []const u8,
    service: []const u8,
    /// Present when a user-defined inventory name replaced the provider ID.
    reference_id: ?[]const u8 = null,
    amount_micros: i64,
    time_billed_ms: u64 = 0,
    disk_space_billed_gb: u64 = 0,
    detail: ?[]const u8 = null,
};

const ResourceNames = std.StringHashMapUnmanaged([]const u8);

const OwnedBreakdown = struct {
    arena: std.heap.ArenaAllocator,
    items: []BillingItem,

    fn deinit(self: *OwnedBreakdown) void {
        self.arena.deinit();
    }
};

const ParsedSnapshot = struct {
    account: Account,
    breakdown: OwnedBreakdown,

    fn deinit(self: *ParsedSnapshot) void {
        self.breakdown.deinit();
    }
};

pub const Runpod = struct {
    account: ?Account = null,
    breakdown: ?OwnedBreakdown = null,

    pub fn init() Runpod {
        return .{};
    }

    pub fn deinit(self: *Runpod) void {
        if (self.breakdown) |*breakdown| breakdown.deinit();
        self.breakdown = null;
    }

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

        var replacement = try parseSnapshot(allocator, payload, received_at_unix);
        errdefer replacement.deinit();
        if (self.breakdown) |*breakdown| breakdown.deinit();
        self.account = replacement.account;
        self.breakdown = replacement.breakdown;
    }

    pub fn collect(
        self: *Runpod,
        allocator: std.mem.Allocator,
        period: model.Period,
    ) !model.ProviderReport {
        const account = self.account orelse return error.NotFetched;
        const breakdown = self.breakdown orelse return error.NotFetched;
        const resources = try allocator.alloc(model.Resource, breakdown.items.len);
        errdefer allocator.free(resources);
        const line_items = try allocator.alloc(model.CostLineItem, breakdown.items.len);
        errdefer allocator.free(line_items);

        for (breakdown.items, 0..) |item, index| {
            resources[index] = .{
                .id = item.id,
                .name = item.label,
                .kind = item.kind,
                .status = .unknown,
            };
            line_items[index] = .{
                .id = item.id,
                .description = item.label,
                .service = item.service,
                .amount_micros = item.amount_micros,
                .detail = item.detail,
            };
        }

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
) !ParsedSnapshot {
    var result = ParsedSnapshot{
        .account = undefined,
        .breakdown = .{
            .arena = .init(allocator),
            .items = &.{},
        },
    };
    errdefer result.deinit();
    const arena = result.breakdown.arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    });

    const snapshot = try requireObject(parsed);
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

    var pod_names: ResourceNames = .empty;
    defer pod_names.deinit(arena);
    try parsePodInventory(
        arena,
        snapshot.get("podInventory") orelse myself.get("pods"),
        &pod_names,
    );

    var items: std.ArrayList(BillingItem) = .empty;
    const pod_micros = try parseBillingRecords(
        arena,
        snapshot.get("pods") orelse return error.InvalidResponse,
        .pods,
        &pod_names,
        &items,
    );
    const serverless_micros = try parseBillingRecords(
        arena,
        snapshot.get("endpoints") orelse return error.InvalidResponse,
        .serverless,
        &pod_names,
        &items,
    );
    const network_volume_micros = try parseBillingRecords(
        arena,
        snapshot.get("networkVolumes") orelse return error.InvalidResponse,
        .network_volumes,
        &pod_names,
        &items,
    );
    const compute_micros = std.math.add(i64, pod_micros, serverless_micros) catch
        return error.AmountOverflow;
    const month_to_date_micros = std.math.add(
        i64,
        compute_micros,
        network_volume_micros,
    ) catch return error.AmountOverflow;

    for (items.items) |*item| item.detail = try billingDetail(arena, item.*);
    result.breakdown.items = try items.toOwnedSlice(arena);
    std.mem.sort(BillingItem, result.breakdown.items, {}, amountDescending);
    result.account = .{
        .credit_remaining_micros = @max(balance, 0),
        .current_spend_per_hour_micros = hourly_spend,
        .month_to_date_micros = month_to_date_micros,
        .pod_micros = pod_micros,
        .serverless_micros = serverless_micros,
        .network_volume_micros = network_volume_micros,
        .updated_at_unix = received_at_unix,
    };
    return result;
}

const BillingKind = enum {
    pods,
    serverless,
    network_volumes,

    fn service(self: BillingKind) []const u8 {
        return switch (self) {
            .pods => "Pods",
            .serverless => "Serverless",
            .network_volumes => "Network volumes",
        };
    }

    fn resourceKind(self: BillingKind) []const u8 {
        return switch (self) {
            .pods => "pod",
            .serverless => "serverless_endpoint",
            .network_volumes => "network_volume",
        };
    }

    fn fallbackID(self: BillingKind) []const u8 {
        return switch (self) {
            .pods => "runpod-pods",
            .serverless => "runpod-serverless",
            .network_volumes => "runpod-network-volumes",
        };
    }

    fn fallbackLabel(self: BillingKind) []const u8 {
        return switch (self) {
            .pods => "Pod compute and attached storage",
            .serverless => "Serverless workers",
            .network_volumes => "Network volume storage",
        };
    }
};

fn parseBillingRecords(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    kind: BillingKind,
    pod_names: *const ResourceNames,
    items: *std.ArrayList(BillingItem),
) !i64 {
    if (value != .array) return error.InvalidResponse;

    var total: i64 = 0;
    for (value.array.items) |record_value| {
        const record = try requireObject(record_value);
        const amount = try parseMoneyValue(
            record.get("amount") orelse return error.InvalidResponse,
        );
        if (amount < 0) return error.InvalidAmount;
        total = std.math.add(i64, total, amount) catch return error.AmountOverflow;
        if (amount == 0) continue;

        const raw_id = billingResourceID(record, kind);
        const id = if (raw_id) |resource_id|
            try std.fmt.allocPrint(allocator, "runpod-{s}-{s}", .{
                @tagName(kind),
                resource_id,
            })
        else
            kind.fallbackID();
        const inventory_name = if (kind == .pods and raw_id != null)
            pod_names.get(raw_id.?)
        else
            null;
        const label = inventory_name orelse if (raw_id) |resource_id|
            try std.fmt.allocPrint(allocator, "{s} {s}", .{
                switch (kind) {
                    .pods => "Pod",
                    .serverless => "Endpoint",
                    .network_volumes => "Network volume",
                },
                resource_id,
            })
        else
            kind.fallbackLabel();
        const time_billed_ms = try optionalUnsigned(record.get("timeBilledMs")) orelse 0;
        const disk_space_billed_gb = try optionalUnsigned(
            record.get("diskSpaceBilledGb"),
        ) orelse 0;

        if (findBillingItem(items.items, id)) |existing| {
            existing.amount_micros = std.math.add(
                i64,
                existing.amount_micros,
                amount,
            ) catch return error.AmountOverflow;
            existing.time_billed_ms +|= time_billed_ms;
            existing.disk_space_billed_gb +|= disk_space_billed_gb;
        } else {
            try items.append(allocator, .{
                .id = id,
                .label = label,
                .kind = kind.resourceKind(),
                .service = kind.service(),
                .reference_id = if (inventory_name != null) raw_id else null,
                .amount_micros = amount,
                .time_billed_ms = time_billed_ms,
                .disk_space_billed_gb = disk_space_billed_gb,
            });
        }
    }
    return total;
}

fn parsePodInventory(
    allocator: std.mem.Allocator,
    maybe_value: ?std.json.Value,
    names: *ResourceNames,
) !void {
    const value = maybe_value orelse return;
    if (value != .array) return error.InvalidResponse;

    for (value.array.items) |pod_value| {
        if (pod_value != .object) return error.InvalidResponse;
        const id_value = pod_value.object.get("id") orelse continue;
        const name_value = pod_value.object.get("name") orelse continue;
        if (id_value != .string or name_value != .string) continue;
        if (id_value.string.len == 0 or name_value.string.len == 0) continue;
        try names.put(allocator, id_value.string, name_value.string);
    }
}

fn billingResourceID(record: std.json.ObjectMap, kind: BillingKind) ?[]const u8 {
    const fields: []const []const u8 = switch (kind) {
        .pods => &.{ "podId", "gpuTypeId" },
        .serverless => &.{ "endpointId", "serverlessId" },
        .network_volumes => &.{ "networkVolumeId", "volumeId" },
    };
    for (fields) |field| {
        if (record.get(field)) |value| {
            if (value == .string and value.string.len > 0) return value.string;
        }
    }
    return null;
}

fn findBillingItem(items: []BillingItem, id: []const u8) ?*BillingItem {
    for (items) |*item| {
        if (std.mem.eql(u8, item.id, id)) return item;
    }
    return null;
}

fn optionalUnsigned(value: ?std.json.Value) !?u64 {
    const found = value orelse return null;
    return switch (found) {
        .integer => |number| if (number >= 0) @intCast(number) else error.InvalidAmount,
        .number_string, .string => |number| std.fmt.parseUnsigned(u64, number, 10) catch
            error.InvalidAmount,
        .null => null,
        else => error.InvalidAmount,
    };
}

fn billingDetail(allocator: std.mem.Allocator, item: BillingItem) !?[]const u8 {
    const has_time = item.time_billed_ms > 0;
    const has_disk = item.disk_space_billed_gb > 0;
    if (item.reference_id == null and !has_time and !has_disk) return null;

    const tenths_of_an_hour = @divTrunc(
        @as(u128, item.time_billed_ms) * 10,
        3_600_000,
    );
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    if (item.reference_id) |reference_id| {
        try output.writer.print("ID {s}", .{reference_id});
    }
    if (has_time) {
        if (output.written().len > 0) try output.writer.writeAll(" · ");
        try output.writer.print("{d}.{d} billed hours", .{
            tenths_of_an_hour / 10,
            tenths_of_an_hour % 10,
        });
    }
    if (has_disk) {
        if (output.written().len > 0) try output.writer.writeAll(" · ");
        try output.writer.print("{d} GB disk", .{item.disk_space_billed_gb});
    }
    return try output.toOwnedSlice();
}

fn amountDescending(_: void, left: BillingItem, right: BillingItem) bool {
    if (left.amount_micros != right.amount_micros) {
        return left.amount_micros > right.amount_micros;
    }
    return std.mem.lessThan(u8, left.label, right.label);
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

test "Runpod resolves billing IDs to user-defined Pod names" {
    var provider = Runpod.init();
    defer provider.deinit();

    try provider.ingest(std.testing.allocator, "snapshot",
        \\{"account":{"data":{"myself":{"clientBalance":20,"currentSpendPerHr":0.5,"pods":[{"id":"pod-a","name":"Training cluster"},{"id":"pod-b","name":"Image generation"}]}}},"pods":[{"podId":"pod-a","amount":2.5,"timeBilledMs":3600000,"diskSpaceBilledGb":20},{"podId":"pod-a","amount":1.5,"timeBilledMs":1800000,"diskSpaceBilledGb":10},{"podId":"pod-b","amount":4}],"endpoints":[{"endpointId":"endpoint-a","amount":3,"timeBilledMs":7200000}],"networkVolumes":[{"networkVolumeId":"volume-a","amount":1}]}
    , 100);

    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 200,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i64, 12_000_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(usize, 4), report.line_items.len);
    var training_item: ?model.CostLineItem = null;
    for (report.line_items) |item| {
        if (std.mem.eql(u8, item.id, "runpod-pods-pod-a")) training_item = item;
    }
    try std.testing.expect(training_item != null);
    try std.testing.expectEqualStrings("Training cluster", training_item.?.description);
    try std.testing.expectEqual(@as(i64, 4_000_000), training_item.?.amount_micros);
    try std.testing.expectEqualStrings(
        "ID pod-a · 1.5 billed hours · 30 GB disk",
        training_item.?.detail.?,
    );
    try std.testing.expectEqual(@as(usize, 4), report.resources.len);
    try std.testing.expectEqualStrings("pod", report.resources[0].kind);
}

test "Runpod keeps billing IDs for Pods absent from current inventory" {
    var provider = Runpod.init();
    defer provider.deinit();

    try provider.ingest(std.testing.allocator, "snapshot",
        \\{"account":{"data":{"myself":{"clientBalance":0,"currentSpendPerHr":0}}},"podInventory":[],"pods":[{"podId":"deleted-pod","amount":2}],"endpoints":[],"networkVolumes":[]}
    , 100);

    const report = try provider.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 200,
    });
    defer report.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), report.line_items.len);
    try std.testing.expectEqualStrings("Pod deleted-pod", report.line_items[0].description);
    try std.testing.expectEqual(@as(?[]const u8, null), report.line_items[0].detail);
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
