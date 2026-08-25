//! Profiles one complete Costbar refresh and reports where the time goes:
//! credential lookup, every provider HTTP request, response parsing, provider
//! aggregation, and snapshot encoding.
//!
//!     zig run -O ReleaseFast src/profile_refresh.zig -lc -- [OPTIONS]
//!
//!     --passes N   sequential passes per provider (default 2: cold, then warm)
//!     --local      also refresh every local scanner (Codex, Claude, OpenCode)
//!     --codex --claude --opencode   refresh one local scanner at a time
//!     --period S E period bounds as unix seconds (default: current UTC month)
//!
//! Tokens are read from the environment first (`DIGITALOCEAN_TOKEN`, …) and
//! otherwise from the same Keychain items the app uses, so macOS may prompt for
//! access once per item. Token values are never printed.

const std = @import("std");
const costbar = @import("root.zig").c_api;
const http = @import("http.zig");
const model = @import("model.zig");
const live_refresh = @import("live_refresh.zig");
const digitalocean = @import("providers/digitalocean.zig");
const ovh = @import("providers/ovh.zig");
const hetzner = @import("providers/hetzner.zig");
const cloudflare = @import("providers/cloudflare.zig");
const runpod = @import("providers/runpod.zig");
const vercel = @import("providers/vercel.zig");
const openrouter = @import("providers/openrouter.zig");
const openai_api = @import("providers/openai_api.zig");
const anthropic_api = @import("providers/anthropic_api.zig");
const xai_api = @import("providers/xai_api.zig");
const github = @import("providers/github.zig");
const cursor = @import("providers/cursor.zig");

extern fn costbar_core_create() ?*anyopaque;
extern fn costbar_core_destroy(core: ?*anyopaque) void;
extern fn costbar_core_set_setting(
    core: ?*anyopaque,
    key: costbar.Bytes,
    value: costbar.Bytes,
) costbar.Status;
extern fn costbar_core_refresh(
    core: ?*anyopaque,
    options: costbar.RefreshOptions,
    result: *costbar.RefreshResult,
) costbar.Status;
extern fn costbar_core_snapshot_json(
    core: ?*anyopaque,
    period_start_unix: i64,
    period_end_exclusive_unix: i64,
    out_json: *costbar.Bytes,
) costbar.Status;
extern fn costbar_core_snapshot_create(
    core: ?*anyopaque,
    period_start_unix: i64,
    period_end_exclusive_unix: i64,
    out_snapshot: *?*anyopaque,
) costbar.Status;
extern fn costbar_core_cached_snapshot_create(
    core: ?*anyopaque,
    period_start_unix: i64,
    period_end_exclusive_unix: i64,
    out_snapshot: *?*anyopaque,
) costbar.Status;
extern fn costbar_snapshot_destroy(snapshot: ?*anyopaque) void;
extern fn costbar_bytes_free(bytes: costbar.Bytes) void;

const keychain_service = "com.costbar.provider-credentials";

extern "c" fn SecKeychainFindGenericPassword(
    keychain_or_array: ?*anyopaque,
    service_name_length: u32,
    service_name: [*]const u8,
    account_name_length: u32,
    account_name: [*]const u8,
    password_length: *u32,
    password_data: *?*anyopaque,
    item_ref: ?*?*anyopaque,
) i32;
extern "c" fn SecKeychainItemFreeContent(
    attribute_list: ?*anyopaque,
    data: ?*anyopaque,
) i32;

const Setting = struct {
    key: []const u8,
    env: []const u8,
};

/// Every credential the core accepts, in the order the report lists them.
const settings = [_]Setting{
    .{ .key = "digitalocean.token", .env = "DIGITALOCEAN_TOKEN" },
    .{ .key = "ovh.endpoint", .env = "OVH_ENDPOINT" },
    .{ .key = "ovh.application-key", .env = "OVH_APPLICATION_KEY" },
    .{ .key = "ovh.application-secret", .env = "OVH_APPLICATION_SECRET" },
    .{ .key = "ovh.consumer-key", .env = "OVH_CONSUMER_KEY" },
    .{ .key = "ovh.project-id", .env = "OVH_CLOUD_PROJECT_SERVICE" },
    .{ .key = "hetzner.token", .env = "HCLOUD_TOKEN" },
    .{ .key = "cloudflare.token", .env = "CLOUDFLARE_TOKEN" },
    .{ .key = "cloudflare.account-id", .env = "CLOUDFLARE_ACCOUNT_ID" },
    .{ .key = "runpod.api-key", .env = "RUNPOD_API_KEY" },
    .{ .key = "vercel.token", .env = "VERCEL_TOKEN" },
    .{ .key = "vercel.team", .env = "VERCEL_TEAM" },
    .{ .key = "openrouter.api-key", .env = "OPENROUTER_API_KEY" },
    .{ .key = "openrouter.management-key", .env = "OPENROUTER_MANAGEMENT_KEY" },
    .{ .key = "openai.admin-key", .env = "OPENAI_ADMIN_KEY" },
    .{ .key = "anthropic.admin-key", .env = "ANTHROPIC_ADMIN_KEY" },
    .{ .key = "xai.management-key", .env = "XAI_MANAGEMENT_API_KEY" },
    .{ .key = "xai.team-id", .env = "XAI_TEAM_ID" },
    .{ .key = "github.token", .env = "GITHUB_TOKEN" },
    .{ .key = "github.organization", .env = "GITHUB_ORGANIZATION" },
    .{ .key = "cursor.admin-key", .env = "CURSOR_ADMIN_KEY" },
};

const Source = enum { environment, keychain, missing };

const Credential = struct {
    value: ?[]u8 = null,
    source: Source = .missing,
    lookup_ns: u64 = 0,
};

const Options = struct {
    passes: usize = 2,
    codex: bool = false,
    claude: bool = false,
    opencode: bool = false,
    period: ?model.Period = null,

    fn anyLocal(self: Options) bool {
        return self.codex or self.claude or self.opencode;
    }
};

/// One HTTP request as it happened, attributed to the provider that made it.
const Record = struct {
    kind: live_refresh.Kind,
    pass: usize,
    url: []u8,
    method: std.http.Method,
    status: u16,
    bytes: usize,
    elapsed_ns: u64,
};

/// One provider's sequential pass: wall clock split into transport and
/// everything else the provider does with the bytes.
const Sample = struct {
    kind: live_refresh.Kind,
    pass: usize,
    requests: usize,
    http_ns: u64,
    total_ns: u64,
    bytes: usize,
    failure: ?anyerror,

    fn parseNs(self: Sample) u64 {
        return if (self.total_ns > self.http_ns) self.total_ns - self.http_ns else 0;
    }
};

/// Wraps the production transport and times every request it performs.
const Probe = struct {
    inner: http.StdBackend,
    allocator: std.mem.Allocator,
    records: std.ArrayList(Record) = .empty,
    kind: live_refresh.Kind = .digitalocean,
    pass: usize = 0,

    fn deinit(self: *Probe) void {
        for (self.records.items) |entry| self.allocator.free(entry.url);
        self.records.deinit(self.allocator);
    }

    pub fn get(
        self: *Probe,
        allocator: std.mem.Allocator,
        request: http.Request,
    ) !http.Response {
        const started = monotonicNanoseconds();
        const response = self.inner.get(allocator, request) catch |err| {
            self.record(request, 0, 0, started);
            return err;
        };
        self.record(request, response.status, response.body.len, started);
        return response;
    }

    fn record(
        self: *Probe,
        request: http.Request,
        status: u16,
        bytes: usize,
        started: u64,
    ) void {
        const elapsed = monotonicNanoseconds() - started;
        const url = self.allocator.dupe(u8, request.url) catch return;
        self.records.append(self.allocator, .{
            .kind = self.kind,
            .pass = self.pass,
            .url = url,
            .method = request.method,
            .status = status,
            .bytes = bytes,
            .elapsed_ns = elapsed,
        }) catch self.allocator.free(url);
    }

    fn tail(self: *const Probe, from: usize) struct { requests: usize, ns: u64, bytes: usize } {
        var ns: u64 = 0;
        var bytes: usize = 0;
        for (self.records.items[from..]) |entry| {
            ns += entry.elapsed_ns;
            bytes += entry.bytes;
        }
        return .{ .requests = self.records.items.len - from, .ns = ns, .bytes = bytes };
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);
    const options = try parseOptions(args);

    const now = currentUnixTimestamp();
    const period = options.period orelse currentMonthPeriod(now);

    var credentials: [settings.len]Credential = @splat(.{});
    defer for (credentials) |credential| {
        if (credential.value) |value| allocator.free(value);
    };
    loadCredentials(allocator, &credentials);
    reportCredentials(credentials);

    const live = credentialsFrom(credentials);
    var configured: std.ArrayList(live_refresh.Kind) = .empty;
    defer configured.deinit(allocator);
    inline for (std.meta.fields(live_refresh.Kind)) |field| {
        const kind: live_refresh.Kind = @enumFromInt(field.value);
        if (live.isConfigured(kind)) try configured.append(allocator, kind);
    }
    var samples: std.ArrayList(Sample) = .empty;
    defer samples.deinit(allocator);

    if (configured.items.len == 0) {
        // The concurrent and core sections still say something useful: the
        // local scanners need no credentials at all.
        std.debug.print(
            "\nNo remote provider is configured, so there is nothing to fetch.\n",
            .{},
        );
    } else {
        var probe = try sequentialPasses(
            allocator,
            &samples,
            configured.items,
            live,
            period,
            now,
            options.passes,
        );
        defer probe.deinit();
        reportSamples(samples.items, options.passes);
        reportSlowestRequests(probe.records.items);
    }

    try reportConcurrentRefresh(credentials, period, options, samples.items);
}

fn parseOptions(args: []const [:0]const u8) !Options {
    var options = Options{};
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--local")) {
            options.codex = true;
            options.claude = true;
            options.opencode = true;
        } else if (std.mem.eql(u8, argument, "--codex")) {
            options.codex = true;
        } else if (std.mem.eql(u8, argument, "--claude")) {
            options.claude = true;
        } else if (std.mem.eql(u8, argument, "--opencode")) {
            options.opencode = true;
        } else if (std.mem.eql(u8, argument, "--passes")) {
            index += 1;
            if (index >= args.len) return error.MissingPassCount;
            options.passes = try std.fmt.parseInt(usize, args[index], 10);
            if (options.passes == 0) return error.MissingPassCount;
        } else if (std.mem.eql(u8, argument, "--period")) {
            if (index + 2 >= args.len) return error.MissingPeriod;
            options.period = .{
                .start_unix = try std.fmt.parseInt(i64, args[index + 1], 10),
                .end_exclusive_unix = try std.fmt.parseInt(i64, args[index + 2], 10),
            };
            index += 2;
        } else {
            std.debug.print("unknown argument: {s}\n", .{argument});
            return error.InvalidArguments;
        }
    }
    if (options.period) |value| try value.validate();
    return options;
}

fn loadCredentials(
    allocator: std.mem.Allocator,
    into: *[settings.len]Credential,
) void {
    for (settings, 0..) |setting, index| {
        const started = monotonicNanoseconds();
        if (environmentValue(allocator, setting.env)) |value| {
            into[index] = .{
                .value = value,
                .source = .environment,
                .lookup_ns = monotonicNanoseconds() - started,
            };
            continue;
        }
        const value = keychainValue(allocator, setting.key);
        into[index] = .{
            .value = value,
            .source = if (value == null) .missing else .keychain,
            .lookup_ns = monotonicNanoseconds() - started,
        };
    }
}

fn environmentValue(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    var buffer: [128]u8 = undefined;
    const name_z = std.fmt.bufPrintZ(&buffer, "{s}", .{name}) catch return null;
    const pointer = std.c.getenv(name_z) orelse return null;
    const value = std.mem.span(pointer);
    if (value.len == 0) return null;
    return allocator.dupe(u8, value) catch null;
}

/// Reads one item from the same login Keychain the app writes to. macOS asks
/// for permission the first time this binary touches an item, because the
/// profiler is not the signed app.
fn keychainValue(allocator: std.mem.Allocator, account: []const u8) ?[]u8 {
    var length: u32 = 0;
    var data: ?*anyopaque = null;
    const status = SecKeychainFindGenericPassword(
        null,
        @intCast(keychain_service.len),
        keychain_service.ptr,
        @intCast(account.len),
        account.ptr,
        &length,
        &data,
        null,
    );
    if (status != 0 or data == null) return null;
    defer _ = SecKeychainItemFreeContent(null, data);

    const bytes: [*]const u8 = @ptrCast(data.?);
    const value = std.mem.trim(u8, bytes[0..length], " \t\r\n");
    if (value.len == 0) return null;
    return allocator.dupe(u8, value) catch null;
}

fn credentialValue(credentials: [settings.len]Credential, key: []const u8) ?[]const u8 {
    for (settings, 0..) |setting, index| {
        if (std.mem.eql(u8, setting.key, key)) return credentials[index].value;
    }
    return null;
}

fn credentialsFrom(credentials: [settings.len]Credential) live_refresh.Credentials {
    return .{
        .digitalocean_token = credentialValue(credentials, "digitalocean.token"),
        .ovh_endpoint = credentialValue(credentials, "ovh.endpoint"),
        .ovh_application_key = credentialValue(credentials, "ovh.application-key"),
        .ovh_application_secret = credentialValue(credentials, "ovh.application-secret"),
        .ovh_consumer_key = credentialValue(credentials, "ovh.consumer-key"),
        .ovh_project_id = credentialValue(credentials, "ovh.project-id"),
        .hetzner_token = credentialValue(credentials, "hetzner.token"),
        .cloudflare_token = credentialValue(credentials, "cloudflare.token"),
        .cloudflare_account_id = credentialValue(credentials, "cloudflare.account-id"),
        .runpod_api_key = credentialValue(credentials, "runpod.api-key"),
        .vercel_token = credentialValue(credentials, "vercel.token"),
        .vercel_team = credentialValue(credentials, "vercel.team"),
        .openrouter_api_key = credentialValue(credentials, "openrouter.api-key"),
        .openrouter_management_key = credentialValue(credentials, "openrouter.management-key"),
        .openai_admin_key = credentialValue(credentials, "openai.admin-key"),
        .anthropic_admin_key = credentialValue(credentials, "anthropic.admin-key"),
        .xai_management_key = credentialValue(credentials, "xai.management-key"),
        .xai_team_id = credentialValue(credentials, "xai.team-id"),
        .github_token = credentialValue(credentials, "github.token"),
        .github_organization = credentialValue(credentials, "github.organization"),
        .cursor_admin_key = credentialValue(credentials, "cursor.admin-key"),
    };
}

fn sequentialPasses(
    allocator: std.mem.Allocator,
    samples: *std.ArrayList(Sample),
    kinds: []const live_refresh.Kind,
    credentials: live_refresh.Credentials,
    period: model.Period,
    now: i64,
    passes: usize,
) !Probe {
    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    defer io_threaded.deinit();
    var standard_client = std.http.Client{
        .allocator = allocator,
        .io = io_threaded.io(),
    };
    defer standard_client.deinit();

    var probe = Probe{
        .inner = .{ .client = &standard_client },
        .allocator = allocator,
    };
    var client = http.Client(Probe).init(&probe);

    var instances = Instances.init();
    defer instances.deinit();
    const providers = instances.providers();

    for (0..passes) |pass| {
        for (kinds) |kind| {
            probe.kind = kind;
            probe.pass = pass;
            const first_record = probe.records.items.len;
            const started = monotonicNanoseconds();
            var failure: ?anyerror = null;
            live_refresh.refreshWithClient(
                allocator,
                &client,
                providers,
                credentials,
                kind,
                period,
                now,
            ) catch |err| {
                failure = err;
            };
            const total_ns = monotonicNanoseconds() - started;
            const transport = probe.tail(first_record);
            try samples.append(allocator, .{
                .kind = kind,
                .pass = pass,
                .requests = transport.requests,
                .http_ns = transport.ns,
                .total_ns = total_ns,
                .bytes = transport.bytes,
                .failure = failure,
            });
        }
    }
    return probe;
}

/// Owns one instance of every remote provider, mirroring the set the core holds.
const Instances = struct {
    digitalocean: digitalocean.DigitalOcean,
    ovh: ovh.OVHcloud,
    hetzner: hetzner.Hetzner,
    cloudflare: cloudflare.Cloudflare,
    runpod: runpod.Runpod,
    vercel: vercel.Vercel,
    openrouter: openrouter.OpenRouter,
    openai_api: openai_api.OpenAIAPI,
    anthropic_api: anthropic_api.AnthropicAPI,
    xai_api: xai_api.XAIAPI,
    github: github.GitHub,
    cursor: cursor.Cursor,

    fn init() Instances {
        return .{
            .digitalocean = .init(),
            .ovh = .init(),
            .hetzner = .init(),
            .cloudflare = .init(),
            .runpod = .init(),
            .vercel = .init(),
            .openrouter = .init(),
            .openai_api = .init(),
            .anthropic_api = .init(),
            .xai_api = .init(),
            .github = .init(),
            .cursor = .init(),
        };
    }

    fn deinit(self: *Instances) void {
        self.digitalocean.deinit();
        self.ovh.deinit();
        self.hetzner.deinit();
        self.cloudflare.deinit();
        self.runpod.deinit();
        self.vercel.deinit();
        self.openrouter.deinit();
        self.openai_api.deinit();
        self.anthropic_api.deinit();
        self.xai_api.deinit();
        self.github.deinit();
        self.cursor.deinit();
    }

    fn providers(self: *Instances) live_refresh.Providers {
        return .{
            .digitalocean = &self.digitalocean,
            .ovh = &self.ovh,
            .hetzner = &self.hetzner,
            .cloudflare = &self.cloudflare,
            .runpod = &self.runpod,
            .vercel = &self.vercel,
            .openrouter = &self.openrouter,
            .openai_api = &self.openai_api,
            .anthropic_api = &self.anthropic_api,
            .xai_api = &self.xai_api,
            .github = &self.github,
            .cursor = &self.cursor,
        };
    }
};

fn reportCredentials(credentials: [settings.len]Credential) void {
    std.debug.print("CREDENTIALS\n", .{});
    var keychain_ns: u64 = 0;
    var keychain_reads: usize = 0;
    for (settings, 0..) |setting, index| {
        const credential = credentials[index];
        if (credential.source == .keychain) {
            keychain_ns += credential.lookup_ns;
            keychain_reads += 1;
        }
        std.debug.print("  {s:<28} {s:<12} {s}\n", .{
            setting.key,
            @tagName(credential.source),
            if (credential.value) |value|
                lengthLabel(value.len)
            else
                "-",
        });
    }
    if (keychain_reads > 0) {
        std.debug.print(
            "  {d} Keychain items read in {d:.1} ms" ++
                " (profiler only: the app uses SecItemCopyMatching in-process)\n",
            .{ keychain_reads, milliseconds(keychain_ns) },
        );
    }
}

fn reportSamples(samples: []const Sample, passes: usize) void {
    std.debug.print(
        "\nSEQUENTIAL PASSES (one provider at a time, {d} pass(es))\n",
        .{passes},
    );
    std.debug.print(
        "  {s:<14} {s:>4} {s:>5} {s:>10} {s:>10} {s:>10} {s:>10}  {s}\n",
        .{ "provider", "pass", "reqs", "http ms", "parse ms", "total ms", "KiB", "result" },
    );

    var http_ns: u64 = 0;
    var parse_ns: u64 = 0;
    var total_ns: u64 = 0;
    var bytes: usize = 0;
    var requests: usize = 0;
    for (samples) |sample| {
        std.debug.print(
            "  {s:<14} {d:>4} {d:>5} {d:>10.1} {d:>10.1} {d:>10.1} {d:>10.1}  {s}\n",
            .{
                @tagName(sample.kind),
                sample.pass,
                sample.requests,
                milliseconds(sample.http_ns),
                milliseconds(sample.parseNs()),
                milliseconds(sample.total_ns),
                kibibytes(sample.bytes),
                if (sample.failure) |err| @errorName(err) else "ok",
            },
        );
        if (sample.pass != 0) continue;
        http_ns += sample.http_ns;
        parse_ns += sample.parseNs();
        total_ns += sample.total_ns;
        bytes += sample.bytes;
        requests += sample.requests;
    }

    std.debug.print(
        "  {s:<14} {s:>4} {d:>5} {d:>10.1} {d:>10.1} {d:>10.1} {d:>10.1}\n",
        .{
            "cold total",
            "-",
            requests,
            milliseconds(http_ns),
            milliseconds(parse_ns),
            milliseconds(total_ns),
            kibibytes(bytes),
        },
    );
    if (total_ns > 0) {
        std.debug.print(
            "  transport is {d:.1}% of the cold sequential time\n",
            .{@as(f64, @floatFromInt(http_ns)) * 100 /
                @as(f64, @floatFromInt(total_ns))},
        );
    }
}

fn reportSlowestRequests(records: []Record) void {
    if (records.len == 0) {
        std.debug.print("\nNo HTTP request was performed.\n", .{});
        return;
    }
    std.mem.sort(Record, records, {}, slowestFirst);
    std.debug.print("\nSLOWEST REQUESTS (all passes)\n", .{});
    const shown = @min(records.len, 12);
    for (records[0..shown]) |record| {
        std.debug.print("  {d:>9.1} ms  {d:>3}  {d:>8.1} KiB  {s:<14} {s}\n", .{
            milliseconds(record.elapsed_ns),
            record.status,
            kibibytes(record.bytes),
            @tagName(record.kind),
            shortUrl(record.url),
        });
    }
}

fn slowestFirst(_: void, left: Record, right: Record) bool {
    return left.elapsed_ns > right.elapsed_ns;
}

fn reportConcurrentRefresh(
    credentials: [settings.len]Credential,
    period: model.Period,
    options: Options,
    samples: []const Sample,
) !void {
    const core = costbar_core_create() orelse return error.OutOfMemory;
    defer costbar_core_destroy(core);

    for (settings, 0..) |setting, index| {
        const value = credentials[index].value orelse continue;
        if (costbar_core_set_setting(
            core,
            bytesView(setting.key),
            bytesView(value),
        ) != .ok) {
            std.debug.print("could not apply setting {s}\n", .{setting.key});
        }
    }

    std.debug.print(
        "\nCONCURRENT REFRESH (the real path: one thread per provider)\n",
        .{},
    );
    const refresh_options = costbar.RefreshOptions{
        .period_start_unix = period.start_unix,
        .period_end_exclusive_unix = period.end_exclusive_unix,
        .track_codex = @intFromBool(options.codex),
        .track_claude = @intFromBool(options.claude),
        .track_opencode = @intFromBool(options.opencode),
        .use_github_cli = 0,
    };
    var wall_ns: [2]u64 = @splat(0);
    for (0..2) |iteration| {
        var result: costbar.RefreshResult = .{};
        const started = monotonicNanoseconds();
        const status = costbar_core_refresh(core, refresh_options, &result);
        wall_ns[iteration] = monotonicNanoseconds() - started;
        defer costbar_bytes_free(result.errors);
        if (status != .ok) {
            std.debug.print("  refresh failed with status {s}\n", .{@tagName(status)});
            return;
        }
        std.debug.print("  {s:<6} {d:>9.1} ms  ({d}/{d} refreshed)\n", .{
            if (iteration == 0) "cold" else "warm",
            milliseconds(wall_ns[iteration]),
            result.refreshed_count,
            result.configured_count,
        });
        if (result.errors.ptr) |pointer| {
            var lines = std.mem.splitScalar(u8, pointer[0..result.errors.len], '\n');
            while (lines.next()) |line| {
                if (line.len > 0) std.debug.print("         {s}\n", .{line});
            }
        }
    }

    var critical: ?Sample = null;
    for (samples) |sample| {
        if (sample.pass != 0) continue;
        if (critical == null or sample.total_ns > critical.?.total_ns) critical = sample;
    }
    if (critical) |slowest| {
        std.debug.print(
            "  critical path: {s} at {d:.1} ms; the refresh cannot beat that\n",
            .{ @tagName(slowest.kind), milliseconds(slowest.total_ns) },
        );
        if (wall_ns[0] > slowest.total_ns) {
            std.debug.print(
                "  {d:.1} ms of the cold wall clock is above the critical path\n",
                .{milliseconds(wall_ns[0] - slowest.total_ns)},
            );
        }
    }

    try reportCoreWork(core, period);
}

fn reportCoreWork(core: ?*anyopaque, period: model.Period) !void {
    std.debug.print("\nCORE (CPU only, best of 20)\n", .{});

    var json_ns: u64 = std.math.maxInt(u64);
    var json_len: usize = 0;
    for (0..20) |_| {
        var bytes = costbar.Bytes{};
        const started = monotonicNanoseconds();
        const status = costbar_core_snapshot_json(
            core,
            period.start_unix,
            period.end_exclusive_unix,
            &bytes,
        );
        const elapsed = monotonicNanoseconds() - started;
        if (status != .ok) break;
        defer costbar_bytes_free(bytes);
        json_ns = @min(json_ns, elapsed);
        json_len = bytes.len;
    }
    if (json_len > 0) {
        std.debug.print(
            "  collect + JSON encode      {d:>8.3} ms  ({d:.1} KiB)\n",
            .{ milliseconds(json_ns), kibibytes(json_len) },
        );
    }

    var struct_ns: u64 = std.math.maxInt(u64);
    for (0..20) |_| {
        var snapshot: ?*anyopaque = null;
        const started = monotonicNanoseconds();
        const status = costbar_core_snapshot_create(
            core,
            period.start_unix,
            period.end_exclusive_unix,
            &snapshot,
        );
        const elapsed = monotonicNanoseconds() - started;
        if (status != .ok) break;
        costbar_snapshot_destroy(snapshot);
        struct_ns = @min(struct_ns, elapsed);
    }
    if (struct_ns != std.math.maxInt(u64)) {
        std.debug.print(
            "  collect (struct handle)    {d:>8.3} ms  the path the app uses\n",
            .{milliseconds(struct_ns)},
        );
    }

    var cached_ns: u64 = std.math.maxInt(u64);
    for (0..20) |_| {
        var snapshot: ?*anyopaque = null;
        const started = monotonicNanoseconds();
        const status = costbar_core_cached_snapshot_create(
            core,
            period.start_unix,
            period.end_exclusive_unix,
            &snapshot,
        );
        const elapsed = monotonicNanoseconds() - started;
        if (status != .ok) break;
        costbar_snapshot_destroy(snapshot);
        cached_ns = @min(cached_ns, elapsed);
    }
    if (cached_ns != std.math.maxInt(u64)) {
        std.debug.print(
            "  cached snapshot restore    {d:>8.3} ms  what launch shows first\n",
            .{milliseconds(cached_ns)},
        );
    } else {
        std.debug.print(
            "  cached snapshot restore    unavailable for this period\n",
            .{},
        );
    }
}

fn bytesView(value: []const u8) costbar.Bytes {
    return .{ .ptr = value.ptr, .len = value.len };
}

fn lengthLabel(length: usize) []const u8 {
    return switch (length) {
        0 => "empty",
        1...15 => "short",
        else => "present",
    };
}

/// Host and path only, clipped so the table stays readable.
fn shortUrl(url: []const u8) []const u8 {
    const without_scheme = if (std.mem.indexOf(u8, url, "://")) |index|
        url[index + 3 ..]
    else
        url;
    return if (without_scheme.len > 74) without_scheme[0..74] else without_scheme;
}

fn milliseconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms;
}

fn kibibytes(bytes: usize) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1024;
}

fn monotonicNanoseconds() u64 {
    var timestamp: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &timestamp) != 0) return 0;
    return @as(u64, @intCast(timestamp.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(timestamp.nsec));
}

fn currentUnixTimestamp() i64 {
    var timestamp: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &timestamp) != 0) return 0;
    return timestamp.sec;
}

/// UTC month containing `now`, matching what the app asks the core for.
fn currentMonthPeriod(now: i64) model.Period {
    const seconds: u64 = @intCast(@max(now, 0));
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = seconds };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const seconds_per_day: i64 = std.time.epoch.secs_per_day;
    const start_day = epoch_day.day - month_day.day_index;
    const start = @as(i64, start_day) * seconds_per_day;
    const days_in_month = std.time.epoch.getDaysInMonth(year_day.year, month_day.month);
    return .{
        .start_unix = start,
        .end_exclusive_unix = start + @as(i64, days_in_month) * seconds_per_day,
    };
}
