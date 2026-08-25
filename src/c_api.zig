const std = @import("std");
const builtin = @import("builtin");
const model = @import("model.zig");
const Provider = @import("provider.zig").Provider;
const Registry = @import("registry.zig").Registry;
const digitalocean = @import("providers/digitalocean.zig");
const ovh = @import("providers/ovh.zig");
const hetzner = @import("providers/hetzner.zig");
const cloudflare = @import("providers/cloudflare.zig");
const runpod = @import("providers/runpod.zig");
const vercel = @import("providers/vercel.zig");
const openrouter = @import("providers/openrouter.zig");
const codex = @import("providers/codex.zig");
const claude = @import("providers/claude.zig");
const openai_api = @import("providers/openai_api.zig");
const anthropic_api = @import("providers/anthropic_api.zig");
const xai_api = @import("providers/xai_api.zig");
const github = @import("providers/github.zig");
const cursor = @import("providers/cursor.zig");
const opencode = @import("providers/opencode.zig");
const local_usage = @import("local_usage.zig");
const dashboard_cache = @import("dashboard_cache.zig");
const live_refresh = @import("live_refresh.zig");
const claude_status = @import("claude_status.zig");

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

pub const RefreshOptions = extern struct {
    period_start_unix: i64,
    period_end_exclusive_unix: i64,
    track_codex: u8,
    track_claude: u8,
    track_opencode: u8,
    use_github_cli: u8,
};

pub const RefreshResult = extern struct {
    configured_count: u32 = 0,
    refreshed_count: u32 = 0,
    errors: Bytes = .{},
};

pub const OptionalI64 = extern struct {
    value: i64 = 0,
    present: u8 = 0,
};

pub const SnapshotHeader = extern struct {
    period_start_unix: i64,
    period_end_exclusive_unix: i64,
    generated_at_unix: i64,
    total_count: usize,
    provider_count: usize,
};

pub const CurrencyTotalView = extern struct {
    currency: Bytes,
    current_cost_micros: i64,
    projected_cost_micros: OptionalI64,
    credit_remaining_micros: OptionalI64,
    projection_complete: u8,
    credit_complete: u8,
};

pub const ProviderView = extern struct {
    id: Bytes,
    display_name: Bytes,
    kind: Bytes,
    status: Bytes,
    error_message: Bytes,
    has_error_message: u8,
    currency: Bytes,
    current_cost_micros: i64,
    projected_cost_micros: OptionalI64,
    credit_remaining_micros: OptionalI64,
    contributes_to_totals: u8,
    updated_at_unix: i64,
    resource_count: usize,
    line_item_count: usize,
    allowance_count: usize,
    has_token_usage: u8,
    token_usage_window_count: usize,
    financial_count: usize,
};

pub const ResourceView = extern struct {
    id: Bytes,
    name: Bytes,
    kind: Bytes,
    status: Bytes,
    quantity: u64,
};

pub const CostLineItemView = extern struct {
    id: Bytes,
    description: Bytes,
    service: Bytes,
    amount_micros: i64,
    currency: Bytes,
    has_currency: u8,
    detail: Bytes,
    has_detail: u8,
};

pub const AllowanceView = extern struct {
    id: Bytes,
    label: Bytes,
    used_percent: f64,
    resets_at_unix: OptionalI64,
    detail: Bytes,
    has_detail: u8,
};

pub const TokenUsageView = extern struct {
    period_start_unix: i64,
    period_end_exclusive_unix: i64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_creation_tokens: u64,
    reasoning_tokens: u64,
    source: Bytes,
    updated_at_unix: i64,
};

pub const TokenUsageWindowView = extern struct {
    id: Bytes,
    label: Bytes,
    period_start_unix: i64,
    period_end_exclusive_unix: i64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_creation_tokens: u64,
    reasoning_tokens: u64,
};

pub const FinancialView = extern struct {
    currency: Bytes,
    current_cost_micros: i64,
    projected_cost_micros: OptionalI64,
    credit_remaining_micros: OptionalI64,
};

const Snapshot = struct {
    dashboard: model.Dashboard,
    cache_arena: ?std.heap.ArenaAllocator = null,

    fn deinit(self: *Snapshot) void {
        if (self.cache_arena) |*arena| {
            arena.deinit();
        } else {
            self.dashboard.deinit(allocator);
        }
    }
};

const Core = struct {
    digitalocean_provider: digitalocean.DigitalOcean,
    ovh_provider: ovh.OVHcloud,
    hetzner_provider: hetzner.Hetzner,
    cloudflare_provider: cloudflare.Cloudflare,
    runpod_provider: runpod.Runpod,
    vercel_provider: vercel.Vercel,
    openrouter_provider: openrouter.OpenRouter,
    codex_provider: codex.Codex,
    claude_provider: claude.Claude,
    openai_api_provider: openai_api.OpenAIAPI,
    anthropic_api_provider: anthropic_api.AnthropicAPI,
    xai_api_provider: xai_api.XAIAPI,
    github_provider: github.GitHub,
    cursor_provider: cursor.Cursor,
    opencode_provider: opencode.OpenCode,
    codex_usage: local_usage.Collector(local_usage.CodexLogAdapter),
    claude_usage: local_usage.Collector(local_usage.ClaudeLogAdapter),
    settings: std.BufMap,
    registry: Registry,

    fn create() !*Core {
        const core = try allocator.create(Core);
        errdefer allocator.destroy(core);

        core.digitalocean_provider = .init();
        core.ovh_provider = .init();
        core.hetzner_provider = .init();
        core.cloudflare_provider = .init();
        core.runpod_provider = .init();
        core.vercel_provider = .init();
        core.openrouter_provider = .init();
        core.codex_provider = .init();
        core.claude_provider = .init();
        core.openai_api_provider = .init();
        core.anthropic_api_provider = .init();
        core.xai_api_provider = .init();
        core.github_provider = .init();
        core.cursor_provider = .init();
        core.opencode_provider = .init();
        core.codex_usage = .init(allocator);
        core.claude_usage = .init(allocator);
        core.settings = .init(allocator);

        core.registry = Registry.init(allocator);
        errdefer core.registry.deinit();
        try core.registry.addConfigured(Provider.from(&core.digitalocean_provider), false);
        try core.registry.addConfigured(Provider.from(&core.ovh_provider), false);
        try core.registry.addConfigured(Provider.from(&core.hetzner_provider), false);
        try core.registry.addConfigured(Provider.from(&core.cloudflare_provider), false);
        try core.registry.addConfigured(Provider.from(&core.runpod_provider), false);
        try core.registry.addConfigured(Provider.from(&core.vercel_provider), false);
        try core.registry.addConfigured(Provider.from(&core.openrouter_provider), false);
        try core.registry.addConfigured(Provider.from(&core.codex_provider), false);
        try core.registry.addConfigured(Provider.from(&core.claude_provider), false);
        try core.registry.addConfigured(Provider.from(&core.openai_api_provider), false);
        try core.registry.addConfigured(Provider.from(&core.anthropic_api_provider), false);
        try core.registry.addConfigured(Provider.from(&core.xai_api_provider), false);
        try core.registry.addConfigured(Provider.from(&core.github_provider), false);
        try core.registry.addConfigured(Provider.from(&core.cursor_provider), false);
        try core.registry.addConfigured(Provider.from(&core.opencode_provider), false);
        return core;
    }

    fn destroy(core: *Core) void {
        core.registry.deinit();
        core.digitalocean_provider.deinit();
        core.ovh_provider.deinit();
        core.hetzner_provider.deinit();
        core.cloudflare_provider.deinit();
        core.runpod_provider.deinit();
        core.vercel_provider.deinit();
        core.openrouter_provider.deinit();
        core.codex_provider.deinit();
        core.claude_provider.deinit();
        core.openai_api_provider.deinit();
        core.anthropic_api_provider.deinit();
        core.xai_api_provider.deinit();
        core.github_provider.deinit();
        core.cursor_provider.deinit();
        core.opencode_provider.deinit();
        core.codex_usage.deinit();
        core.claude_usage.deinit();
        core.settings.deinit();
        allocator.destroy(core);
    }
};

export fn costbar_abi_version() u32 {
    return 6;
}

/// Stores one opaque credential/configuration value in Zig-owned memory. An
/// empty value clears the setting. Keys are fixed ABI names so a typo cannot
/// silently create dead configuration.
export fn costbar_core_set_setting(
    core: ?*Core,
    key_bytes: Bytes,
    value_bytes: Bytes,
) Status {
    const core_value = core orelse return .invalid_argument;
    const key = borrowedSlice(key_bytes) orelse return .invalid_argument;
    const value = borrowedSlice(value_bytes) orelse return .invalid_argument;
    if (!isKnownSetting(key)) return .unsupported;
    if (value.len == 0) {
        core_value.settings.remove(key);
    } else {
        core_value.settings.put(key, value) catch return .out_of_memory;
    }
    syncRemoteProviderConfiguration(
        core_value,
        credentialsFrom(core_value.settings),
    ) catch return .internal_error;
    return .ok;
}

/// Compatibility decoder for the original packed Keychain record. Swift keeps
/// treating the Keychain payload as opaque bytes; legacy JSON is decoded here
/// and then migrated to one UTF-8 Keychain item per field.
export fn costbar_decode_credential_json_field(
    json_bytes: Bytes,
    key_bytes: Bytes,
    out_value: ?*Bytes,
) Status {
    const json = borrowedSlice(json_bytes) orelse return .invalid_argument;
    const key = borrowedSlice(key_bytes) orelse return .invalid_argument;
    const output = out_value orelse return .invalid_argument;
    output.* = .{};
    const json_name = credentialJSONName(key) orelse return .unsupported;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{
        .allocate = .alloc_always,
    }) catch return .parse_error;
    defer parsed.deinit();
    if (parsed.value != .object) return .parse_error;
    const found = parsed.value.object.get(json_name) orelse return .ok;
    if (found == .null) return .ok;
    if (found != .string) return .parse_error;
    const owned = allocator.dupe(u8, found.string) catch return .out_of_memory;
    output.* = .{ .ptr = owned.ptr, .len = owned.len };
    return .ok;
}

/// Refreshes every configured provider concurrently. The Swift caller only
/// supplies the selected time window and local-provider UI toggles; HTTP,
/// filesystem access, JSON/NDJSON, pagination, and aggregation are all Zig.
export fn costbar_core_refresh(
    core: ?*Core,
    options: RefreshOptions,
    out_result: ?*RefreshResult,
) Status {
    const core_value = core orelse return .invalid_argument;
    const result = out_result orelse return .invalid_argument;
    result.* = .{};
    const period = model.Period{
        .start_unix = options.period_start_unix,
        .end_exclusive_unix = options.period_end_exclusive_unix,
    };
    period.validate() catch return .invalid_argument;

    var credentials = credentialsFrom(core_value.settings);
    credentials.github_use_cli = options.use_github_cli != 0;
    syncRemoteProviderConfiguration(core_value, credentials) catch
        return .internal_error;
    core_value.registry.setConfigured("codex", options.track_codex != 0) catch
        return .internal_error;
    core_value.registry.setConfigured("claude", options.track_claude != 0) catch
        return .internal_error;
    core_value.registry.setConfigured("opencode", options.track_opencode != 0) catch
        return .internal_error;
    const home_pointer = std.c.getenv("HOME");
    const home = if (home_pointer) |pointer| std.mem.span(pointer) else "";
    const now = currentUnixTimestamp();

    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    defer io_threaded.deinit();
    var standard_client = std.http.Client{
        .allocator = allocator,
        .io = io_threaded.io(),
    };
    defer standard_client.deinit();

    var contexts: [max_worker_count]WorkerContext = undefined;
    var context_count: usize = 0;
    inline for (std.meta.fields(live_refresh.Kind)) |field| {
        const kind: live_refresh.Kind = @enumFromInt(field.value);
        if (credentials.isConfigured(kind)) {
            contexts[context_count] = .{
                .core = core_value,
                .standard_client = &standard_client,
                .credentials = credentials,
                .period = period,
                .home = home,
                .now = now,
                .kind = .{ .remote = kind },
            };
            context_count += 1;
        }
    }
    if (options.track_codex != 0) {
        contexts[context_count] = .{
            .core = core_value,
            .standard_client = &standard_client,
            .credentials = credentials,
            .period = period,
            .home = home,
            .now = now,
            .kind = .codex,
        };
        context_count += 1;
    }
    if (options.track_claude != 0) {
        contexts[context_count] = .{
            .core = core_value,
            .standard_client = &standard_client,
            .credentials = credentials,
            .period = period,
            .home = home,
            .now = now,
            .kind = .claude,
        };
        context_count += 1;
    }
    if (options.track_opencode != 0) {
        contexts[context_count] = .{
            .core = core_value,
            .standard_client = &standard_client,
            .credentials = credentials,
            .period = period,
            .home = home,
            .now = now,
            .kind = .opencode,
        };
        context_count += 1;
    }
    result.configured_count = @intCast(context_count);

    var threads: [max_worker_count]?std.Thread = @splat(null);
    for (contexts[0..context_count], 0..) |*context, index| {
        threads[index] = std.Thread.spawn(.{}, workerMain, .{context}) catch |err| {
            context.failure = err;
            continue;
        };
    }
    for (threads[0..context_count]) |maybe_thread| {
        if (maybe_thread) |thread| thread.join();
    }

    var errors: std.Io.Writer.Allocating = .init(allocator);
    defer errors.deinit();
    for (contexts[0..context_count]) |context| {
        if (context.failure) |err| {
            if (errors.written().len > 0) errors.writer.writeByte('\n') catch
                return .out_of_memory;
            errors.writer.print("{s}: {s}", .{ context.displayName(), @errorName(err) }) catch
                return .out_of_memory;
        } else {
            result.refreshed_count += 1;
        }
    }
    if (errors.written().len > 0) {
        const owned = errors.toOwnedSlice() catch return .out_of_memory;
        result.errors = .{ .ptr = owned.ptr, .len = owned.len };
    }
    if (!builtin.is_test and home.len > 0 and
        (result.refreshed_count > 0 or result.configured_count == 0))
    {
        const maybe_dashboard: ?model.Dashboard = core_value.registry.collect(
            allocator,
            period,
            now,
        ) catch null;
        if (maybe_dashboard) |dashboard| {
            defer dashboard.deinit(allocator);
            dashboard_cache.saveDefault(
                allocator,
                standard_client.io,
                home,
                dashboard,
            ) catch {};
        }
    }
    return .ok;
}

export fn costbar_version_string() [*:0]const u8 {
    return "0.1.0";
}

export fn costbar_claude_status_bridge_is_installed(out_installed: ?*u8) Status {
    const output = out_installed orelse return .invalid_argument;
    const home_pointer = std.c.getenv("HOME") orelse return .internal_error;
    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    defer io_threaded.deinit();
    const installed = claude_status.isInstalled(
        allocator,
        io_threaded.io(),
        std.mem.span(home_pointer),
    ) catch return .internal_error;
    output.* = @intFromBool(installed);
    return .ok;
}

export fn costbar_claude_status_bridge_install() Status {
    const home_pointer = std.c.getenv("HOME") orelse return .internal_error;
    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    defer io_threaded.deinit();
    claude_status.install(
        allocator,
        io_threaded.io(),
        std.mem.span(home_pointer),
    ) catch |err| return statusForError(err);
    return .ok;
}

export fn costbar_claude_status_bridge_restore() Status {
    const home_pointer = std.c.getenv("HOME") orelse return .internal_error;
    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    defer io_threaded.deinit();
    claude_status.restore(
        allocator,
        io_threaded.io(),
        std.mem.span(home_pointer),
    ) catch |err| return statusForError(err);
    return .ok;
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

export fn costbar_core_snapshot_create(
    core: ?*Core,
    period_start_unix: i64,
    period_end_exclusive_unix: i64,
    out_snapshot: ?*?*Snapshot,
) Status {
    const core_value = core orelse return .invalid_argument;
    const output = out_snapshot orelse return .invalid_argument;
    output.* = null;
    const snapshot = allocator.create(Snapshot) catch return .out_of_memory;
    errdefer allocator.destroy(snapshot);
    snapshot.dashboard = core_value.registry.collect(allocator, .{
        .start_unix = period_start_unix,
        .end_exclusive_unix = period_end_exclusive_unix,
    }, currentUnixTimestamp()) catch |err| return statusForError(err);
    snapshot.cache_arena = null;
    output.* = snapshot;
    return .ok;
}

/// Restores the last normalized dashboard for this exact period. Missing,
/// stale, or corrupt cache data is reported as unsupported so the caller can
/// immediately continue with a background refresh.
export fn costbar_core_cached_snapshot_create(
    core: ?*Core,
    period_start_unix: i64,
    period_end_exclusive_unix: i64,
    out_snapshot: ?*?*Snapshot,
) Status {
    _ = core orelse return .invalid_argument;
    const output = out_snapshot orelse return .invalid_argument;
    output.* = null;
    const period = model.Period{
        .start_unix = period_start_unix,
        .end_exclusive_unix = period_end_exclusive_unix,
    };
    period.validate() catch return .invalid_argument;
    const home_pointer = std.c.getenv("HOME") orelse return .unsupported;
    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    defer io_threaded.deinit();
    var loaded = (dashboard_cache.loadDefault(
        allocator,
        io_threaded.io(),
        std.mem.span(home_pointer),
        period,
    ) catch return .unsupported) orelse return .unsupported;
    const snapshot = allocator.create(Snapshot) catch {
        loaded.deinit();
        return .out_of_memory;
    };
    snapshot.* = .{
        .dashboard = loaded.dashboard,
        .cache_arena = loaded.arena,
    };
    output.* = snapshot;
    return .ok;
}

export fn costbar_snapshot_destroy(snapshot: ?*Snapshot) void {
    const value = snapshot orelse return;
    value.deinit();
    allocator.destroy(value);
}

export fn costbar_snapshot_header(
    snapshot: ?*const Snapshot,
    out_header: ?*SnapshotHeader,
) Status {
    const dashboard = if (snapshot) |value| value.dashboard else return .invalid_argument;
    const output = out_header orelse return .invalid_argument;
    output.* = .{
        .period_start_unix = dashboard.period.start_unix,
        .period_end_exclusive_unix = dashboard.period.end_exclusive_unix,
        .generated_at_unix = dashboard.generated_at_unix,
        .total_count = dashboard.totals.len,
        .provider_count = dashboard.providers.len,
    };
    return .ok;
}

export fn costbar_snapshot_total(
    snapshot: ?*const Snapshot,
    index: usize,
    out_total: ?*CurrencyTotalView,
) Status {
    const dashboard = if (snapshot) |value| value.dashboard else return .invalid_argument;
    const output = out_total orelse return .invalid_argument;
    if (index >= dashboard.totals.len) return .invalid_argument;
    const total = dashboard.totals[index];
    output.* = .{
        .currency = bytesView(total.currency),
        .current_cost_micros = total.current_cost_micros,
        .projected_cost_micros = optionalI64(total.projected_cost_micros),
        .credit_remaining_micros = optionalI64(total.credit_remaining_micros),
        .projection_complete = @intFromBool(total.projection_complete),
        .credit_complete = @intFromBool(total.credit_complete),
    };
    return .ok;
}

export fn costbar_snapshot_provider(
    snapshot: ?*const Snapshot,
    index: usize,
    out_provider: ?*ProviderView,
) Status {
    const dashboard = if (snapshot) |value| value.dashboard else return .invalid_argument;
    const output = out_provider orelse return .invalid_argument;
    if (index >= dashboard.providers.len) return .invalid_argument;
    const report = dashboard.providers[index];
    output.* = .{
        .id = bytesView(report.summary.id),
        .display_name = bytesView(report.summary.display_name),
        .kind = bytesView(@tagName(report.summary.kind)),
        .status = bytesView(@tagName(report.summary.status)),
        .error_message = bytesView(report.summary.error_message orelse ""),
        .has_error_message = @intFromBool(report.summary.error_message != null),
        .currency = bytesView(report.summary.currency),
        .current_cost_micros = report.summary.current_cost_micros,
        .projected_cost_micros = optionalI64(report.summary.projected_cost_micros),
        .credit_remaining_micros = optionalI64(report.summary.credit_remaining_micros),
        .contributes_to_totals = @intFromBool(report.summary.contributes_to_totals),
        .updated_at_unix = report.summary.updated_at_unix,
        .resource_count = report.resources.len,
        .line_item_count = report.line_items.len,
        .allowance_count = report.allowance_windows.len,
        .has_token_usage = @intFromBool(report.token_usage != null),
        .token_usage_window_count = report.token_usage_windows.len,
        .financial_count = report.financials.len,
    };
    return .ok;
}

export fn costbar_snapshot_resource(
    snapshot: ?*const Snapshot,
    provider_index: usize,
    index: usize,
    out_resource: ?*ResourceView,
) Status {
    const report = snapshotReport(snapshot, provider_index) orelse return .invalid_argument;
    const output = out_resource orelse return .invalid_argument;
    if (index >= report.resources.len) return .invalid_argument;
    const resource = report.resources[index];
    output.* = .{
        .id = bytesView(resource.id),
        .name = bytesView(resource.name),
        .kind = bytesView(resource.kind),
        .status = bytesView(@tagName(resource.status)),
        .quantity = resource.quantity,
    };
    return .ok;
}

export fn costbar_snapshot_line_item(
    snapshot: ?*const Snapshot,
    provider_index: usize,
    index: usize,
    out_item: ?*CostLineItemView,
) Status {
    const report = snapshotReport(snapshot, provider_index) orelse return .invalid_argument;
    const output = out_item orelse return .invalid_argument;
    if (index >= report.line_items.len) return .invalid_argument;
    const item = report.line_items[index];
    output.* = .{
        .id = bytesView(item.id),
        .description = bytesView(item.description),
        .service = bytesView(item.service),
        .amount_micros = item.amount_micros,
        .currency = bytesView(item.currency orelse ""),
        .has_currency = @intFromBool(item.currency != null),
        .detail = bytesView(item.detail orelse ""),
        .has_detail = @intFromBool(item.detail != null),
    };
    return .ok;
}

export fn costbar_snapshot_allowance(
    snapshot: ?*const Snapshot,
    provider_index: usize,
    index: usize,
    out_allowance: ?*AllowanceView,
) Status {
    const report = snapshotReport(snapshot, provider_index) orelse return .invalid_argument;
    const output = out_allowance orelse return .invalid_argument;
    if (index >= report.allowance_windows.len) return .invalid_argument;
    const allowance_value = report.allowance_windows[index];
    output.* = .{
        .id = bytesView(allowance_value.id),
        .label = bytesView(allowance_value.label),
        .used_percent = allowance_value.used_percent,
        .resets_at_unix = optionalI64(allowance_value.resets_at_unix),
        .detail = bytesView(allowance_value.detail orelse ""),
        .has_detail = @intFromBool(allowance_value.detail != null),
    };
    return .ok;
}

export fn costbar_snapshot_token_usage(
    snapshot: ?*const Snapshot,
    provider_index: usize,
    out_usage: ?*TokenUsageView,
) Status {
    const report = snapshotReport(snapshot, provider_index) orelse return .invalid_argument;
    const output = out_usage orelse return .invalid_argument;
    const usage = report.token_usage orelse return .unsupported;
    output.* = .{
        .period_start_unix = usage.period.start_unix,
        .period_end_exclusive_unix = usage.period.end_exclusive_unix,
        .input_tokens = usage.input_tokens,
        .output_tokens = usage.output_tokens,
        .cache_read_tokens = usage.cache_read_tokens,
        .cache_creation_tokens = usage.cache_creation_tokens,
        .reasoning_tokens = usage.reasoning_tokens,
        .source = bytesView(usage.source),
        .updated_at_unix = usage.updated_at_unix,
    };
    return .ok;
}

export fn costbar_snapshot_token_usage_window(
    snapshot: ?*const Snapshot,
    provider_index: usize,
    index: usize,
    out_window: ?*TokenUsageWindowView,
) Status {
    const report = snapshotReport(snapshot, provider_index) orelse return .invalid_argument;
    const output = out_window orelse return .invalid_argument;
    if (index >= report.token_usage_windows.len) return .invalid_argument;
    const window = report.token_usage_windows[index];
    output.* = .{
        .id = bytesView(window.id),
        .label = bytesView(window.label),
        .period_start_unix = window.period.start_unix,
        .period_end_exclusive_unix = window.period.end_exclusive_unix,
        .input_tokens = window.input_tokens,
        .output_tokens = window.output_tokens,
        .cache_read_tokens = window.cache_read_tokens,
        .cache_creation_tokens = window.cache_creation_tokens,
        .reasoning_tokens = window.reasoning_tokens,
    };
    return .ok;
}

export fn costbar_snapshot_financial(
    snapshot: ?*const Snapshot,
    provider_index: usize,
    index: usize,
    out_financial: ?*FinancialView,
) Status {
    const report = snapshotReport(snapshot, provider_index) orelse return .invalid_argument;
    const output = out_financial orelse return .invalid_argument;
    if (index >= report.financials.len) return .invalid_argument;
    const financial = report.financials[index];
    output.* = .{
        .currency = bytesView(financial.currency),
        .current_cost_micros = financial.current_cost_micros,
        .projected_cost_micros = optionalI64(financial.projected_cost_micros),
        .credit_remaining_micros = optionalI64(financial.credit_remaining_micros),
    };
    return .ok;
}

export fn costbar_bytes_free(bytes: Bytes) void {
    const ptr = bytes.ptr orelse return;
    allocator.free(@constCast(ptr[0..bytes.len]));
}

const WorkKind = union(enum) {
    remote: live_refresh.Kind,
    codex,
    claude,
    opencode,
};

const max_worker_count = std.meta.fields(live_refresh.Kind).len + 3;

const WorkerContext = struct {
    core: *Core,
    standard_client: *std.http.Client,
    credentials: live_refresh.Credentials,
    period: model.Period,
    home: []const u8,
    now: i64,
    kind: WorkKind,
    failure: ?anyerror = null,

    fn displayName(self: WorkerContext) []const u8 {
        return switch (self.kind) {
            .remote => |kind| switch (kind) {
                .digitalocean => "DigitalOcean",
                .ovh => "OVHcloud",
                .hetzner => "Hetzner",
                .cloudflare => "Cloudflare",
                .runpod => "Runpod",
                .vercel => "Vercel",
                .openrouter => "OpenRouter",
                .openai_api => "OpenAI API",
                .anthropic_api => "Anthropic API",
                .xai_api => "xAI (Grok) API",
                .github => "GitHub",
                .cursor => "Cursor",
            },
            .codex => "Codex",
            .claude => "Claude",
            .opencode => "OpenCode",
        };
    }
};

fn workerMain(context: *WorkerContext) void {
    runWorker(context) catch |err| {
        context.failure = err;
    };
}

fn runWorker(context: *WorkerContext) !void {
    switch (context.kind) {
        .remote => |kind| {
            if (kind == .github and context.credentials.github_use_cli) {
                if (context.home.len == 0) return error.HomeUnavailable;
                try live_refresh.refreshGitHubCLI(
                    allocator,
                    context.standard_client.io,
                    context.home,
                    &context.core.github_provider,
                    context.credentials.github_organization.?,
                    context.period,
                    context.now,
                );
                return;
            }
            try live_refresh.refresh(
                allocator,
                context.standard_client,
                liveProviders(context.core),
                context.credentials,
                kind,
                context.period,
                context.now,
            );
        },
        .codex => {
            if (context.home.len == 0) return error.HomeUnavailable;
            try context.core.codex_usage.refreshDefaultRoots(
                context.standard_client.io,
                context.home,
                localUsageDiscoveryPeriod(context.period, context.now),
            );
            var aggregate = try context.core.codex_usage.aggregatePeriod(context.period);
            defer aggregate.deinit();
            if (!aggregate.has_tokens and aggregate.limits == null) return error.NoLocalUsage;
            var usage_windows: [local_usage_window_definitions.len]codex.Codex.UsageWindow = undefined;
            const windows = try collectUsageWindows(
                codex.Codex,
                &context.core.codex_usage,
                context.now,
                &usage_windows,
            );
            try updateCodex(
                &context.core.codex_provider,
                aggregate,
                windows,
                context.period,
                context.now,
            );
        },
        .claude => {
            if (context.home.len == 0) return error.HomeUnavailable;
            try context.core.claude_usage.refreshDefaultRoots(
                context.standard_client.io,
                context.home,
                localUsageDiscoveryPeriod(context.period, context.now),
            );
            var aggregate = try context.core.claude_usage.aggregatePeriod(context.period);
            defer aggregate.deinit();
            const status_limits = try local_usage.readClaudeStatusLimits(
                allocator,
                context.standard_client.io,
                context.home,
            );
            if (!aggregate.has_tokens and status_limits == null) return error.NoLocalUsage;
            var usage_windows: [local_usage_window_definitions.len]claude.Claude.UsageWindow = undefined;
            const windows = try collectUsageWindows(
                claude.Claude,
                &context.core.claude_usage,
                context.now,
                &usage_windows,
            );
            try updateClaude(
                &context.core.claude_provider,
                aggregate,
                status_limits,
                windows,
                context.period,
                context.now,
            );
        },
        .opencode => {
            if (context.home.len == 0) return error.HomeUnavailable;
            try context.core.opencode_provider.refresh(
                allocator,
                context.standard_client.io,
                context.home,
                context.period,
                context.now,
            );
        },
    }
}

fn liveProviders(core: *Core) live_refresh.Providers {
    return .{
        .digitalocean = &core.digitalocean_provider,
        .ovh = &core.ovh_provider,
        .hetzner = &core.hetzner_provider,
        .cloudflare = &core.cloudflare_provider,
        .runpod = &core.runpod_provider,
        .vercel = &core.vercel_provider,
        .openrouter = &core.openrouter_provider,
        .openai_api = &core.openai_api_provider,
        .anthropic_api = &core.anthropic_api_provider,
        .xai_api = &core.xai_api_provider,
        .github = &core.github_provider,
        .cursor = &core.cursor_provider,
    };
}

fn credentialsFrom(settings: std.BufMap) live_refresh.Credentials {
    return .{
        .digitalocean_token = settings.get("digitalocean.token"),
        .ovh_endpoint = settings.get("ovh.endpoint"),
        .ovh_application_key = settings.get("ovh.application-key"),
        .ovh_application_secret = settings.get("ovh.application-secret"),
        .ovh_consumer_key = settings.get("ovh.consumer-key"),
        .ovh_project_id = settings.get("ovh.project-id"),
        .hetzner_token = settings.get("hetzner.token"),
        .cloudflare_token = settings.get("cloudflare.token"),
        .cloudflare_account_id = settings.get("cloudflare.account-id"),
        .runpod_api_key = settings.get("runpod.api-key"),
        .vercel_token = settings.get("vercel.token"),
        .vercel_team = settings.get("vercel.team"),
        .openrouter_api_key = settings.get("openrouter.api-key"),
        .openrouter_management_key = settings.get("openrouter.management-key"),
        .openai_admin_key = settings.get("openai.admin-key"),
        .anthropic_admin_key = settings.get("anthropic.admin-key"),
        .xai_management_key = settings.get("xai.management-key"),
        .xai_team_id = settings.get("xai.team-id"),
        .github_token = settings.get("github.token"),
        .github_organization = settings.get("github.organization"),
        .cursor_admin_key = settings.get("cursor.admin-key"),
    };
}

fn syncRemoteProviderConfiguration(
    core: *Core,
    credentials: live_refresh.Credentials,
) !void {
    inline for (std.meta.fields(live_refresh.Kind)) |field| {
        const kind: live_refresh.Kind = @enumFromInt(field.value);
        try core.registry.setConfigured(
            liveProviderId(kind),
            credentials.isConfigured(kind),
        );
    }
}

fn liveProviderId(kind: live_refresh.Kind) []const u8 {
    return switch (kind) {
        .digitalocean => "digitalocean",
        .ovh => "ovh",
        .hetzner => "hetzner",
        .cloudflare => "cloudflare",
        .runpod => "runpod",
        .vercel => "vercel",
        .openrouter => "openrouter",
        .openai_api => "openai-api",
        .anthropic_api => "anthropic-api",
        .xai_api => "xai-api",
        .github => "github",
        .cursor => "cursor",
    };
}

fn isKnownSetting(key: []const u8) bool {
    return inline for (.{
        "digitalocean.token",
        "ovh.endpoint",
        "ovh.application-key",
        "ovh.application-secret",
        "ovh.consumer-key",
        "ovh.project-id",
        "hetzner.token",
        "cloudflare.token",
        "cloudflare.account-id",
        "runpod.api-key",
        "vercel.token",
        "vercel.team",
        "openrouter.api-key",
        "openrouter.management-key",
        "openai.admin-key",
        "anthropic.admin-key",
        "xai.management-key",
        "xai.team-id",
        "github.token",
        "github.organization",
        "cursor.admin-key",
    }) |known| {
        if (std.mem.eql(u8, key, known)) break true;
    } else false;
}

fn credentialJSONName(key: []const u8) ?[]const u8 {
    const names = .{
        .{ "digitalocean.token", "digitalOceanToken" },
        .{ "ovh.endpoint", "ovhEndpoint" },
        .{ "ovh.application-key", "ovhApplicationKey" },
        .{ "ovh.application-secret", "ovhApplicationSecret" },
        .{ "ovh.consumer-key", "ovhConsumerKey" },
        .{ "ovh.project-id", "ovhProjectID" },
        .{ "hetzner.token", "hetznerToken" },
        .{ "cloudflare.token", "cloudflareToken" },
        .{ "cloudflare.account-id", "cloudflareAccountID" },
        .{ "runpod.api-key", "runpodAPIKey" },
        .{ "vercel.token", "vercelToken" },
        .{ "vercel.team", "vercelTeamIDOrSlug" },
        .{ "openrouter.api-key", "openRouterAPIKey" },
        .{ "openrouter.management-key", "openRouterManagementKey" },
        .{ "openai.admin-key", "openAIAdminKey" },
        .{ "anthropic.admin-key", "anthropicAdminKey" },
        .{ "xai.management-key", "xAIManagementKey" },
        .{ "xai.team-id", "xAITeamID" },
        .{ "github.token", "githubToken" },
        .{ "github.organization", "githubOrganization" },
        .{ "cursor.admin-key", "cursorAdminKey" },
    };
    return inline for (names) |entry| {
        if (std.mem.eql(u8, key, entry[0])) break entry[1];
    } else null;
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

fn tokenCounts(comptime ProviderType: type, tokens: local_usage.Tokens) ProviderType.TokenCounts {
    return .{
        .input_tokens = tokens.input,
        .output_tokens = tokens.output,
        .cache_read_tokens = tokens.cache_read,
        .cache_creation_tokens = tokens.cache_creation,
        .reasoning_tokens = tokens.reasoning,
    };
}

const LocalUsageWindowDefinition = struct {
    id: []const u8,
    label: []const u8,
    duration_seconds: i64,
};

const local_usage_window_definitions = [_]LocalUsageWindowDefinition{
    .{ .id = "hour", .label = "Last hour", .duration_seconds = std.time.s_per_hour },
    .{ .id = "day", .label = "Last 24 hours", .duration_seconds = std.time.s_per_day },
    .{ .id = "week", .label = "Last 7 days", .duration_seconds = 7 * std.time.s_per_day },
    .{ .id = "thirty-days", .label = "Last 30 days", .duration_seconds = 30 * std.time.s_per_day },
};

fn localUsagePeriod(now: i64, duration_seconds: i64) model.Period {
    return .{
        .start_unix = now -| duration_seconds,
        .end_exclusive_unix = now +| 1,
    };
}

fn localUsageDiscoveryPeriod(selected: model.Period, now: i64) model.Period {
    const history = localUsagePeriod(
        now,
        local_usage_window_definitions[local_usage_window_definitions.len - 1].duration_seconds,
    );
    return .{
        .start_unix = @min(selected.start_unix, history.start_unix),
        .end_exclusive_unix = @max(selected.end_exclusive_unix, history.end_exclusive_unix),
    };
}

fn collectUsageWindows(
    comptime ProviderType: type,
    collector: anytype,
    now: i64,
    output: *[local_usage_window_definitions.len]ProviderType.UsageWindow,
) ![]const ProviderType.UsageWindow {
    for (local_usage_window_definitions, 0..) |definition, index| {
        const period = localUsagePeriod(now, definition.duration_seconds);
        var aggregate = try collector.aggregatePeriod(period);
        defer aggregate.deinit();
        output[index] = .{
            .id = definition.id,
            .label = definition.label,
            .period = period,
            .token_usage = tokenCounts(ProviderType, aggregate.tokens),
        };
    }
    return output;
}

fn updateCodex(
    provider: *codex.Codex,
    aggregate: local_usage.Aggregate,
    usage_windows: []const codex.Codex.UsageWindow,
    period: model.Period,
    now: i64,
) !void {
    var allowances_buffer: [2]codex.Codex.Allowance = undefined;
    var labels: [2][32]u8 = undefined;
    var allowance_count: usize = 0;
    if (aggregate.limits) |limits| {
        if (limits.primary) |window| {
            allowances_buffer[allowance_count] = allowance(
                "primary",
                window,
                &labels[allowance_count],
            );
            allowance_count += 1;
        }
        if (limits.secondary) |window| {
            allowances_buffer[allowance_count] = allowance(
                "secondary",
                window,
                &labels[allowance_count],
            );
            allowance_count += 1;
        }
    }
    try provider.update(allocator, .{
        .period = period,
        .token_usage = tokenCounts(codex.Codex, aggregate.tokens),
        .token_usage_windows = usage_windows,
        .allowance_windows = allowances_buffer[0..allowance_count],
        .models = aggregate.models,
        .source = "Local Codex sessions",
        .updated_at_unix = now,
    });
}

fn updateClaude(
    provider: *claude.Claude,
    aggregate: local_usage.Aggregate,
    status_limits: ?local_usage.Limits,
    usage_windows: []const claude.Claude.UsageWindow,
    period: model.Period,
    now: i64,
) !void {
    var allowances_buffer: [2]claude.Claude.Allowance = undefined;
    var labels: [2][32]u8 = undefined;
    var allowance_count: usize = 0;
    if (status_limits orelse aggregate.limits) |limits| {
        if (limits.primary) |window| {
            allowances_buffer[allowance_count] = localAllowance(
                claude.Claude,
                "primary",
                window,
                &labels[allowance_count],
            );
            allowance_count += 1;
        }
        if (limits.secondary) |window| {
            allowances_buffer[allowance_count] = localAllowance(
                claude.Claude,
                "secondary",
                window,
                &labels[allowance_count],
            );
            allowance_count += 1;
        }
    }
    try provider.update(allocator, .{
        .period = period,
        .token_usage = tokenCounts(claude.Claude, aggregate.tokens),
        .token_usage_windows = usage_windows,
        .allowance_windows = allowances_buffer[0..allowance_count],
        .models = aggregate.models,
        .source = "Local Claude Code sessions",
        .updated_at_unix = now,
    });
}

fn localAllowance(
    comptime ProviderType: type,
    id: []const u8,
    window: local_usage.Window,
    label_buffer: *[32]u8,
) ProviderType.Allowance {
    const label = if (window.duration_minutes) |minutes|
        if (minutes == 300)
            "5 hour"
        else if (minutes == 10_080)
            "7 day"
        else
            std.fmt.bufPrint(label_buffer, "{d} min", .{minutes}) catch id
    else
        id;
    return .{
        .id = id,
        .label = label,
        .used_percent = window.used_percent,
        .resets_at_unix = window.resets_at_unix,
    };
}

fn allowance(
    id: []const u8,
    window: local_usage.Window,
    label_buffer: *[32]u8,
) codex.Codex.Allowance {
    return localAllowance(codex.Codex, id, window, label_buffer);
}

fn optionalI64(value: ?i64) OptionalI64 {
    return if (value) |found|
        .{ .value = found, .present = 1 }
    else
        .{};
}

fn snapshotReport(snapshot: ?*const Snapshot, provider_index: usize) ?model.ProviderReport {
    const dashboard = if (snapshot) |value| value.dashboard else return null;
    if (provider_index >= dashboard.providers.len) return null;
    return dashboard.providers[provider_index];
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
    try std.testing.expectEqual(@as(usize, 15), root.get("providers").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), root.get("totals").?.array.items.len);
    const providers = root.get("providers").?.array.items;
    try std.testing.expectEqualStrings(
        "not_configured",
        providers[0].object.get("summary").?.object.get("status").?.string,
    );
    try std.testing.expectEqual(std.json.Value.null, providers[0].object.get("summary").?.object.get("error_message").?);
}

test "C refresh with no configured providers performs no work" {
    const core = costbar_core_create() orelse return error.OutOfMemory;
    defer costbar_core_destroy(core);
    var result: RefreshResult = .{};
    try std.testing.expectEqual(Status.ok, costbar_core_refresh(core, .{
        .period_start_unix = 1,
        .period_end_exclusive_unix = 2,
        .track_codex = 0,
        .track_claude = 0,
        .track_opencode = 0,
        .use_github_cli = 0,
    }, &result));
    defer costbar_bytes_free(result.errors);
    try std.testing.expectEqual(@as(u32, 0), result.configured_count);
    try std.testing.expectEqual(@as(u32, 0), result.refreshed_count);
    try std.testing.expectEqual(@as(usize, 0), result.errors.len);
}

test "C snapshots distinguish configured providers from setup omissions" {
    const core = costbar_core_create() orelse return error.OutOfMemory;
    defer costbar_core_destroy(core);
    try std.testing.expectEqual(Status.ok, costbar_core_set_setting(
        core,
        bytesView("digitalocean.token"),
        bytesView("configured"),
    ));

    var bytes: Bytes = .{};
    try std.testing.expectEqual(Status.ok, costbar_core_snapshot_json(core, 1, 2, &bytes));
    defer costbar_bytes_free(bytes);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        bytes.ptr.?[0..bytes.len],
        .{},
    );
    defer parsed.deinit();
    const digitalocean_report = try providerObject(parsed.value, "digitalocean");
    const summary = digitalocean_report.get("summary").?.object;
    try std.testing.expectEqualStrings("unavailable", summary.get("status").?.string);
    try std.testing.expectEqualStrings("NotFetched", summary.get("error_message").?.string);

    const ovh_report = try providerObject(parsed.value, "ovh");
    const ovh_summary = ovh_report.get("summary").?.object;
    try std.testing.expectEqualStrings("not_configured", ovh_summary.get("status").?.string);
    try std.testing.expectEqual(std.json.Value.null, ovh_summary.get("error_message").?);
}

test "legacy credential JSON is decoded only inside Zig" {
    var value: Bytes = .{};
    try std.testing.expectEqual(Status.ok, costbar_decode_credential_json_field(
        bytesView("{\"digitalOceanToken\":\"secret\"}"),
        bytesView("digitalocean.token"),
        &value,
    ));
    defer costbar_bytes_free(value);
    try std.testing.expectEqualStrings("secret", value.ptr.?[0..value.len]);
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
    const runpod_report = try providerObject(parsed.value, "runpod");
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
    const vercel_report = try providerObject(parsed.value, "vercel");
    try std.testing.expectEqual(
        @as(i64, 4_750_000),
        vercel_report.get("summary").?.object.get("current_cost_micros").?.integer,
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        vercel_report.get("line_items").?.array.items.len,
    );
}

fn providerObject(root: std.json.Value, provider_id: []const u8) !std.json.ObjectMap {
    const reports = root.object.get("providers") orelse return error.InvalidResponse;
    for (reports.array.items) |report| {
        const summary = report.object.get("summary") orelse return error.InvalidResponse;
        const id = summary.object.get("id") orelse return error.InvalidResponse;
        if (std.mem.eql(u8, id.string, provider_id)) return report.object;
    }
    return error.ProviderNotFound;
}

fn bytesView(value: []const u8) Bytes {
    return .{ .ptr = value.ptr, .len = value.len };
}
