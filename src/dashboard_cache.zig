const std = @import("std");
const model = @import("model.zig");

const cache_version: u32 = 1;
const cache_name = "dashboard-v1.json";
const max_cache_bytes = 64 * 1024 * 1024;

const Document = struct {
    version: u32,
    dashboard: model.Dashboard,
};

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    dashboard: model.Dashboard,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
    }
};

pub fn loadDefault(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    period: model.Period,
) !?Loaded {
    const directory = try std.fs.path.join(
        allocator,
        &.{ home, "Library/Caches/Costbar" },
    );
    defer allocator.free(directory);
    return load(allocator, io, directory, period);
}

pub fn saveDefault(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    dashboard: model.Dashboard,
) !void {
    const directory = try std.fs.path.join(
        allocator,
        &.{ home, "Library/Caches/Costbar" },
    );
    defer allocator.free(directory);
    try save(allocator, io, directory, dashboard);
}

fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    period: model.Period,
) !?Loaded {
    try period.validate();
    const path = try std.fs.path.join(allocator, &.{ directory, cache_name });
    defer allocator.free(path);
    const bytes = try std.Io.Dir.readFileAlloc(
        .cwd(),
        io,
        path,
        allocator,
        .limited(max_cache_bytes),
    );
    defer allocator.free(bytes);

    var loaded = Loaded{
        .arena = .init(allocator),
        .dashboard = undefined,
    };
    errdefer loaded.deinit();
    const document = std.json.parseFromSliceLeaky(
        Document,
        loaded.arena.allocator(),
        bytes,
        .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        },
    ) catch return error.InvalidDashboardCache;
    if (document.version != cache_version or
        document.dashboard.period.start_unix != period.start_unix or
        document.dashboard.period.end_exclusive_unix != period.end_exclusive_unix)
    {
        loaded.deinit();
        return null;
    }
    try validate(document.dashboard);
    loaded.dashboard = document.dashboard;
    return loaded;
}

fn save(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    dashboard: model.Dashboard,
) !void {
    try validate(dashboard);
    _ = try std.Io.Dir.createDirPathStatus(
        .cwd(),
        io,
        directory,
        .fromMode(0o700),
    );
    const path = try std.fs.path.join(allocator, &.{ directory, cache_name });
    defer allocator.free(path);
    const bytes = try std.json.Stringify.valueAlloc(allocator, Document{
        .version = cache_version,
        .dashboard = dashboard,
    }, .{});
    defer allocator.free(bytes);

    const temporary = try std.fmt.allocPrint(allocator, "{s}.costbar-tmp", .{path});
    defer allocator.free(temporary);
    errdefer std.Io.Dir.deleteFileAbsolute(io, temporary) catch {};
    try std.Io.Dir.writeFile(.cwd(), io, .{
        .sub_path = temporary,
        .data = bytes,
        .flags = .{ .permissions = .fromMode(0o600) },
    });
    try std.Io.Dir.renameAbsolute(temporary, path, io);
}

fn validate(dashboard: model.Dashboard) !void {
    try dashboard.period.validate();
    if (dashboard.totals.len > 1_024 or dashboard.providers.len > 1_024) {
        return error.InvalidDashboardCache;
    }
    for (dashboard.totals) |total| try validateString(total.currency);
    for (dashboard.providers) |report| {
        try validateString(report.summary.id);
        try validateString(report.summary.display_name);
        try validateString(report.summary.currency);
        if (report.summary.error_message) |value| try validateString(value);
        if (report.resources.len > 1_000_000 or
            report.line_items.len > 1_000_000 or
            report.allowance_windows.len > 1_000_000 or
            report.token_usage_windows.len > 1_000_000 or
            report.financials.len > 1_000_000)
        {
            return error.InvalidDashboardCache;
        }
        for (report.resources) |resource| {
            try validateString(resource.id);
            try validateString(resource.name);
            try validateString(resource.kind);
        }
        for (report.line_items) |item| {
            try validateString(item.id);
            try validateString(item.description);
            try validateString(item.service);
            if (item.currency) |value| try validateString(value);
            if (item.detail) |value| try validateString(value);
        }
        for (report.allowance_windows) |window| {
            try validateString(window.id);
            try validateString(window.label);
            if (window.detail) |value| try validateString(value);
            if (!std.math.isFinite(window.used_percent) or
                window.used_percent < 0 or window.used_percent > 100)
            {
                return error.InvalidDashboardCache;
            }
        }
        if (report.token_usage) |usage| {
            try usage.period.validate();
            try validateString(usage.source);
        }
        for (report.token_usage_windows) |window| {
            try window.period.validate();
            try validateString(window.id);
            try validateString(window.label);
        }
        for (report.financials) |financial| try validateString(financial.currency);
    }
}

fn validateString(value: []const u8) !void {
    if (value.len > 64 * 1024 or !std.unicode.utf8ValidateSlice(value)) {
        return error.InvalidDashboardCache;
    }
}

test "dashboard cache round trips a normalized snapshot and rejects another month" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_length = try tmp.dir.realPath(std.testing.io, &directory_buffer);
    const directory = directory_buffer[0..directory_length];

    var resources = [_]model.Resource{.{
        .id = "resource-1",
        .name = "Production",
        .kind = "Droplet",
        .status = .active,
    }};
    var line_items = [_]model.CostLineItem{.{
        .id = "line-1",
        .description = "Compute",
        .service = "Droplets",
        .amount_micros = 2_500_000,
    }};
    var providers = [_]model.ProviderReport{.{
        .summary = .{
            .id = "digitalocean",
            .display_name = "DigitalOcean",
            .kind = .cloud,
            .currency = "USD",
            .current_cost_micros = 2_500_000,
            .updated_at_unix = 100,
        },
        .resources = &resources,
        .line_items = &line_items,
    }};
    var totals = [_]model.CurrencyTotal{.{
        .currency = "USD",
        .current_cost_micros = 2_500_000,
        .projected_cost_micros = 3_000_000,
        .credit_remaining_micros = null,
        .projection_complete = true,
        .credit_complete = false,
    }};
    const dashboard = model.Dashboard{
        .period = .{ .start_unix = 1, .end_exclusive_unix = 200 },
        .generated_at_unix = 100,
        .totals = &totals,
        .providers = &providers,
    };
    try save(std.testing.allocator, std.testing.io, directory, dashboard);

    var loaded = (try load(
        std.testing.allocator,
        std.testing.io,
        directory,
        dashboard.period,
    )).?;
    defer loaded.deinit();
    try std.testing.expectEqual(@as(i64, 2_500_000), loaded.dashboard.totals[0].current_cost_micros);
    try std.testing.expectEqualStrings("Production", loaded.dashboard.providers[0].resources[0].name);
    try std.testing.expect((try load(
        std.testing.allocator,
        std.testing.io,
        directory,
        .{ .start_unix = 200, .end_exclusive_unix = 300 },
    )) == null);
}

test "dashboard cache ignores corrupt data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_length = try tmp.dir.realPath(std.testing.io, &directory_buffer);
    const directory = directory_buffer[0..directory_length];
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = cache_name,
        .data = "not-json",
    });
    try std.testing.expectError(
        error.InvalidDashboardCache,
        load(
            std.testing.allocator,
            std.testing.io,
            directory,
            .{ .start_unix = 1, .end_exclusive_unix = 2 },
        ),
    );
}
