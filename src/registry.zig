const std = @import("std");
const model = @import("model.zig");
const Provider = @import("provider.zig").Provider;

pub const Registry = struct {
    allocator: std.mem.Allocator,
    providers: std.ArrayList(Provider) = .empty,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.providers.deinit(self.allocator);
    }

    pub fn add(self: *Registry, provider: Provider) !void {
        try self.providers.append(self.allocator, provider);
    }

    pub fn ingest(
        self: *Registry,
        provider_id: []const u8,
        document_id: []const u8,
        payload: []const u8,
        received_at_unix: i64,
    ) !void {
        for (self.providers.items) |provider| {
            if (std.mem.eql(u8, provider.metadata().id, provider_id)) {
                return provider.ingest(
                    self.allocator,
                    document_id,
                    payload,
                    received_at_unix,
                );
            }
        }
        return error.UnknownProvider;
    }

    pub fn collect(
        self: *Registry,
        allocator: std.mem.Allocator,
        period: model.Period,
        generated_at_unix: i64,
    ) !model.Dashboard {
        try period.validate();

        var reports: std.ArrayList(model.ProviderReport) = .empty;
        errdefer {
            for (reports.items) |report| report.deinit(allocator);
            reports.deinit(allocator);
        }

        var totals: std.ArrayList(model.CurrencyTotal) = .empty;
        errdefer totals.deinit(allocator);

        for (self.providers.items) |provider| {
            const report = provider.collect(allocator, period) catch |err|
                try unavailableReport(
                    allocator,
                    provider.metadata(),
                    @errorName(err),
                    generated_at_unix,
                );
            errdefer report.deinit(allocator);

            if (report.summary.status == .available and report.summary.contributes_to_totals) {
                if (report.financials.len > 0) {
                    for (report.financials) |financial| {
                        try addFinancialToTotals(allocator, &totals, financial);
                    }
                } else {
                    try addToTotals(allocator, &totals, report.summary);
                }
            }
            try reports.append(allocator, report);
        }

        return .{
            .period = period,
            .generated_at_unix = generated_at_unix,
            .totals = try totals.toOwnedSlice(allocator),
            .providers = try reports.toOwnedSlice(allocator),
        };
    }
};

fn addToTotals(
    allocator: std.mem.Allocator,
    totals: *std.ArrayList(model.CurrencyTotal),
    summary: model.ProviderSummary,
) !void {
    for (totals.items) |*total| {
        if (std.mem.eql(u8, total.currency, summary.currency)) {
            total.current_cost_micros += summary.current_cost_micros;
            if (summary.projected_cost_micros) |projected| {
                total.projected_cost_micros = (total.projected_cost_micros orelse 0) + projected;
            } else {
                total.projection_complete = false;
            }
            if (summary.credit_remaining_micros) |credit| {
                total.credit_remaining_micros = (total.credit_remaining_micros orelse 0) + credit;
            } else {
                total.credit_complete = false;
            }
            return;
        }
    }

    try totals.append(allocator, .{
        .currency = summary.currency,
        .current_cost_micros = summary.current_cost_micros,
        .projected_cost_micros = summary.projected_cost_micros,
        .credit_remaining_micros = summary.credit_remaining_micros,
        .projection_complete = summary.projected_cost_micros != null,
        .credit_complete = summary.credit_remaining_micros != null,
    });
}

fn addFinancialToTotals(
    allocator: std.mem.Allocator,
    totals: *std.ArrayList(model.CurrencyTotal),
    financial: model.FinancialSummary,
) !void {
    return addToTotals(allocator, totals, .{
        .id = "",
        .display_name = "",
        .kind = .other,
        .currency = financial.currency,
        .current_cost_micros = financial.current_cost_micros,
        .projected_cost_micros = financial.projected_cost_micros,
        .credit_remaining_micros = financial.credit_remaining_micros,
        .updated_at_unix = 0,
    });
}

fn unavailableReport(
    allocator: std.mem.Allocator,
    metadata: model.ProviderMetadata,
    error_message: []const u8,
    generated_at_unix: i64,
) !model.ProviderReport {
    const resources = try allocator.alloc(model.Resource, 0);
    errdefer allocator.free(resources);
    const line_items = try allocator.alloc(model.CostLineItem, 0);

    return .{
        .summary = .{
            .id = metadata.id,
            .display_name = metadata.display_name,
            .kind = metadata.kind,
            .status = .unavailable,
            .error_message = error_message,
            .currency = "",
            .current_cost_micros = 0,
            .updated_at_unix = generated_at_unix,
        },
        .resources = resources,
        .line_items = line_items,
    };
}

test "registry aggregates providers and preserves provider details" {
    const StaticProvider = struct {
        id: []const u8,
        currency: []const u8,
        current: i64,
        projected: ?i64,

        pub fn metadata(self: *const @This()) model.ProviderMetadata {
            return .{ .id = self.id, .display_name = self.id, .kind = .other };
        }

        pub fn collect(
            self: *@This(),
            allocator: std.mem.Allocator,
            _: model.Period,
        ) !model.ProviderReport {
            return .{
                .summary = .{
                    .id = self.id,
                    .display_name = self.id,
                    .kind = .other,
                    .currency = self.currency,
                    .current_cost_micros = self.current,
                    .projected_cost_micros = self.projected,
                    .updated_at_unix = 1,
                },
                .resources = try allocator.alloc(model.Resource, 0),
                .line_items = try allocator.alloc(model.CostLineItem, 0),
            };
        }
    };

    var first = StaticProvider{ .id = "first", .currency = "USD", .current = 100, .projected = 150 };
    var second = StaticProvider{ .id = "second", .currency = "USD", .current = 25, .projected = null };
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.add(Provider.from(&first));
    try registry.add(Provider.from(&second));

    const dashboard = try registry.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 2,
    }, 2);
    defer dashboard.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), dashboard.providers.len);
    try std.testing.expectEqual(@as(i64, 125), dashboard.totals[0].current_cost_micros);
    try std.testing.expectEqual(@as(?i64, 150), dashboard.totals[0].projected_cost_micros);
    try std.testing.expect(!dashboard.totals[0].projection_complete);
}

test "one failing provider does not hide healthy providers" {
    const Failing = struct {
        pub fn metadata(_: *const @This()) model.ProviderMetadata {
            return .{ .id = "offline", .display_name = "Offline", .kind = .cloud };
        }

        pub fn collect(
            _: *@This(),
            _: std.mem.Allocator,
            _: model.Period,
        ) !model.ProviderReport {
            return error.AuthenticationFailed;
        }
    };

    var failing = Failing{};
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.add(Provider.from(&failing));

    const dashboard = try registry.collect(std.testing.allocator, .{
        .start_unix = 1,
        .end_exclusive_unix = 2,
    }, 2);
    defer dashboard.deinit(std.testing.allocator);

    try std.testing.expectEqual(model.ProviderStatus.unavailable, dashboard.providers[0].summary.status);
    try std.testing.expectEqualStrings("AuthenticationFailed", dashboard.providers[0].summary.error_message.?);
}
