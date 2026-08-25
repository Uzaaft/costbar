const std = @import("std");
const model = @import("../model.zig");
const money = @import("../money.zig");

const ModelUsage = struct {
    id: []const u8,
    provider: []const u8,
    model: []const u8,
    amount_micros: i64,
    input: u64,
    output: u64,
    reasoning: u64,
    cache_read: u64,
    cache_write: u64,
    detail: []const u8,

    fn totalTokens(self: ModelUsage) u64 {
        var total = self.input;
        total +|= self.output;
        total +|= self.reasoning;
        total +|= self.cache_read;
        total +|= self.cache_write;
        return total;
    }
};

const OwnedUsage = struct {
    arena: std.heap.ArenaAllocator,
    period: model.Period,
    models: []ModelUsage,
    updated_at_unix: i64,

    fn deinit(self: *OwnedUsage) void {
        self.arena.deinit();
    }
};

pub const OpenCode = struct {
    usage: ?OwnedUsage = null,

    pub fn init() OpenCode {
        return .{};
    }

    pub fn deinit(self: *OpenCode) void {
        if (self.usage) |*usage| usage.deinit();
        self.usage = null;
    }

    pub fn metadata(_: *const OpenCode) model.ProviderMetadata {
        return .{ .id = "opencode", .display_name = "OpenCode", .kind = .developer_tool };
    }

    pub fn ingest(
        self: *OpenCode,
        allocator: std.mem.Allocator,
        document_id: []const u8,
        payload: []const u8,
        received_at_unix: i64,
    ) !void {
        if (!std.mem.eql(u8, document_id, "local-usage")) {
            return error.UnsupportedDocument;
        }
        var replacement = try parseUsage(allocator, payload, received_at_unix);
        errdefer replacement.deinit();
        if (self.usage) |*existing| existing.deinit();
        self.usage = replacement;
    }

    /// Queries the OpenCode CLI, but only when the database it reads has moved
    /// on. `opencode db` costs roughly 400 ms of process start-up before it
    /// opens anything, which the app would otherwise pay on every poll, so a
    /// result that still matches the database and its write-ahead log is
    /// replayed from disk instead. A failing or missing CLI falls back to the
    /// last cached answer for the same period rather than dropping the row.
    pub fn refresh(
        self: *OpenCode,
        allocator: std.mem.Allocator,
        io: std.Io,
        home: []const u8,
        period: model.Period,
        received_at_unix: i64,
    ) !void {
        try period.validate();
        const database_path = try databasePath(allocator, home);
        defer if (database_path) |path| allocator.free(path);
        const current = if (database_path) |path|
            fingerprint(io, path, period)
        else
            null;

        const cache_path = if (database_path) |path|
            cachePath(allocator, io, home, path) catch null
        else
            null;
        defer if (cache_path) |path| allocator.free(path);

        var cached: ?OwnedCache = if (cache_path) |path|
            loadCache(allocator, io, path) catch null
        else
            null;
        defer if (cached) |*value| value.deinit();

        if (cached) |value| {
            if (current) |validators| {
                if (value.entry.fingerprint.matches(validators)) {
                    // The database has not changed, so the cached answer is not
                    // stale data: it is the current answer, timestamped now.
                    return self.ingest(
                        allocator,
                        "local-usage",
                        value.entry.payload,
                        received_at_unix,
                    );
                }
            }
        }

        const query = try usageQuery(allocator, period);
        defer allocator.free(query);
        const rows = runQuery(allocator, io, home, query) catch |err| {
            if (cached) |value| {
                if (value.entry.fingerprint.coversPeriod(period)) {
                    // Keep the last answer visible, dated when it was taken.
                    return self.ingest(
                        allocator,
                        "local-usage",
                        value.entry.payload,
                        value.entry.updated_at_unix,
                    );
                }
            }
            return err;
        };
        defer allocator.free(rows);

        const payload = try wrappedPayload(allocator, period, rows);
        defer allocator.free(payload);
        try self.ingest(allocator, "local-usage", payload, received_at_unix);

        if (cache_path) |path| {
            if (current) |validators| {
                storeCache(allocator, io, path, validators, received_at_unix, payload) catch {};
            }
        }
    }

    pub fn collect(
        self: *OpenCode,
        allocator: std.mem.Allocator,
        _: model.Period,
    ) !model.ProviderReport {
        const usage = self.usage orelse return error.NotFetched;
        const resources = try allocator.alloc(model.Resource, usage.models.len);
        errdefer allocator.free(resources);
        const line_items = try allocator.alloc(model.CostLineItem, usage.models.len);
        errdefer allocator.free(line_items);
        var current: i64 = 0;
        var tokens = model.TokenUsage{
            .period = usage.period,
            .source = "OpenCode local database via official CLI",
            .updated_at_unix = usage.updated_at_unix,
        };
        for (usage.models, 0..) |entry, index| {
            current = std.math.add(i64, current, entry.amount_micros) catch
                return error.AmountOverflow;
            resources[index] = .{
                .id = entry.id,
                .name = entry.model,
                .kind = entry.provider,
                .status = .active,
                .quantity = entry.totalTokens(),
            };
            line_items[index] = .{
                .id = entry.id,
                .description = entry.model,
                .service = entry.provider,
                .amount_micros = entry.amount_micros,
                .currency = "USD",
                .detail = entry.detail,
            };
            tokens.input_tokens +|= entry.input;
            tokens.output_tokens +|= entry.output;
            tokens.reasoning_tokens +|= entry.reasoning;
            tokens.cache_read_tokens +|= entry.cache_read;
            tokens.cache_creation_tokens +|= entry.cache_write;
        }
        return .{
            .summary = .{
                .id = "opencode",
                .display_name = "OpenCode",
                .kind = .developer_tool,
                .currency = "USD",
                .current_cost_micros = current,
                // OpenCode stores model/list cost. It can overlap a provider's
                // authoritative bill or represent usage included in Go.
                .contributes_to_totals = false,
                .updated_at_unix = usage.updated_at_unix,
            },
            .resources = resources,
            .line_items = line_items,
            .token_usage = tokens,
        };
    }
};

const database_relative_path = ".local/share/opencode/opencode.db";
const cache_relative_directory = "Library/Caches/Costbar/local-usage/opencode-v1";
const cache_version: u32 = 1;
const max_cache_bytes = 8 * 1024 * 1024;

/// Everything that has to be unchanged for a cached CLI answer to still be the
/// right answer. These are SQLite's own write markers rather than file
/// timestamps: `opencode db` bumps the database mtime just by opening it, so an
/// mtime-keyed cache would invalidate itself on every single query, while the
/// header counters and write-ahead log salts stay put unless something was
/// actually committed.
const Fingerprint = struct {
    database_size: u64 = 0,
    /// SQLite header offset 24: incremented by every write transaction.
    change_counter: u32 = 0,
    /// SQLite header offset 28: database size in pages.
    page_count: u32 = 0,
    wal_size: u64 = 0,
    /// WAL header offset 12: checkpoint sequence number.
    wal_checkpoint: u32 = 0,
    /// WAL header offsets 16 and 20: salts, rewritten when the log resets.
    wal_salt_1: u32 = 0,
    wal_salt_2: u32 = 0,
    period_start_unix: i64,
    period_end_exclusive_unix: i64,

    fn matches(self: Fingerprint, other: Fingerprint) bool {
        return self.database_size == other.database_size and
            self.change_counter == other.change_counter and
            self.page_count == other.page_count and
            self.wal_size == other.wal_size and
            self.wal_checkpoint == other.wal_checkpoint and
            self.wal_salt_1 == other.wal_salt_1 and
            self.wal_salt_2 == other.wal_salt_2 and
            self.coversPeriod(.{
                .start_unix = other.period_start_unix,
                .end_exclusive_unix = other.period_end_exclusive_unix,
            });
    }

    /// A cached answer for a different period is never a substitute: last
    /// month's spend must not be shown as this month's.
    fn coversPeriod(self: Fingerprint, period: model.Period) bool {
        return self.period_start_unix == period.start_unix and
            self.period_end_exclusive_unix == period.end_exclusive_unix;
    }
};

const CachedQuery = struct {
    version: u32,
    fingerprint: Fingerprint,
    updated_at_unix: i64,
    /// The exact document `ingest` accepts, so a replay parses one way only.
    payload: []const u8,
};

const OwnedCache = struct {
    arena: std.heap.ArenaAllocator,
    entry: CachedQuery,

    fn deinit(self: *OwnedCache) void {
        self.arena.deinit();
    }
};

fn databasePath(allocator: std.mem.Allocator, home: []const u8) !?[]u8 {
    if (home.len == 0) return null;
    return try std.fs.path.join(allocator, &.{ home, database_relative_path });
}

const database_header_bytes = 100;
const wal_header_bytes = 32;

/// Null when the database cannot be inspected, which keeps an unverifiable
/// cache out of the fresh path while still allowing it as a fallback.
fn fingerprint(io: std.Io, database_path: []const u8, period: model.Period) ?Fingerprint {
    var result = Fingerprint{
        .period_start_unix = period.start_unix,
        .period_end_exclusive_unix = period.end_exclusive_unix,
    };

    var header: [database_header_bytes]u8 = undefined;
    const database = readHeader(io, database_path, &header) orelse return null;
    result.database_size = database.size;
    if (database.read >= 32) {
        result.change_counter = std.mem.readInt(u32, header[24..28], .big);
        result.page_count = std.mem.readInt(u32, header[28..32], .big);
    }

    var wal_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const wal_path = std.fmt.bufPrint(
        &wal_path_buffer,
        "{s}-wal",
        .{database_path},
    ) catch return result;
    var wal_header: [wal_header_bytes]u8 = undefined;
    if (readHeader(io, wal_path, &wal_header)) |wal| {
        result.wal_size = wal.size;
        if (wal.read >= 24) {
            result.wal_checkpoint = std.mem.readInt(u32, wal_header[12..16], .big);
            result.wal_salt_1 = std.mem.readInt(u32, wal_header[16..20], .big);
            result.wal_salt_2 = std.mem.readInt(u32, wal_header[20..24], .big);
        }
    }
    return result;
}

const HeaderRead = struct {
    size: u64,
    read: usize,
};

/// Reads only the leading header bytes: the database itself is gigabytes.
fn readHeader(io: std.Io, path: []const u8, buffer: []u8) ?HeaderRead {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer file.close(io);
    const info = file.stat(io) catch return null;
    @memset(buffer, 0);
    return .{
        .size = info.size,
        .read = file.readPositionalAll(io, buffer, 0) catch 0,
    };
}

fn cachePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    database_path: []const u8,
) !?[]u8 {
    if (home.len == 0) return null;
    const directory = try std.fs.path.join(allocator, &.{ home, cache_relative_directory });
    defer allocator.free(directory);
    _ = std.Io.Dir.createDirPathStatus(
        .cwd(),
        io,
        directory,
        .fromMode(0o700),
    ) catch return null;

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(database_path, &digest, .{});
    const filename = try std.fmt.allocPrint(
        allocator,
        "{s}.json",
        .{std.fmt.bytesToHex(digest, .lower)},
    );
    defer allocator.free(filename);
    return try std.fs.path.join(allocator, &.{ directory, filename });
}

fn loadCache(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_path: []const u8,
) !?OwnedCache {
    const bytes = try std.Io.Dir.readFileAlloc(
        .cwd(),
        io,
        cache_path,
        allocator,
        .limited(max_cache_bytes),
    );
    defer allocator.free(bytes);

    var result = OwnedCache{ .arena = .init(allocator), .entry = undefined };
    errdefer result.deinit();
    result.entry = std.json.parseFromSliceLeaky(
        CachedQuery,
        result.arena.allocator(),
        bytes,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return error.InvalidCache;
    if (result.entry.version != cache_version or result.entry.payload.len == 0) {
        result.deinit();
        return null;
    }
    return result;
}

fn storeCache(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_path: []const u8,
    validators: Fingerprint,
    updated_at_unix: i64,
    payload: []const u8,
) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, CachedQuery{
        .version = cache_version,
        .fingerprint = validators,
        .updated_at_unix = updated_at_unix,
        .payload = payload,
    }, .{});
    defer allocator.free(bytes);
    if (bytes.len > max_cache_bytes) return error.CacheTooLarge;

    const temporary = try std.fmt.allocPrint(allocator, "{s}.costbar-tmp", .{cache_path});
    defer allocator.free(temporary);
    errdefer std.Io.Dir.deleteFileAbsolute(io, temporary) catch {};
    try std.Io.Dir.writeFile(.cwd(), io, .{
        .sub_path = temporary,
        .data = bytes,
        .flags = .{ .permissions = .fromMode(0o600) },
    });
    try std.Io.Dir.renameAbsolute(temporary, cache_path, io);
}

fn usageQuery(allocator: std.mem.Allocator, period: model.Period) ![]u8 {
    try period.validate();
    const start_millis = std.math.mul(i64, period.start_unix, 1000) catch
        return error.InvalidPeriod;
    const end_millis = std.math.mul(i64, period.end_exclusive_unix, 1000) catch
        return error.InvalidPeriod;
    return std.fmt.allocPrint(allocator,
        \\SELECT
        \\ COALESCE(json_extract(data, '$.providerID'), 'unknown') AS provider,
        \\ COALESCE(json_extract(data, '$.modelID'), 'unknown') AS model,
        \\ SUM(COALESCE(json_extract(data, '$.cost'), 0)) AS cost,
        \\ SUM(COALESCE(json_extract(data, '$.tokens.input'), 0)) AS input,
        \\ SUM(COALESCE(json_extract(data, '$.tokens.output'), 0)) AS output,
        \\ SUM(COALESCE(json_extract(data, '$.tokens.reasoning'), 0)) AS reasoning,
        \\ SUM(COALESCE(json_extract(data, '$.tokens.cache.read'), 0)) AS cache_read,
        \\ SUM(COALESCE(json_extract(data, '$.tokens.cache.write'), 0)) AS cache_write
        \\FROM message
        \\WHERE json_extract(data, '$.role') = 'assistant'
        \\ AND time_created >= {d}
        \\ AND time_created < {d}
        \\GROUP BY provider, model
        \\ORDER BY cost DESC, provider ASC, model ASC
    , .{ start_millis, end_millis });
}

fn runQuery(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    query: []const u8,
) ![]u8 {
    const home_executable = try std.fs.path.join(allocator, &.{ home, ".opencode/bin/opencode" });
    defer allocator.free(home_executable);
    const candidates = [_][]const u8{
        home_executable,
        "/opt/homebrew/bin/opencode",
        "/usr/local/bin/opencode",
        "opencode",
    };
    for (candidates) |executable| {
        const result = std.process.run(allocator, io, .{
            .argv = &.{ executable, "db", "--format", "json", query },
            .stdout_limit = .limited(32 * 1024 * 1024),
            .stderr_limit = .limited(1024 * 1024),
        }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        allocator.free(result.stderr);
        switch (result.term) {
            .exited => |code| if (code == 0) return result.stdout,
            else => {},
        }
        allocator.free(result.stdout);
        return error.OpenCodeQueryFailed;
    }
    return error.OpenCodeNotInstalled;
}

fn parseUsage(
    allocator: std.mem.Allocator,
    payload: []const u8,
    received_at_unix: i64,
) !OwnedUsage {
    var result = OwnedUsage{
        .arena = .init(allocator),
        .period = undefined,
        .models = &.{},
        .updated_at_unix = received_at_unix,
    };
    errdefer result.deinit();
    const arena = result.arena.allocator();
    const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, payload, .{
        .allocate = .alloc_always,
        .parse_numbers = false,
    });
    const root = try object(value);
    result.period = try parsePeriod(root.get("period") orelse return error.InvalidResponse);
    const rows = try array(root.get("rows") orelse return error.InvalidResponse);
    var models: std.ArrayList(ModelUsage) = .empty;
    for (rows.items) |row_value| {
        const row = try object(row_value);
        const provider = optionalString(row.get("provider")) orelse "unknown";
        const model_name = optionalString(row.get("model")) orelse "unknown";
        const input = try optionalU64(row.get("input")) orelse 0;
        const output = try optionalU64(row.get("output")) orelse 0;
        const reasoning = try optionalU64(row.get("reasoning")) orelse 0;
        const cache_read = try optionalU64(row.get("cache_read")) orelse 0;
        const cache_write = try optionalU64(row.get("cache_write")) orelse 0;
        var total_tokens = input;
        total_tokens +|= output;
        total_tokens +|= reasoning;
        total_tokens +|= cache_read;
        total_tokens +|= cache_write;
        try models.append(arena, .{
            .id = try std.fmt.allocPrint(arena, "{s}/{s}", .{ provider, model_name }),
            .provider = provider,
            .model = model_name,
            .amount_micros = try optionalMoney(row.get("cost")) orelse 0,
            .input = input,
            .output = output,
            .reasoning = reasoning,
            .cache_read = cache_read,
            .cache_write = cache_write,
            .detail = try std.fmt.allocPrint(arena, "{d} tokens", .{total_tokens}),
        });
    }
    result.models = try models.toOwnedSlice(arena);
    std.mem.sort(ModelUsage, result.models, {}, usageDescending);
    return result;
}

fn wrappedPayload(
    allocator: std.mem.Allocator,
    period: model.Period,
    rows: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"period\":{{\"start_unix\":{d},\"end_exclusive_unix\":{d}}},\"rows\":{s}}}",
        .{ period.start_unix, period.end_exclusive_unix, rows },
    );
}

fn parsePeriod(value: std.json.Value) !model.Period {
    const period_object = try object(value);
    const period = model.Period{
        .start_unix = try requireI64(period_object.get("start_unix") orelse
            return error.InvalidResponse),
        .end_exclusive_unix = try requireI64(period_object.get("end_exclusive_unix") orelse
            return error.InvalidResponse),
    };
    try period.validate();
    return period;
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    if (value != .object) return error.InvalidResponse;
    return value.object;
}

fn array(value: std.json.Value) !std.json.Array {
    if (value != .array) return error.InvalidResponse;
    return value.array;
}

fn optionalString(value: ?std.json.Value) ?[]const u8 {
    const found = value orelse return null;
    return if (found == .string) found.string else null;
}

fn optionalMoney(value: ?std.json.Value) !?i64 {
    const found = value orelse return null;
    if (found == .null) return null;
    return switch (found) {
        .number_string, .string => |number| try money.parseRoundedMicros(number),
        .integer => |integer| std.math.mul(i64, integer, money.micros_per_unit) catch
            error.AmountOverflow,
        else => error.InvalidAmount,
    };
}

fn optionalU64(value: ?std.json.Value) !?u64 {
    const found = value orelse return null;
    if (found == .null) return null;
    return switch (found) {
        .integer => |integer| if (integer >= 0) @intCast(integer) else error.InvalidAmount,
        .number_string, .string => |number| @as(?u64, try std.fmt.parseInt(u64, number, 10)),
        else => error.InvalidAmount,
    };
}

fn requireI64(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |integer| integer,
        .number_string, .string => |number| std.fmt.parseInt(i64, number, 10),
        else => error.InvalidResponse,
    };
}

fn usageDescending(_: void, left: ModelUsage, right: ModelUsage) bool {
    if (left.amount_micros != right.amount_micros) {
        return left.amount_micros > right.amount_micros;
    }
    return left.totalTokens() > right.totalTokens();
}

test "OpenCode parses exact local cost and token metadata" {
    const period = model.Period{ .start_unix = 1, .end_exclusive_unix = 200 };
    const rows =
        \\[{"provider":"opencode-go","model":"kimi","cost":0,"input":100,"output":20,"reasoning":5,"cache_read":40,"cache_write":2},
        \\ {"provider":"openrouter","model":"grok","cost":1.25,"input":10,"output":3,"reasoning":0,"cache_read":0,"cache_write":0}]
    ;
    const payload = try wrappedPayload(std.testing.allocator, period, rows);
    defer std.testing.allocator.free(payload);
    var provider = OpenCode.init();
    defer provider.deinit();
    try provider.ingest(std.testing.allocator, "local-usage", payload, 100);
    const report = try provider.collect(std.testing.allocator, period);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 1_250_000), report.summary.current_cost_micros);
    try std.testing.expect(!report.summary.contributes_to_totals);
    try std.testing.expectEqual(@as(u64, 110), report.token_usage.?.input_tokens);
    try std.testing.expectEqual(@as(u64, 40), report.token_usage.?.cache_read_tokens);
    try std.testing.expectEqualStrings("openrouter/grok", report.resources[0].id);
}

test "OpenCode SQL query is period-bounded and selects no content" {
    const query = try usageQuery(std.testing.allocator, .{
        .start_unix = 10,
        .end_exclusive_unix = 20,
    });
    defer std.testing.allocator.free(query);
    try std.testing.expect(std.mem.indexOf(u8, query, "time_created >= 10000") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "time_created < 20000") != null);
    try std.testing.expect(std.mem.indexOf(u8, query, "prompt") == null);
    try std.testing.expect(std.mem.indexOf(u8, query, "parts") == null);
}

test "OpenCode reuses a cached query only while the database is unchanged" {
    const allocator = std.testing.allocator;
    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home = try std.fmt.bufPrint(
        &home_buffer,
        "/tmp/costbar-opencode-cache-{d}",
        .{std.c.getpid()},
    );
    std.Io.Dir.deleteTree(.cwd(), io, home) catch {};
    defer std.Io.Dir.deleteTree(.cwd(), io, home) catch {};

    const database = (try databasePath(allocator, home)).?;
    defer allocator.free(database);
    try std.Io.Dir.createDirPath(.cwd(), io, std.fs.path.dirname(database).?);
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = database, .data = "sqlite" });

    const period = model.Period{ .start_unix = 10, .end_exclusive_unix = 20 };
    const before = fingerprint(io, database, period).?;
    const cache_file = (try cachePath(allocator, io, home, database)).?;
    defer allocator.free(cache_file);

    const payload = try wrappedPayload(
        allocator,
        period,
        \\[{"provider":"openrouter","model":"grok","cost":1.25,"input":10}]
    );
    defer allocator.free(payload);
    try storeCache(allocator, io, cache_file, before, 500, payload);

    var cached = (try loadCache(allocator, io, cache_file)).?;
    defer cached.deinit();
    try std.testing.expect(cached.entry.fingerprint.matches(before));
    try std.testing.expectEqual(@as(i64, 500), cached.entry.updated_at_unix);

    // The replayed payload is the same document the CLI path ingests.
    var provider = OpenCode.init();
    defer provider.deinit();
    try provider.ingest(
        allocator,
        "local-usage",
        cached.entry.payload,
        cached.entry.updated_at_unix,
    );
    const report = try provider.collect(allocator, period);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 1_250_000), report.summary.current_cost_micros);
    try std.testing.expectEqual(@as(i64, 500), report.summary.updated_at_unix);

    // A write to the database retires the cache for the fresh path, while it
    // stays eligible as the fallback for the very same period.
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = database, .data = "sqlite and more" });
    const after = fingerprint(io, database, period).?;
    try std.testing.expect(!cached.entry.fingerprint.matches(after));
    try std.testing.expect(cached.entry.fingerprint.coversPeriod(period));
    try std.testing.expect(!cached.entry.fingerprint.coversPeriod(.{
        .start_unix = 10,
        .end_exclusive_unix = 21,
    }));
}

test "OpenCode ignores a cache written by another version" {
    const allocator = std.testing.allocator;
    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cache_file = try std.fmt.bufPrint(
        &path_buffer,
        "/tmp/costbar-opencode-cache-version-{d}.json",
        .{std.c.getpid()},
    );
    defer std.Io.Dir.deleteFileAbsolute(io, cache_file) catch {};

    const document = try std.json.Stringify.valueAlloc(allocator, CachedQuery{
        .version = cache_version + 1,
        .fingerprint = .{ .period_start_unix = 10, .period_end_exclusive_unix = 20 },
        .updated_at_unix = 1,
        .payload = "{}",
    }, .{});
    defer allocator.free(document);
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = cache_file, .data = document });

    try std.testing.expectEqual(
        @as(?OwnedCache, null),
        try loadCache(allocator, io, cache_file),
    );
}

test "OpenCode has no database fingerprint without a home directory" {
    try std.testing.expectEqual(
        @as(?[]u8, null),
        try databasePath(std.testing.allocator, ""),
    );
}

test "OpenCode falls back to the last cached answer when the CLI fails" {
    const allocator = std.testing.allocator;
    var io_threaded: std.Io.Threaded = .init(allocator, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home = try std.fmt.bufPrint(
        &home_buffer,
        "/tmp/costbar-opencode-fallback-{d}",
        .{std.c.getpid()},
    );
    std.Io.Dir.deleteTree(.cwd(), io, home) catch {};
    defer std.Io.Dir.deleteTree(.cwd(), io, home) catch {};

    // A CLI that exists and fails, so the candidate search stops here instead
    // of finding a real installation.
    var executable_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable = try std.fmt.bufPrint(
        &executable_buffer,
        "{s}/.opencode/bin/opencode",
        .{home},
    );
    try std.Io.Dir.createDirPath(.cwd(), io, std.fs.path.dirname(executable).?);
    try std.Io.Dir.writeFile(.cwd(), io, .{
        .sub_path = executable,
        .data = "#!/bin/sh\nexit 1\n",
        .flags = .{ .permissions = .fromMode(0o700) },
    });

    const database = (try databasePath(allocator, home)).?;
    defer allocator.free(database);
    try std.Io.Dir.createDirPath(.cwd(), io, std.fs.path.dirname(database).?);
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = database, .data = "sqlite" });

    const period = model.Period{ .start_unix = 10, .end_exclusive_unix = 20 };
    var provider = OpenCode.init();
    defer provider.deinit();

    // Without a cache there is nothing to fall back to.
    try std.testing.expectError(
        error.OpenCodeQueryFailed,
        provider.refresh(allocator, io, home, period, 900),
    );

    const cache_file = (try cachePath(allocator, io, home, database)).?;
    defer allocator.free(cache_file);
    const payload = try wrappedPayload(
        allocator,
        period,
        \\[{"provider":"openrouter","model":"grok","cost":2.50}]
    );
    defer allocator.free(payload);
    // Fingerprint from an older database state, so the fresh path cannot use it.
    try storeCache(allocator, io, cache_file, .{
        .database_size = 1,
        .period_start_unix = period.start_unix,
        .period_end_exclusive_unix = period.end_exclusive_unix,
    }, 500, payload);

    try provider.refresh(allocator, io, home, period, 900);
    const report = try provider.collect(allocator, period);
    defer report.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 2_500_000), report.summary.current_cost_micros);
    // Dated when the answer was taken, not when the failed refresh ran.
    try std.testing.expectEqual(@as(i64, 500), report.summary.updated_at_unix);

    // A cache for another period is not a substitute.
    try std.testing.expectError(error.OpenCodeQueryFailed, provider.refresh(
        allocator,
        io,
        home,
        .{ .start_unix = 20, .end_exclusive_unix = 30 },
        900,
    ));
}
