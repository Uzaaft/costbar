const std = @import("std");
const model = @import("model.zig");
const simd_index = @import("simd/index_of.zig");

pub const Kind = enum {
    codex,
    claude,
};

pub const Tokens = struct {
    input: u64 = 0,
    output: u64 = 0,
    cache_read: u64 = 0,
    cache_creation: u64 = 0,
    reasoning: u64 = 0,

    pub fn add(self: *Tokens, other: Tokens) void {
        self.input +|= other.input;
        self.output +|= other.output;
        self.cache_read +|= other.cache_read;
        self.cache_creation +|= other.cache_creation;
        self.reasoning +|= other.reasoning;
    }

    fn subtract(self: Tokens, earlier: Tokens) Tokens {
        return .{
            .input = self.input -| earlier.input,
            .output = self.output -| earlier.output,
            .cache_read = self.cache_read -| earlier.cache_read,
            .cache_creation = self.cache_creation -| earlier.cache_creation,
            .reasoning = self.reasoning -| earlier.reasoning,
        };
    }
};

pub const Window = struct {
    used_percent: f64,
    resets_at_unix: ?i64 = null,
    duration_minutes: ?i64 = null,
};

pub const Limits = struct {
    timestamp: i64,
    primary: ?Window = null,
    secondary: ?Window = null,
};

pub const Aggregate = struct {
    arena: std.heap.ArenaAllocator,
    tokens: Tokens = .{},
    has_tokens: bool = false,
    models: []const []const u8 = &.{},
    limits: ?Limits = null,

    pub fn deinit(self: *Aggregate) void {
        self.arena.deinit();
    }
};

const UsageSample = struct {
    timestamp: i64,
    tokens: Tokens,
    model_name: ?[]const u8 = null,
    dedupe_key: ?DedupeKey = null,
};

const CachedScan = struct {
    arena: std.heap.ArenaAllocator,
    samples: []const UsageSample = &.{},
    limits: ?Limits = null,

    fn deinit(self: *CachedScan) void {
        self.arena.deinit();
    }
};

const persistent_cache_version: u32 = 1;
const max_persistent_cache_bytes = 512 * 1024 * 1024;

const PersistentCache = struct {
    version: u32,
    source_key: [std.crypto.hash.sha2.Sha256.digest_length]u8,
    source_size: u64,
    source_mtime_nanoseconds: i96,
    samples: []const UsageSample,
    limits: ?Limits = null,
};

/// A compile-time local-log collector. An adapter owns only schema-specific
/// parsing; traversal, file caching, period filtering, model aggregation, and
/// duplicate handling are shared here.
pub fn Collector(comptime Adapter: type) type {
    return struct {
        const Self = @This();

        const Entry = struct {
            size: u64,
            mtime_nanoseconds: i96,
            seen_generation: u64,
            scan: CachedScan,

            fn deinit(self: *Entry) void {
                self.scan.deinit();
            }
        };

        allocator: std.mem.Allocator,
        generation: u64 = 0,
        entries: std.StringHashMapUnmanaged(Entry) = .empty,
        persistent_cache_hits: usize = 0,
        source_scans: usize = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            var iterator = self.entries.iterator();
            while (iterator.next()) |item| {
                self.allocator.free(item.key_ptr.*);
                item.value_ptr.deinit();
            }
            self.entries.deinit(self.allocator);
        }

        pub fn collectDefaultRoots(
            self: *Self,
            io: std.Io,
            home: []const u8,
            period: model.Period,
        ) !Aggregate {
            try self.refreshDefaultRoots(io, home, period);
            return self.aggregatePeriod(period);
        }

        pub fn refreshDefaultRoots(
            self: *Self,
            io: std.Io,
            home: []const u8,
            discovery_period: model.Period,
        ) !void {
            var roots: [Adapter.relative_roots.len][]u8 = undefined;
            var root_count: usize = 0;
            defer for (roots[0..root_count]) |root| self.allocator.free(root);
            inline for (Adapter.relative_roots) |relative| {
                roots[root_count] = try std.fs.path.join(self.allocator, &.{ home, relative });
                root_count += 1;
            }
            const cache_directory = try std.fs.path.join(self.allocator, &.{
                home,
                "Library/Caches/Costbar/local-usage",
                Adapter.cache_namespace,
            });
            defer self.allocator.free(cache_directory);
            try self.refreshRootsWithCache(
                io,
                roots[0..root_count],
                discovery_period,
                cache_directory,
            );
        }

        pub fn refreshRoots(
            self: *Self,
            io: std.Io,
            roots: []const []const u8,
            discovery_period: model.Period,
        ) !void {
            try self.refreshRootsImpl(io, roots, discovery_period, null);
        }

        /// Refreshes arbitrary roots with the same persistent cache used by the
        /// default roots. This keeps custom adapters and tests on the generic
        /// collector path without teaching the collector their schemas.
        pub fn refreshRootsWithCache(
            self: *Self,
            io: std.Io,
            roots: []const []const u8,
            discovery_period: model.Period,
            cache_directory: []const u8,
        ) !void {
            const status = std.Io.Dir.createDirPathStatus(
                .cwd(),
                io,
                cache_directory,
                .fromMode(0o700),
            ) catch null;
            try self.refreshRootsImpl(
                io,
                roots,
                discovery_period,
                if (status != null) cache_directory else null,
            );
        }

        fn refreshRootsImpl(
            self: *Self,
            io: std.Io,
            roots: []const []const u8,
            discovery_period: model.Period,
            cache_directory: ?[]const u8,
        ) !void {
            try discovery_period.validate();
            self.generation +%= 1;
            if (self.generation == 0) self.generation = 1;

            for (roots) |root_path| {
                var root = std.Io.Dir.openDirAbsolute(io, root_path, .{
                    .iterate = true,
                    .follow_symlinks = false,
                }) catch continue;
                defer root.close(io);
                var walker = try root.walk(self.allocator);
                defer walker.deinit();
                while (try walker.next(io)) |walk_entry| {
                    if (walk_entry.kind != .file or
                        !std.mem.endsWith(u8, walk_entry.basename, ".jsonl"))
                    {
                        continue;
                    }
                    const stat = walk_entry.dir.statFile(io, walk_entry.basename, .{}) catch continue;
                    if (@divFloor(stat.mtime.nanoseconds, std.time.ns_per_s) <
                        discovery_period.start_unix)
                    {
                        continue;
                    }
                    const path = try std.fs.path.join(
                        self.allocator,
                        &.{ root_path, walk_entry.path },
                    );
                    defer self.allocator.free(path);

                    if (self.entries.getPtr(path)) |cached| {
                        if (cached.size == stat.size and
                            cached.mtime_nanoseconds == stat.mtime.nanoseconds)
                        {
                            cached.seen_generation = self.generation;
                            continue;
                        }
                    }

                    var maybe_scan: ?CachedScan = null;
                    if (cache_directory) |directory| {
                        maybe_scan = loadPersistentCache(
                            self.allocator,
                            io,
                            directory,
                            path,
                            stat.size,
                            stat.mtime.nanoseconds,
                        ) catch null;
                        if (maybe_scan != null) self.persistent_cache_hits +|= 1;
                    }
                    if (maybe_scan == null) {
                        const bytes = walk_entry.dir.readFileAlloc(
                            io,
                            walk_entry.basename,
                            self.allocator,
                            .limited(2 * 1024 * 1024 * 1024),
                        ) catch continue;
                        defer self.allocator.free(bytes);
                        maybe_scan = try scanHistory(Adapter, self.allocator, bytes);
                        self.source_scans +|= 1;
                        if (cache_directory) |directory| {
                            writePersistentCache(
                                self.allocator,
                                io,
                                directory,
                                path,
                                stat.size,
                                stat.mtime.nanoseconds,
                                maybe_scan.?,
                            ) catch {};
                        }
                    }
                    var scan = maybe_scan.?;
                    errdefer scan.deinit();

                    if (self.entries.getPtr(path)) |cached| {
                        cached.deinit();
                        cached.* = .{
                            .size = stat.size,
                            .mtime_nanoseconds = stat.mtime.nanoseconds,
                            .seen_generation = self.generation,
                            .scan = scan,
                        };
                        continue;
                    }

                    const owned_path = try self.allocator.dupe(u8, path);
                    errdefer self.allocator.free(owned_path);
                    try self.entries.put(self.allocator, owned_path, .{
                        .size = stat.size,
                        .mtime_nanoseconds = stat.mtime.nanoseconds,
                        .seen_generation = self.generation,
                        .scan = scan,
                    });
                }
            }
        }

        pub fn aggregatePeriod(self: *Self, period: model.Period) !Aggregate {
            try period.validate();
            var result = Aggregate{ .arena = .init(self.allocator) };
            errdefer result.deinit();
            const arena = result.arena.allocator();
            var models: std.ArrayList([]const u8) = .empty;
            var deduped: std.HashMapUnmanaged(
                DedupeKey,
                UsageSample,
                DedupeContext,
                80,
            ) = .empty;
            var iterator = self.entries.iterator();
            while (iterator.next()) |item| {
                const entry = item.value_ptr;
                if (entry.seen_generation != self.generation) continue;
                for (entry.scan.samples) |sample| {
                    if (sample.dedupe_key) |key| {
                        try putLatestSample(arena, &deduped, key, sample);
                        continue;
                    }
                    if (!contains(period, sample.timestamp)) continue;
                    result.tokens.add(sample.tokens);
                    result.has_tokens = true;
                    if (sample.model_name) |name| {
                        try appendUniqueModel(arena, &models, name);
                    }
                }
                if (entry.scan.limits) |limits| {
                    if (result.limits == null or limits.timestamp >= result.limits.?.timestamp) {
                        result.limits = limits;
                    }
                }
            }
            var deduped_iterator = deduped.valueIterator();
            while (deduped_iterator.next()) |sample| {
                if (!contains(period, sample.timestamp)) continue;
                result.tokens.add(sample.tokens);
                result.has_tokens = true;
                if (sample.model_name) |name| {
                    try appendUniqueModel(arena, &models, name);
                }
            }
            result.models = try models.toOwnedSlice(arena);
            return result;
        }
    };
}

fn loadPersistentCache(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_directory: []const u8,
    source_path: []const u8,
    source_size: u64,
    source_mtime_nanoseconds: i96,
) !?CachedScan {
    const cache_path = try persistentCachePath(allocator, cache_directory, source_path);
    defer allocator.free(cache_path);
    const bytes = try std.Io.Dir.readFileAlloc(
        .cwd(),
        io,
        cache_path,
        allocator,
        .limited(max_persistent_cache_bytes),
    );
    defer allocator.free(bytes);

    var result = CachedScan{ .arena = .init(allocator) };
    errdefer result.deinit();
    const persisted = std.json.parseFromSliceLeaky(
        PersistentCache,
        result.arena.allocator(),
        bytes,
        .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        },
    ) catch return error.InvalidPersistentCache;
    const expected_source_key = hashBytes(source_path);
    if (persisted.version != persistent_cache_version or
        !std.mem.eql(u8, &persisted.source_key, &expected_source_key) or
        persisted.source_size != source_size or
        persisted.source_mtime_nanoseconds != source_mtime_nanoseconds)
    {
        result.deinit();
        return null;
    }
    try validatePersistentCache(persisted);
    result.samples = persisted.samples;
    result.limits = persisted.limits;
    return result;
}

fn writePersistentCache(
    allocator: std.mem.Allocator,
    io: std.Io,
    cache_directory: []const u8,
    source_path: []const u8,
    source_size: u64,
    source_mtime_nanoseconds: i96,
    scan: CachedScan,
) !void {
    const cache_path = try persistentCachePath(allocator, cache_directory, source_path);
    defer allocator.free(cache_path);
    const bytes = try std.json.Stringify.valueAlloc(allocator, PersistentCache{
        .version = persistent_cache_version,
        .source_key = hashBytes(source_path),
        .source_size = source_size,
        .source_mtime_nanoseconds = source_mtime_nanoseconds,
        .samples = scan.samples,
        .limits = scan.limits,
    }, .{});
    defer allocator.free(bytes);

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

fn persistentCachePath(
    allocator: std.mem.Allocator,
    cache_directory: []const u8,
    source_path: []const u8,
) ![]u8 {
    const encoded = std.fmt.bytesToHex(hashBytes(source_path), .lower);
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{encoded});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ cache_directory, filename });
}

fn validatePersistentCache(cache: PersistentCache) !void {
    if (cache.samples.len > 20_000_000) return error.InvalidPersistentCache;
    for (cache.samples) |sample| {
        if (sample.model_name) |name| {
            if (name.len > 1024) return error.InvalidPersistentCache;
        }
    }
    if (cache.limits) |limits| {
        try validateCachedWindow(limits.primary);
        try validateCachedWindow(limits.secondary);
    }
}

fn validateCachedWindow(maybe_window: ?Window) !void {
    const window = maybe_window orelse return;
    if (!std.math.isFinite(window.used_percent) or
        window.used_percent < 0 or window.used_percent > 100)
    {
        return error.InvalidPersistentCache;
    }
    if (window.duration_minutes) |duration| {
        if (duration <= 0) return error.InvalidPersistentCache;
    }
}

fn hashBytes(bytes: []const u8) [std.crypto.hash.sha2.Sha256.digest_length]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

fn hashPair(primary: []const u8, secondary: []const u8) DedupeKey {
    const primary_hash = hashBytes(primary);
    const secondary_hash = hashBytes(secondary);
    var pair: [primary_hash.len + secondary_hash.len]u8 = undefined;
    @memcpy(pair[0..primary_hash.len], &primary_hash);
    @memcpy(pair[primary_hash.len..], &secondary_hash);
    return hashBytes(&pair);
}

pub fn readClaudeStatusLimits(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
) !?Limits {
    const RawStatusWindow = struct {
        used_percentage: ?f64 = null,
        resets_at: ?i64 = null,
    };
    const Status = struct {
        rate_limits: ?struct {
            five_hour: ?RawStatusWindow = null,
            seven_day: ?RawStatusWindow = null,
        } = null,
    };
    const path = try std.fs.path.join(
        allocator,
        &.{ home, "Library/Application Support/Costbar/claude-status.json" },
    );
    defer allocator.free(path);
    const bytes = std.Io.Dir.readFileAlloc(
        .cwd(),
        io,
        path,
        allocator,
        .limited(1024 * 1024),
    ) catch return null;
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(Status, allocator, bytes, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    const raw = parsed.value.rate_limits orelse return null;
    const primary = statusWindow(raw.five_hour, 300);
    const secondary = statusWindow(raw.seven_day, 10_080);
    if (primary == null and secondary == null) return null;
    return .{
        .timestamp = 0,
        .primary = primary,
        .secondary = secondary,
    };
}

fn statusWindow(raw: anytype, duration_minutes: i64) ?Window {
    const value = raw orelse return null;
    const used = value.used_percentage orelse return null;
    if (!std.math.isFinite(used)) return null;
    return .{
        .used_percent = @min(@max(used, 0), 100),
        .resets_at_unix = value.resets_at,
        .duration_minutes = duration_minutes,
    };
}

const RawTokens = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cached_input_tokens: u64 = 0,
    cache_write_input_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
    reasoning_output_tokens: u64 = 0,
};

const RawWindow = struct {
    used_percent: ?f64 = null,
    usedPercent: ?f64 = null,
    resets_at: ?i64 = null,
    resetsAt: ?i64 = null,
    window_minutes: ?i64 = null,
    windowDurationMins: ?i64 = null,
};

const RawLimits = struct {
    primary: ?RawWindow = null,
    secondary: ?RawWindow = null,
};

const CodexEvent = struct {
    timestamp: ?std.json.Value = null,
    payload: ?struct {
        type: ?[]const u8 = null,
        model: ?[]const u8 = null,
        info: ?struct {
            total_token_usage: ?RawTokens = null,
            last_token_usage: ?RawTokens = null,
        } = null,
        rate_limits: ?RawLimits = null,
    } = null,
};

const ClaudeEvent = struct {
    type: ?[]const u8 = null,
    timestamp: ?std.json.Value = null,
    requestId: ?[]const u8 = null,
    message: ?struct {
        id: ?[]const u8 = null,
        model: ?[]const u8 = null,
        usage: ?RawTokens = null,
    } = null,
};

const DedupeKey = [std.crypto.hash.sha2.Sha256.digest_length]u8;

const NormalizedEvent = struct {
    tokens: ?Tokens = null,
    model_name: ?[]const u8 = null,
    limits: ?Limits = null,
    dedupe_key: ?DedupeKey = null,
};

/// Native Codex JSONL schema adapter. Cumulative counters remain a fallback
/// for older logs; current logs provide exact per-turn `last_token_usage`.
pub const CodexLogAdapter = struct {
    pub const relative_roots = .{ ".codex/sessions", ".codex/archived_sessions" };
    pub const cache_namespace = "codex-v1";
    pub const RawEvent = CodexEvent;

    pub const State = struct {
        current_model: ?[]const u8 = null,
        previous_total: ?Tokens = null,
    };

    pub fn initState() State {
        return .{};
    }

    pub fn accepts(line: []const u8) bool {
        return std.mem.indexOf(u8, line, "\"token_count\"") != null or
            std.mem.indexOf(u8, line, "\"model\"") != null or
            std.mem.indexOf(u8, line, "\"rate_limits\"") != null;
    }

    pub fn timestamp(event: RawEvent) ?std.json.Value {
        return event.timestamp;
    }

    pub fn normalize(
        state: *State,
        stable_allocator: std.mem.Allocator,
        event: RawEvent,
        timestamp_unix: i64,
    ) !?NormalizedEvent {
        const payload = event.payload orelse return null;
        if (payload.model) |name| {
            if (name.len > 0 and
                (state.current_model == null or
                    !std.mem.eql(u8, state.current_model.?, name)))
            {
                state.current_model = try stable_allocator.dupe(u8, name);
            }
        }

        const limits = if (payload.rate_limits) |raw|
            parseLimits(timestamp_unix, raw)
        else
            null;
        if (!std.mem.eql(u8, payload.type orelse "", "token_count")) {
            return if (limits != null) .{ .limits = limits } else null;
        }

        const info = payload.info orelse return if (limits != null)
            .{ .limits = limits }
        else
            null;
        const total = if (info.total_token_usage) |raw| codexTokens(raw) else null;
        defer {
            if (total) |value| state.previous_total = value;
        }
        const tokens = if (info.last_token_usage) |raw|
            codexTokens(raw)
        else if (total) |value|
            if (state.previous_total) |previous| value.subtract(previous) else value
        else
            return if (limits != null) .{ .limits = limits } else null;

        return .{
            .tokens = tokens,
            .model_name = state.current_model,
            .limits = limits,
        };
    }
};

/// Native Claude JSONL schema adapter. Duplicate streaming snapshots share a
/// message/request identity; the generic scanner keeps only the final one.
pub const ClaudeLogAdapter = struct {
    pub const relative_roots = .{".claude/projects"};
    pub const cache_namespace = "claude-v1";
    pub const RawEvent = ClaudeEvent;
    pub const State = struct {};

    pub fn initState() State {
        return .{};
    }

    pub fn accepts(line: []const u8) bool {
        return std.mem.indexOf(u8, line, "\"assistant\"") != null;
    }

    pub fn timestamp(event: RawEvent) ?std.json.Value {
        return event.timestamp;
    }

    pub fn normalize(
        _: *State,
        _: std.mem.Allocator,
        event: RawEvent,
        _: i64,
    ) !?NormalizedEvent {
        if (!std.mem.eql(u8, event.type orelse "", "assistant")) return null;
        const message = event.message orelse return null;
        const usage = message.usage orelse return null;
        const dedupe_key: ?DedupeKey = if (message.id != null and event.requestId != null)
            hashPair(message.id.?, event.requestId.?)
        else
            null;
        return .{
            .tokens = .{
                .input = usage.input_tokens,
                .output = usage.output_tokens,
                .cache_read = usage.cache_read_input_tokens,
                .cache_creation = usage.cache_creation_input_tokens,
            },
            .model_name = message.model,
            .dedupe_key = dedupe_key,
        };
    }
};

/// Iterates JSONL without allocating an array of line ranges. Newline searches
/// use the Ghostty-inspired pure-Zig SIMD index primitive.
pub const LineIterator = struct {
    bytes: []const u8,
    cursor: usize = 0,

    pub fn next(self: *LineIterator) ?[]const u8 {
        while (self.cursor < self.bytes.len) {
            const start = self.cursor;
            const remaining = self.bytes[start..];
            const relative_end = simd_index.indexOf(remaining, '\n') orelse remaining.len;
            const end = start + relative_end;
            self.cursor = end + @intFromBool(end < self.bytes.len);
            if (end != start) return self.bytes[start..end];
        }
        return null;
    }
};

pub fn scanFile(
    allocator: std.mem.Allocator,
    kind: Kind,
    bytes: []const u8,
    period: model.Period,
) !Aggregate {
    try period.validate();
    var history = switch (kind) {
        .codex => try scanHistory(CodexLogAdapter, allocator, bytes),
        .claude => try scanHistory(ClaudeLogAdapter, allocator, bytes),
    };
    defer history.deinit();
    return aggregateCachedScan(allocator, history, period);
}

const DedupeContext = struct {
    pub fn hash(_: DedupeContext, key: DedupeKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(&key);
        return hasher.final();
    }

    pub fn eql(_: DedupeContext, left: DedupeKey, right: DedupeKey) bool {
        return std.mem.eql(u8, &left, &right);
    }
};

fn scanHistory(
    comptime Adapter: type,
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !CachedScan {
    var result = CachedScan{ .arena = .init(allocator) };
    errdefer result.deinit();
    const arena = result.arena.allocator();
    var samples: std.ArrayList(UsageSample) = .empty;
    var state = Adapter.initState();

    var parse_arena: std.heap.ArenaAllocator = .init(allocator);
    defer parse_arena.deinit();
    var lines = LineIterator{ .bytes = bytes };
    while (lines.next()) |line| {
        if (!Adapter.accepts(line)) continue;
        _ = parse_arena.reset(.retain_capacity);
        const event = std.json.parseFromSliceLeaky(
            Adapter.RawEvent,
            parse_arena.allocator(),
            line,
            .{ .ignore_unknown_fields = true },
        ) catch continue;
        const timestamp = parseTimestamp(Adapter.timestamp(event) orelse continue) catch continue;
        const normalized = try Adapter.normalize(&state, arena, event, timestamp) orelse continue;
        if (normalized.limits) |limits| {
            if ((limits.primary != null or limits.secondary != null) and
                (result.limits == null or limits.timestamp >= result.limits.?.timestamp))
            {
                result.limits = limits;
            }
        }
        const tokens = normalized.tokens orelse continue;
        const sample = UsageSample{
            .timestamp = timestamp,
            .tokens = tokens,
            .model_name = if (normalized.model_name) |name|
                try arena.dupe(u8, name)
            else
                null,
            .dedupe_key = normalized.dedupe_key,
        };
        try samples.append(arena, sample);
    }
    result.samples = try samples.toOwnedSlice(arena);
    return result;
}

fn aggregateCachedScan(
    allocator: std.mem.Allocator,
    scan: CachedScan,
    period: model.Period,
) !Aggregate {
    var result = Aggregate{ .arena = .init(allocator) };
    errdefer result.deinit();
    const arena = result.arena.allocator();
    var models: std.ArrayList([]const u8) = .empty;
    var deduped: std.HashMapUnmanaged(DedupeKey, UsageSample, DedupeContext, 80) = .empty;
    for (scan.samples) |sample| {
        if (sample.dedupe_key) |key| {
            try putLatestSample(arena, &deduped, key, sample);
            continue;
        }
        if (!contains(period, sample.timestamp)) continue;
        result.tokens.add(sample.tokens);
        result.has_tokens = true;
        if (sample.model_name) |name| try appendUniqueModel(arena, &models, name);
    }
    var deduped_iterator = deduped.valueIterator();
    while (deduped_iterator.next()) |sample| {
        if (!contains(period, sample.timestamp)) continue;
        result.tokens.add(sample.tokens);
        result.has_tokens = true;
        if (sample.model_name) |name| try appendUniqueModel(arena, &models, name);
    }
    result.models = try models.toOwnedSlice(arena);
    result.limits = scan.limits;
    return result;
}

fn putLatestSample(
    allocator: std.mem.Allocator,
    deduped: *std.HashMapUnmanaged(DedupeKey, UsageSample, DedupeContext, 80),
    key: DedupeKey,
    sample: UsageSample,
) !void {
    if (deduped.getPtr(key)) |existing| {
        if (sample.timestamp >= existing.timestamp) existing.* = sample;
        return;
    }
    try deduped.put(allocator, key, sample);
}

fn appendUniqueModel(
    allocator: std.mem.Allocator,
    models: *std.ArrayList([]const u8),
    name: []const u8,
) !void {
    if (name.len == 0) return;
    for (models.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try models.append(allocator, try allocator.dupe(u8, name));
}

fn codexTokens(raw: RawTokens) Tokens {
    return .{
        .input = raw.input_tokens -| raw.cached_input_tokens -| raw.cache_write_input_tokens,
        .output = raw.output_tokens -| raw.reasoning_output_tokens,
        .cache_read = raw.cached_input_tokens,
        .cache_creation = raw.cache_write_input_tokens,
        .reasoning = raw.reasoning_output_tokens,
    };
}

fn parseLimits(timestamp: i64, raw: RawLimits) Limits {
    return .{
        .timestamp = timestamp,
        .primary = if (raw.primary) |window| parseWindow(window) else null,
        .secondary = if (raw.secondary) |window| parseWindow(window) else null,
    };
}

fn parseWindow(raw: RawWindow) ?Window {
    const used = raw.used_percent orelse raw.usedPercent orelse return null;
    if (!std.math.isFinite(used)) return null;
    return .{
        .used_percent = std.math.clamp(used, 0, 100),
        .resets_at_unix = raw.resets_at orelse raw.resetsAt,
        .duration_minutes = raw.window_minutes orelse raw.windowDurationMins,
    };
}

fn contains(period: model.Period, timestamp: i64) bool {
    return timestamp >= period.start_unix and timestamp < period.end_exclusive_unix;
}

fn parseTimestamp(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |number| number,
        .string => |text| parseIso8601(text),
        else => error.InvalidTimestamp,
    };
}

fn parseIso8601(text: []const u8) !i64 {
    if (text.len < 20 or text[4] != '-' or text[7] != '-' or
        (text[10] != 'T' and text[10] != 't') or text[13] != ':' or text[16] != ':')
    {
        return error.InvalidTimestamp;
    }
    const year = try digits(text[0..4]);
    const month = try digits(text[5..7]);
    const day = try digits(text[8..10]);
    const hour = try digits(text[11..13]);
    const minute = try digits(text[14..16]);
    const second = try digits(text[17..19]);
    if (month < 1 or month > 12 or day < 1 or day > 31 or
        hour > 23 or minute > 59 or second > 60)
    {
        return error.InvalidTimestamp;
    }

    var zone_index: usize = 19;
    if (zone_index < text.len and text[zone_index] == '.') {
        zone_index += 1;
        const fraction_start = zone_index;
        while (zone_index < text.len and std.ascii.isDigit(text[zone_index])) zone_index += 1;
        if (zone_index == fraction_start) return error.InvalidTimestamp;
    }

    var offset_seconds: i64 = 0;
    if (zone_index >= text.len) return error.InvalidTimestamp;
    switch (text[zone_index]) {
        'Z', 'z' => if (zone_index + 1 != text.len) return error.InvalidTimestamp,
        '+', '-' => {
            if (zone_index + 6 != text.len or text[zone_index + 3] != ':') {
                return error.InvalidTimestamp;
            }
            const zone_hours = try digits(text[zone_index + 1 .. zone_index + 3]);
            const zone_minutes = try digits(text[zone_index + 4 .. zone_index + 6]);
            if (zone_hours > 23 or zone_minutes > 59) return error.InvalidTimestamp;
            const absolute: i64 = @intCast(zone_hours * 3600 + zone_minutes * 60);
            offset_seconds = if (text[zone_index] == '+') absolute else -absolute;
        },
        else => return error.InvalidTimestamp,
    }

    const days = daysFromCivil(
        @as(i64, @intCast(year)),
        @as(i64, @intCast(month)),
        @as(i64, @intCast(day)),
    );
    return days * 86_400 +
        @as(i64, @intCast(hour * 3600 + minute * 60 + second)) -
        offset_seconds;
}

fn digits(text: []const u8) !u64 {
    if (text.len == 0) return error.InvalidTimestamp;
    var value: u64 = 0;
    for (text) |character| {
        if (!std.ascii.isDigit(character)) return error.InvalidTimestamp;
        value = value * 10 + character - '0';
    }
    return value;
}

/// Howard Hinnant's civil-date conversion, returning days since 1970-01-01.
fn daysFromCivil(input_year: i64, month: i64, day: i64) i64 {
    const year = input_year - @intFromBool(month <= 2);
    const era = @divFloor(year, 400);
    const year_of_era = year - era * 400;
    const shifted_month = month + (if (month > 2) @as(i64, -3) else 9);
    const day_of_year = @divFloor(153 * shifted_month + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divFloor(year_of_era, 4) -
        @divFloor(year_of_era, 100) + day_of_year;
    return era * 146_097 + day_of_era - 719_468;
}

test "SIMD line iterator matches scalar splitting at every alignment" {
    var storage: [160]u8 = undefined;
    for (0..64) |newline_offset| {
        @memset(&storage, 'a');
        storage[newline_offset] = '\n';
        storage[79] = '\n';
        storage[80] = '\n';

        var iterator = LineIterator{ .bytes = &storage };
        var expected = std.mem.splitScalar(u8, &storage, '\n');
        while (true) {
            var expected_line: ?[]const u8 = null;
            while (expected.next()) |line| {
                if (line.len != 0) {
                    expected_line = line;
                    break;
                }
            }
            const actual = iterator.next();
            try std.testing.expectEqual(expected_line == null, actual == null);
            if (expected_line == null) break;
            try std.testing.expectEqualStrings(expected_line.?, actual.?);
        }
    }
}

test "Codex JSONL scan keeps the final cumulative count per file" {
    const jsonl =
        \\{"timestamp":"2026-08-10T12:00:00.123Z","payload":{"model":"gpt-codex"}}
        \\{"timestamp":"2026-08-10T12:01:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30,"reasoning_output_tokens":5}}}}
        \\{"timestamp":"2026-08-10T12:02:00+00:00","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":200,"cached_input_tokens":50,"output_tokens":60,"reasoning_output_tokens":10}}}}
        \\{"timestamp":"2026-07-10T12:00:00Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":999}}}}
    ;
    var scan = try scanFile(std.testing.allocator, .codex, jsonl, .{
        .start_unix = 1_785_542_400,
        .end_exclusive_unix = 1_788_220_800,
    });
    defer scan.deinit();
    try std.testing.expect(scan.has_tokens);
    try std.testing.expectEqual(@as(u64, 150), scan.tokens.input);
    try std.testing.expectEqual(@as(u64, 50), scan.tokens.output);
    try std.testing.expectEqual(@as(u64, 50), scan.tokens.cache_read);
    try std.testing.expectEqual(@as(u64, 10), scan.tokens.reasoning);
    try std.testing.expectEqual(@as(usize, 1), scan.models.len);
}

test "Codex JSONL scan uses exact per-turn usage at a period boundary" {
    const jsonl =
        \\{"timestamp":"2026-08-10T11:59:00Z","payload":{"model":"gpt-codex"}}
        \\{"timestamp":"2026-08-10T11:59:30Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":30}}}}
        \\{"timestamp":"2026-08-10T12:00:30Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"cached_input_tokens":40,"output_tokens":40},"last_token_usage":{"input_tokens":50,"cached_input_tokens":20,"output_tokens":10}}}}
    ;
    var scan = try scanFile(std.testing.allocator, .codex, jsonl, .{
        .start_unix = 1_786_363_200,
        .end_exclusive_unix = 1_786_366_800,
    });
    defer scan.deinit();
    try std.testing.expectEqual(@as(u64, 30), scan.tokens.input);
    try std.testing.expectEqual(@as(u64, 10), scan.tokens.output);
    try std.testing.expectEqual(@as(u64, 20), scan.tokens.cache_read);
}

test "one cached history can aggregate multiple periods" {
    const jsonl =
        \\{"timestamp":"2026-08-10T11:59:00Z","payload":{"model":"gpt-codex"}}
        \\{"timestamp":"2026-08-10T11:59:30Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20},"last_token_usage":{"input_tokens":100,"output_tokens":20}}}}
        \\{"timestamp":"2026-08-10T12:00:30Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":150,"output_tokens":30},"last_token_usage":{"input_tokens":50,"output_tokens":10}}}}
    ;
    var history = try scanHistory(CodexLogAdapter, std.testing.allocator, jsonl);
    defer history.deinit();

    var before = try aggregateCachedScan(std.testing.allocator, history, .{
        .start_unix = 1_786_359_600,
        .end_exclusive_unix = 1_786_363_200,
    });
    defer before.deinit();
    var after = try aggregateCachedScan(std.testing.allocator, history, .{
        .start_unix = 1_786_363_200,
        .end_exclusive_unix = 1_786_366_800,
    });
    defer after.deinit();

    try std.testing.expectEqual(@as(u64, 120), before.tokens.input + before.tokens.output);
    try std.testing.expectEqual(@as(u64, 60), after.tokens.input + after.tokens.output);
}

test "Claude JSONL scan sums assistant usage only" {
    const jsonl =
        \\{"type":"user","timestamp":"2026-08-10T12:00:00Z","message":{"usage":{"input_tokens":999}}}
        \\{"type":"assistant","timestamp":"2026-08-10T12:01:00Z","message":{"model":"claude-opus","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":3,"cache_creation_input_tokens":2}}}
        \\{"type":"assistant","timestamp":"2026-08-10T12:02:00Z","message":{"model":"claude-opus","usage":{"input_tokens":20,"output_tokens":7}}}
    ;
    var scan = try scanFile(std.testing.allocator, .claude, jsonl, .{
        .start_unix = 1_785_542_400,
        .end_exclusive_unix = 1_788_220_800,
    });
    defer scan.deinit();
    try std.testing.expectEqual(@as(u64, 30), scan.tokens.input);
    try std.testing.expectEqual(@as(u64, 12), scan.tokens.output);
    try std.testing.expectEqual(@as(u64, 3), scan.tokens.cache_read);
    try std.testing.expectEqual(@as(u64, 2), scan.tokens.cache_creation);
}

test "Claude JSONL scan keeps the final streaming snapshot per message request" {
    const jsonl =
        \\{"type":"assistant","timestamp":"2026-08-10T12:01:00Z","requestId":"request-1","message":{"id":"message-1","model":"claude-opus","usage":{"input_tokens":10,"output_tokens":5}}}
        \\{"type":"assistant","timestamp":"2026-08-10T12:01:05Z","requestId":"request-1","message":{"id":"message-1","model":"claude-opus","usage":{"input_tokens":10,"output_tokens":8}}}
        \\{"type":"assistant","timestamp":"2026-08-10T12:02:00Z","requestId":"request-2","message":{"id":"message-2","model":"claude-opus","usage":{"input_tokens":20,"output_tokens":7}}}
    ;
    var scan = try scanFile(std.testing.allocator, .claude, jsonl, .{
        .start_unix = 1_785_542_400,
        .end_exclusive_unix = 1_788_220_800,
    });
    defer scan.deinit();
    try std.testing.expectEqual(@as(u64, 30), scan.tokens.input);
    try std.testing.expectEqual(@as(u64, 15), scan.tokens.output);
}

test "persistent collector cache survives recreation and recovers from stale or corrupt data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home_length = try tmp.dir.realPath(std.testing.io, &home_buffer);
    const home = home_buffer[0..home_length];

    const sessions_directory = try std.fs.path.join(
        std.testing.allocator,
        &.{ home, ".codex/sessions" },
    );
    defer std.testing.allocator.free(sessions_directory);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, sessions_directory);
    const source_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ sessions_directory, "session.jsonl" },
    );
    defer std.testing.allocator.free(source_path);

    const initial_jsonl =
        \\{"timestamp":"2026-08-24T12:00:00Z","payload":{"model":"gpt-5.6-sol"}}
        \\{"timestamp":"2026-08-24T12:00:01Z","payload":{"type":"response_item","content":"private prompt and response"}}
        \\{"timestamp":"2026-08-24T12:01:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"output_tokens":10}}}}
    ;
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = source_path,
        .data = initial_jsonl,
    });
    const period = model.Period{
        .start_unix = 0,
        .end_exclusive_unix = std.math.maxInt(i64),
    };

    const CodexCollector = Collector(CodexLogAdapter);
    var first = CodexCollector.init(std.testing.allocator);
    defer first.deinit();
    try first.refreshDefaultRoots(std.testing.io, home, period);
    try std.testing.expectEqual(@as(usize, 0), first.persistent_cache_hits);
    try std.testing.expectEqual(@as(usize, 1), first.source_scans);
    var first_aggregate = try first.aggregatePeriod(period);
    defer first_aggregate.deinit();
    try std.testing.expectEqual(@as(u64, 50), first_aggregate.tokens.input);

    const cache_directory = try std.fs.path.join(std.testing.allocator, &.{
        home,
        "Library/Caches/Costbar/local-usage",
        CodexLogAdapter.cache_namespace,
    });
    defer std.testing.allocator.free(cache_directory);
    const cache_path = try persistentCachePath(
        std.testing.allocator,
        cache_directory,
        source_path,
    );
    defer std.testing.allocator.free(cache_path);
    const cache_bytes = try std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        cache_path,
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(cache_bytes);
    try std.testing.expect(std.mem.indexOf(u8, cache_bytes, "private prompt") == null);
    try std.testing.expect(std.mem.indexOf(u8, cache_bytes, source_path) == null);

    var second = CodexCollector.init(std.testing.allocator);
    defer second.deinit();
    try second.refreshDefaultRoots(std.testing.io, home, period);
    try std.testing.expectEqual(@as(usize, 1), second.persistent_cache_hits);
    try std.testing.expectEqual(@as(usize, 0), second.source_scans);
    var second_aggregate = try second.aggregatePeriod(period);
    defer second_aggregate.deinit();
    try std.testing.expectEqual(@as(u64, 50), second_aggregate.tokens.input);

    const changed_jsonl = initial_jsonl ++ "\n" ++
        \\{"timestamp":"2026-08-24T12:02:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"output_tokens":5}}}}
    ;
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = source_path,
        .data = changed_jsonl,
    });
    var stale = CodexCollector.init(std.testing.allocator);
    defer stale.deinit();
    try stale.refreshDefaultRoots(std.testing.io, home, period);
    try std.testing.expectEqual(@as(usize, 0), stale.persistent_cache_hits);
    try std.testing.expectEqual(@as(usize, 1), stale.source_scans);
    var stale_aggregate = try stale.aggregatePeriod(period);
    defer stale_aggregate.deinit();
    try std.testing.expectEqual(@as(u64, 70), stale_aggregate.tokens.input);

    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = cache_path,
        .data = "not-json",
    });
    var corrupt = CodexCollector.init(std.testing.allocator);
    defer corrupt.deinit();
    try corrupt.refreshDefaultRoots(std.testing.io, home, period);
    try std.testing.expectEqual(@as(usize, 0), corrupt.persistent_cache_hits);
    try std.testing.expectEqual(@as(usize, 1), corrupt.source_scans);
    var corrupt_aggregate = try corrupt.aggregatePeriod(period);
    defer corrupt_aggregate.deinit();
    try std.testing.expectEqual(@as(u64, 70), corrupt_aggregate.tokens.input);
}

test "persistent Claude cache preserves hashed streaming deduplication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var home_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home_length = try tmp.dir.realPath(std.testing.io, &home_buffer);
    const home = home_buffer[0..home_length];

    const projects_directory = try std.fs.path.join(
        std.testing.allocator,
        &.{ home, ".claude/projects/project" },
    );
    defer std.testing.allocator.free(projects_directory);
    try std.Io.Dir.createDirPath(.cwd(), std.testing.io, projects_directory);
    const source_path = try std.fs.path.join(
        std.testing.allocator,
        &.{ projects_directory, "session.jsonl" },
    );
    defer std.testing.allocator.free(source_path);
    const jsonl =
        \\{"type":"assistant","timestamp":"2026-08-24T12:01:00Z","requestId":"private-request-1","message":{"id":"private-message-1","model":"claude-opus","usage":{"input_tokens":10,"output_tokens":5}}}
        \\{"type":"assistant","timestamp":"2026-08-24T12:01:05Z","requestId":"private-request-1","message":{"id":"private-message-1","model":"claude-opus","usage":{"input_tokens":10,"output_tokens":8}}}
        \\{"type":"assistant","timestamp":"2026-08-24T12:02:00Z","requestId":"private-request-2","message":{"id":"private-message-2","model":"claude-opus","usage":{"input_tokens":20,"output_tokens":7}}}
    ;
    try std.Io.Dir.writeFile(.cwd(), std.testing.io, .{
        .sub_path = source_path,
        .data = jsonl,
    });
    const period = model.Period{
        .start_unix = 0,
        .end_exclusive_unix = std.math.maxInt(i64),
    };

    const ClaudeCollector = Collector(ClaudeLogAdapter);
    var first = ClaudeCollector.init(std.testing.allocator);
    defer first.deinit();
    try first.refreshDefaultRoots(std.testing.io, home, period);

    const cache_directory = try std.fs.path.join(std.testing.allocator, &.{
        home,
        "Library/Caches/Costbar/local-usage",
        ClaudeLogAdapter.cache_namespace,
    });
    defer std.testing.allocator.free(cache_directory);
    const cache_path = try persistentCachePath(
        std.testing.allocator,
        cache_directory,
        source_path,
    );
    defer std.testing.allocator.free(cache_path);
    const cache_bytes = try std.Io.Dir.readFileAlloc(
        .cwd(),
        std.testing.io,
        cache_path,
        std.testing.allocator,
        .limited(1024 * 1024),
    );
    defer std.testing.allocator.free(cache_bytes);
    try std.testing.expect(std.mem.indexOf(u8, cache_bytes, "private-message") == null);
    try std.testing.expect(std.mem.indexOf(u8, cache_bytes, "private-request") == null);

    var restarted = ClaudeCollector.init(std.testing.allocator);
    defer restarted.deinit();
    try restarted.refreshDefaultRoots(std.testing.io, home, period);
    try std.testing.expectEqual(@as(usize, 1), restarted.persistent_cache_hits);
    try std.testing.expectEqual(@as(usize, 0), restarted.source_scans);
    var aggregate = try restarted.aggregatePeriod(period);
    defer aggregate.deinit();
    try std.testing.expectEqual(@as(u64, 30), aggregate.tokens.input);
    try std.testing.expectEqual(@as(u64, 15), aggregate.tokens.output);
}
