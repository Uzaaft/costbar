const std = @import("std");
const model = @import("model.zig");
const Provider = @import("provider.zig").Provider;
const Registry = @import("registry.zig").Registry;
const digitalocean = @import("providers/digitalocean.zig");
const cloudflare = @import("providers/cloudflare.zig");
const runpod = @import("providers/runpod.zig");
const vercel = @import("providers/vercel.zig");
const openrouter = @import("providers/openrouter.zig");
const subscriptions = @import("providers/subscriptions.zig");
const codex = @import("providers/codex.zig");
const claude = @import("providers/claude.zig");
const openai_api = @import("providers/openai_api.zig");
const anthropic_api = @import("providers/anthropic_api.zig");
const github = @import("providers/github.zig");
const cursor = @import("providers/cursor.zig");

const allocator = std.heap.c_allocator;

pub const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    out_of_memory = 2,
    internal_error = 3,
    parse_error = 4,
    unsupported = 5,
};

pub const Bytes = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,
};

const Core = struct {
    digitalocean_provider: digitalocean.DigitalOcean,
    cloudflare_provider: cloudflare.Cloudflare,
    runpod_provider: runpod.Runpod,
    vercel_provider: vercel.Vercel,
    openrouter_provider: openrouter.OpenRouter,
    subscriptions_provider: subscriptions.Subscriptions,
    codex_provider: codex.Codex,
    claude_provider: claude.Claude,
    openai_api_provider: openai_api.OpenAIAPI,
    anthropic_api_provider: anthropic_api.AnthropicAPI,
    github_provider: github.GitHub,
    cursor_provider: cursor.Cursor,
    registry: Registry,

    fn create() !*Core {
        const core = try allocator.create(Core);
        errdefer allocator.destroy(core);

        core.digitalocean_provider = .init();
        core.cloudflare_provider = .init();
        core.runpod_provider = .init();
        core.vercel_provider = .init();
        core.openrouter_provider = .init();
        core.subscriptions_provider = .init();
        core.codex_provider = .init();
        core.claude_provider = .init();
        core.openai_api_provider = .init();
        core.anthropic_api_provider = .init();
        core.github_provider = .init();
        core.cursor_provider = .init();

        core.registry = Registry.init(allocator);
        errdefer core.registry.deinit();
        try core.registry.add(Provider.from(&core.digitalocean_provider));
        try core.registry.add(Provider.from(&core.cloudflare_provider));
        try core.registry.add(Provider.from(&core.runpod_provider));
        try core.registry.add(Provider.from(&core.vercel_provider));
        try core.registry.add(Provider.from(&core.openrouter_provider));
        try core.registry.add(Provider.from(&core.subscriptions_provider));
        try core.registry.add(Provider.from(&core.codex_provider));
        try core.registry.add(Provider.from(&core.claude_provider));
        try core.registry.add(Provider.from(&core.openai_api_provider));
        try core.registry.add(Provider.from(&core.anthropic_api_provider));
        try core.registry.add(Provider.from(&core.github_provider));
        try core.registry.add(Provider.from(&core.cursor_provider));
        return core;
    }

    fn destroy(core: *Core) void {
        core.registry.deinit();
        core.digitalocean_provider.deinit();
        core.cloudflare_provider.deinit();
        core.runpod_provider.deinit();
        core.vercel_provider.deinit();
        core.openrouter_provider.deinit();
        core.subscriptions_provider.deinit();
        core.codex_provider.deinit();
        core.claude_provider.deinit();
        core.openai_api_provider.deinit();
        core.anthropic_api_provider.deinit();
        core.github_provider.deinit();
        core.cursor_provider.deinit();
        allocator.destroy(core);
    }
};

export fn costbar_abi_version() u32 {
    return 1;
}

export fn costbar_version_string() [*:0]const u8 {
    return "0.1.0";
}

export fn costbar_core_create() ?*Core {
    return Core.create() catch null;
}

export fn costbar_core_destroy(core: ?*Core) void {
    if (core) |value| value.destroy();
}

export fn costbar_core_ingest_provider_json(
    core: ?*Core,
    provider_id: Bytes,
    document_id: Bytes,
    json: Bytes,
    received_at_unix: i64,
) Status {
    const core_value = core orelse return .invalid_argument;
    const provider = borrowedSlice(provider_id) orelse return .invalid_argument;
    const document = borrowedSlice(document_id) orelse return .invalid_argument;
    const payload = borrowedSlice(json) orelse return .invalid_argument;
    if (provider.len == 0 or document.len == 0) {
        return .invalid_argument;
    }

    core_value.registry.ingest(
        provider,
        document,
        payload,
        received_at_unix,
    ) catch |err| return statusForIngestError(err);
    return .ok;
}

export fn costbar_core_snapshot_json(
    core: ?*Core,
    period_start_unix: i64,
    period_end_exclusive_unix: i64,
    out_json: ?*Bytes,
) Status {
    const core_value = core orelse return .invalid_argument;
    const output = out_json orelse return .invalid_argument;
    output.* = .{};

    const dashboard = core_value.registry.collect(allocator, .{
        .start_unix = period_start_unix,
        .end_exclusive_unix = period_end_exclusive_unix,
    }, currentUnixTimestamp()) catch |err| return statusForError(err);
    defer dashboard.deinit(allocator);

    const json = std.json.Stringify.valueAlloc(allocator, dashboard, .{}) catch {
        return .out_of_memory;
    };
    output.* = .{ .ptr = json.ptr, .len = json.len };
    return .ok;
}

export fn costbar_bytes_free(bytes: Bytes) void {
    const ptr = bytes.ptr orelse return;
    allocator.free(@constCast(ptr[0..bytes.len]));
}

fn statusForError(err: anyerror) Status {
    return switch (err) {
        error.InvalidPeriod => .invalid_argument,
        error.OutOfMemory => .out_of_memory,
        else => .internal_error,
    };
}

fn statusForIngestError(err: anyerror) Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.UnknownProvider, error.UnsupportedDocument => .unsupported,
        else => .parse_error,
    };
}

fn borrowedSlice(bytes: Bytes) ?[]const u8 {
    if (bytes.len == 0) return "";
    const ptr = bytes.ptr orelse return null;
    return ptr[0..bytes.len];
}

fn currentUnixTimestamp() i64 {
    var timestamp: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &timestamp) != 0) return 0;
    return timestamp.sec;
}

test "C API has no fabricated provider data before the first refresh" {
    const core = costbar_core_create() orelse return error.OutOfMemory;
    defer costbar_core_destroy(core);

    var bytes: Bytes = .{};
    try std.testing.expectEqual(Status.ok, costbar_core_snapshot_json(core, 1, 2, &bytes));
    defer costbar_bytes_free(bytes);

    const json = bytes.ptr.?[0..bytes.len];
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 12), root.get("providers").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), root.get("totals").?.array.items.len);
    const providers = root.get("providers").?.array.items;
    try std.testing.expectEqualStrings(
        "unavailable",
        providers[0].object.get("summary").?.object.get("status").?.string,
    );
    try std.testing.expectEqualStrings(
        "NotFetched",
        providers[0].object.get("summary").?.object.get("error_message").?.string,
    );
}

test "C API ingests live provider documents before snapshotting" {
    const core = costbar_core_create() orelse return error.OutOfMemory;
    defer costbar_core_destroy(core);

    const balance =
        \\{"account_balance":"-12.50","month_to_date_usage":"9.75"}
    ;
    const droplets =
        \\{"droplets":[{"id":42,"name":"production","status":"active"}]}
    ;
    try std.testing.expectEqual(Status.ok, costbar_core_ingest_provider_json(
        core,
        bytesView("digitalocean"),
        bytesView("balance"),
        bytesView(balance),
        100,
    ));
    try std.testing.expectEqual(Status.ok, costbar_core_ingest_provider_json(
        core,
        bytesView("digitalocean"),
        bytesView("droplets"),
        bytesView(droplets),
        100,
    ));

    var bytes: Bytes = .{};
    try std.testing.expectEqual(Status.ok, costbar_core_snapshot_json(core, 1, 200, &bytes));
    defer costbar_bytes_free(bytes);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        bytes.ptr.?[0..bytes.len],
        .{},
    );
    defer parsed.deinit();
    const digitalocean_report = parsed.value.object.get("providers").?.array.items[0].object;
    try std.testing.expectEqual(
        @as(i64, 9_750_000),
        digitalocean_report.get("summary").?.object.get("current_cost_micros").?.integer,
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        digitalocean_report.get("resources").?.array.items.len,
    );
}

test "C API ingests a Runpod billing snapshot" {
    const core = costbar_core_create() orelse return error.OutOfMemory;
    defer costbar_core_destroy(core);

    const snapshot =
        \\{"account":{"data":{"myself":{"clientBalance":25.5,"currentSpendPerHr":0.25}}},"pods":[{"amount":3.5}],"endpoints":[{"amount":1.25}],"networkVolumes":[{"amount":0.5}]}
    ;
    try std.testing.expectEqual(Status.ok, costbar_core_ingest_provider_json(
        core,
        bytesView("runpod"),
        bytesView("snapshot"),
        bytesView(snapshot),
        100,
    ));

    var bytes: Bytes = .{};
    try std.testing.expectEqual(Status.ok, costbar_core_snapshot_json(core, 1, 200, &bytes));
    defer costbar_bytes_free(bytes);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        bytes.ptr.?[0..bytes.len],
        .{},
    );
    defer parsed.deinit();
    const runpod_report = parsed.value.object.get("providers").?.array.items[2].object;
    try std.testing.expectEqual(
        @as(i64, 5_250_000),
        runpod_report.get("summary").?.object.get("current_cost_micros").?.integer,
    );
    try std.testing.expectEqual(
        @as(i64, 25_500_000),
        runpod_report.get("summary").?.object.get("credit_remaining_micros").?.integer,
    );
}

test "C API ingests Vercel FOCUS billing charges" {
    const core = costbar_core_create() orelse return error.OutOfMemory;
    defer costbar_core_destroy(core);

    const charges =
        \\{"BillingCurrency":"USD","BilledCost":3.25,"ServiceName":"Functions"}
        \\{"BillingCurrency":"USD","BilledCost":1.5,"ServiceName":"Fast Data Transfer"}
    ;
    try std.testing.expectEqual(Status.ok, costbar_core_ingest_provider_json(
        core,
        bytesView("vercel"),
        bytesView("charges"),
        bytesView(charges),
        100,
    ));

    var bytes: Bytes = .{};
    try std.testing.expectEqual(Status.ok, costbar_core_snapshot_json(core, 1, 200, &bytes));
    defer costbar_bytes_free(bytes);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        bytes.ptr.?[0..bytes.len],
        .{},
    );
    defer parsed.deinit();
    const vercel_report = parsed.value.object.get("providers").?.array.items[3].object;
    try std.testing.expectEqual(
        @as(i64, 4_750_000),
        vercel_report.get("summary").?.object.get("current_cost_micros").?.integer,
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        vercel_report.get("line_items").?.array.items.len,
    );
}

fn bytesView(value: []const u8) Bytes {
    return .{ .ptr = value.ptr, .len = value.len };
}
