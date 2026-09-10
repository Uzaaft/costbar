const std = @import("std");
const model = @import("model.zig");

pub const LivenessFn = *const fn (pid: i32, started_at_unix: ?i64) bool;

const RawRecord = struct {
    pid: ?i64 = null,
    cwd: ?[]const u8 = null,
    status: ?[]const u8 = null,
    tempo: ?[]const u8 = null,
    sessionId: ?[]const u8 = null,
    name: ?[]const u8 = null,
    waitingFor: ?[]const u8 = null,
    needs: ?[]const u8 = null,
    startedAt: ?f64 = null,
    procStart: ?[]const u8 = null,
    statusUpdatedAt: ?f64 = null,
    updatedAt: ?f64 = null,
    entrypoint: ?[]const u8 = null,
};

pub const ParsedRecord = struct {
    pid: i32,
    started_at_unix: ?i64,
    session_id: ?[]const u8,
    cwd: []const u8,
    reports_status: bool,
    session: model.Session,
};

pub fn parseRecord(allocator: std.mem.Allocator, json: []const u8) !?ParsedRecord {
    var parsed = std.json.parseFromSlice(RawRecord, allocator, json, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    const raw = parsed.value;
    const pid_value = raw.pid orelse return null;
    if (pid_value <= 0 or pid_value > std.math.maxInt(i32)) return null;
    const cwd = raw.cwd orelse return null;
    if (cwd.len == 0) return null;
    const pid: i32 = @intCast(pid_value);

    const mapped = mapState(raw.tempo, raw.status);
    const started_at_unix = millisToUnix(raw.startedAt) orelse parseProcStart(raw.procStart);
    const since = millisToUnix(raw.statusUpdatedAt) orelse
        millisToUnix(raw.updatedAt) orelse
        started_at_unix orelse
        0;
    const folder = std.fs.path.basename(cwd);
    const name = if (raw.name) |value| if (value.len > 0) value else folder else folder;
    const id = try std.fmt.allocPrint(allocator, "claude.{d}", .{pid});
    errdefer allocator.free(id);
    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);
    const owned_detail = try std.fmt.allocPrint(
        allocator,
        "{s} · {s}",
        .{ surface(raw.entrypoint), folder },
    );
    errdefer allocator.free(owned_detail);
    const waiting = raw.waitingFor orelse raw.needs;
    const owned_waiting = if (waiting) |value|
        if (value.len > 0) try allocator.dupe(u8, value) else null
    else
        null;
    errdefer if (owned_waiting) |value| allocator.free(value);
    const owned_cwd = try allocator.dupe(u8, cwd);
    errdefer allocator.free(owned_cwd);
    const owned_session_id = if (raw.sessionId) |value|
        if (value.len > 0) try allocator.dupe(u8, value) else null
    else
        null;
    return .{
        .pid = pid,
        .started_at_unix = started_at_unix,
        .session_id = owned_session_id,
        .cwd = owned_cwd,
        .reports_status = mapped.reports_status,
        .session = .{
            .id = id,
            .name = owned_name,
            .detail = owned_detail,
            .state = mapped.state,
            .waiting_for = owned_waiting,
            .since_unix = since,
            .pid = pid,
        },
    };
}

const Mapped = struct {
    state: model.State,
    reports_status: bool,
};

fn mapState(tempo: ?[]const u8, status: ?[]const u8) Mapped {
    if (tempo) |value| {
        if (std.mem.eql(u8, value, "blocked")) return .{ .state = .waiting, .reports_status = true };
        if (std.mem.eql(u8, value, "active")) return .{ .state = .busy, .reports_status = true };
        if (std.mem.eql(u8, value, "idle")) return .{ .state = .idle, .reports_status = true };
    }
    if (status) |value| {
        if (std.mem.eql(u8, value, "waiting")) return .{ .state = .waiting, .reports_status = true };
        if (std.mem.eql(u8, value, "busy")) return .{ .state = .busy, .reports_status = true };
        if (std.mem.eql(u8, value, "idle")) return .{ .state = .idle, .reports_status = true };
    }
    return .{ .state = .idle, .reports_status = false };
}

fn surface(entrypoint: ?[]const u8) []const u8 {
    const value = entrypoint orelse return "Terminal";
    if (std.mem.eql(u8, value, "claude-desktop") or std.mem.eql(u8, value, "claude-desktop-3p"))
        return "Desktop";
    if (std.mem.eql(u8, value, "claude-vscode")) return "VS Code";
    if (std.mem.eql(u8, value, "local-agent")) return "Agent";
    return "Terminal";
}

fn millisToUnix(value: ?f64) ?i64 {
    const millis = value orelse return null;
    if (!std.math.isFinite(millis) or millis <= 0) return null;
    return @intFromFloat(@divTrunc(millis, 1000));
}

pub fn parseProcStart(text: ?[]const u8) ?i64 {
    const raw = text orelse return null;
    var parts: [5][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, raw, ' ');
    while (it.next()) |part| {
        if (count >= parts.len) return null;
        parts[count] = part;
        count += 1;
    }
    if (count != 5) return null;
    const month = monthNumber(parts[1]) orelse return null;
    const day = std.fmt.parseInt(u8, parts[2], 10) catch return null;
    var time = std.mem.splitScalar(u8, parts[3], ':');
    const hour = std.fmt.parseInt(u8, time.next() orelse return null, 10) catch return null;
    const minute = std.fmt.parseInt(u8, time.next() orelse return null, 10) catch return null;
    const second = std.fmt.parseInt(u8, time.next() orelse return null, 10) catch return null;
    const year = std.fmt.parseInt(i32, parts[4], 10) catch return null;
    return utcUnix(year, month, day, hour, minute, second);
}

fn monthNumber(name: []const u8) ?u8 {
    const months = .{
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    };
    inline for (months, 1..) |month, index| {
        if (std.mem.eql(u8, name, month)) return index;
    }
    return null;
}

fn utcUnix(year: i32, month: u8, day: u8, hour: u8, minute: u8, second: u8) i64 {
    const days = daysFromCivil(year, month, day);
    return days * 86_400 +
        @as(i64, hour) * 3_600 +
        @as(i64, minute) * 60 +
        @as(i64, second);
}

fn daysFromCivil(year_value: i32, month: u8, day: u8) i64 {
    var year: i64 = year_value;
    year -= @intFromBool(month <= 2);
    const era = @divFloor(year, 400);
    const yoe = year - era * 400;
    const shifted_month: i64 = if (month > 2) month - 3 else month + 9;
    const doy = @divFloor(153 * shifted_month + 2, 5) + @as(i64, day) - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

pub const Turn = enum { in_flight, finished };

pub fn turnInTail(allocator: std.mem.Allocator, bytes: []const u8) ?Turn {
    var lines = std.mem.splitBackwardsScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{
            .allocate = .alloc_always,
        }) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        if (parsed.value.object.get("isSidechain")) |side| {
            if (side == .bool and side.bool) continue;
        }
        const kind = if (parsed.value.object.get("type")) |value|
            if (value == .string) value.string else continue
        else
            continue;
        if (std.mem.eql(u8, kind, "assistant")) {
            const message = parsed.value.object.get("message") orelse return .finished;
            if (message != .object) return .finished;
            const reason = message.object.get("stop_reason") orelse return .finished;
            if (reason == .string and std.mem.eql(u8, reason.string, "tool_use")) return .in_flight;
            return .finished;
        }
        if (std.mem.eql(u8, kind, "user")) {
            return if (isInterruption(parsed.value)) .finished else .in_flight;
        }
    }
    return null;
}

fn isInterruption(value: std.json.Value) bool {
    const message = value.object.get("message") orelse return false;
    if (message != .object) return false;
    const content = message.object.get("content") orelse return false;
    const prefix = "[Request interrupted by user";
    if (content == .string) return std.mem.startsWith(u8, content.string, prefix);
    if (content != .array) return false;
    for (content.array.items) |block| {
        if (block != .object) continue;
        if (block.object.get("text")) |text| {
            if (text == .string and std.mem.startsWith(u8, text.string, prefix)) return true;
        }
    }
    return false;
}

fn applyTranscript(session: model.Session, turn: Turn) model.Session {
    return .{
        .id = session.id,
        .name = session.name,
        .detail = session.detail,
        .state = if (turn == .in_flight) .busy else .idle,
        .waiting_for = null,
        .since_unix = session.since_unix,
        .pid = session.pid,
    };
}

pub fn scan(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    profile_id: []const u8,
    now_unix: i64,
    is_live: LivenessFn,
) ![]model.Session {
    _ = profile_id;
    _ = now_unix;
    const sessions_dir = try std.fs.path.join(allocator, &.{ home, ".claude", "sessions" });
    defer allocator.free(sessions_dir);
    var dir = std.Io.Dir.openDirAbsolute(io, sessions_dir, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return &.{};
    defer dir.close(io);

    var found: std.ArrayList(model.Session) = .empty;
    errdefer found.deinit(allocator);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".json")) continue;
        const bytes = entry.dir.readFileAlloc(
            io,
            entry.basename,
            allocator,
            .limited(256 * 1024),
        ) catch continue;
        defer allocator.free(bytes);
        const parsed = (parseRecord(allocator, bytes) catch continue) orelse continue;
        if (!is_live(parsed.pid, parsed.started_at_unix)) {
            freeParsed(allocator, parsed);
            continue;
        }
        var session = parsed.session;
        if (!parsed.reports_status) {
            if (parsed.session_id) |session_id| {
                if (readTranscriptTurn(allocator, io, home, parsed.cwd, session_id)) |turn| {
                    session = applyTranscript(session, turn);
                }
            }
        }
        allocator.free(parsed.cwd);
        if (parsed.session_id) |session_id| allocator.free(session_id);
        try found.append(allocator, session);
    }
    return found.toOwnedSlice(allocator);
}

fn readTranscriptTurn(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    cwd: []const u8,
    session_id: []const u8,
) ?Turn {
    const slug = projectSlugAlloc(allocator, cwd) catch return null;
    defer allocator.free(slug);
    const file_path = std.fs.path.join(allocator, &.{
        home,
        ".claude",
        "projects",
        slug,
        session_id,
    }) catch return null;
    defer allocator.free(file_path);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}.jsonl", .{file_path}) catch return null;
    const bytes = std.Io.Dir.readFileAlloc(
        .cwd(),
        io,
        path,
        allocator,
        .limited(64 * 1024),
    ) catch return null;
    defer allocator.free(bytes);
    return turnInTail(allocator, bytes);
}

fn projectSlugAlloc(allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    const slug = try allocator.dupe(u8, cwd);
    for (slug) |*character| {
        if (character.* == '/' or character.* == '.') character.* = '-';
    }
    return slug;
}

fn freeParsed(allocator: std.mem.Allocator, parsed: ParsedRecord) void {
    allocator.free(parsed.session.id);
    allocator.free(parsed.session.name);
    allocator.free(parsed.session.detail);
    if (parsed.session.waiting_for) |waiting| allocator.free(waiting);
    allocator.free(parsed.cwd);
    if (parsed.session_id) |session_id| allocator.free(session_id);
}

test "claude record maps tempo and status" {
    const json =
        \\{"pid":12345,"cwd":"/Users/x/costbar","status":"busy","tempo":"active",
        \\"sessionId":"abc","name":"costbar","startedAt":1756362920000,
        \\"procStart":"Fri Aug 28 05:15:20 2026","entrypoint":"cli"}
    ;
    const parsed = (try parseRecord(std.testing.allocator, json)).?;
    defer freeParsed(std.testing.allocator, parsed);
    try std.testing.expectEqual(@as(i32, 12345), parsed.pid);
    try std.testing.expectEqual(model.State.busy, parsed.session.state);
    try std.testing.expect(parsed.reports_status);
    try std.testing.expectEqualStrings("claude.12345", parsed.session.id);
    try std.testing.expectEqual(@as(?i64, 1_756_362_920), parsed.started_at_unix);
}

test "unknown status is not a reported state" {
    const json = "{\"pid\":1,\"cwd\":\"/tmp/app\"}";
    const parsed = (try parseRecord(std.testing.allocator, json)).?;
    defer freeParsed(std.testing.allocator, parsed);
    try std.testing.expect(!parsed.reports_status);
    try std.testing.expectEqual(model.State.idle, parsed.session.state);
}

test "procStart is UTC" {
    try std.testing.expectEqual(@as(i64, 1_787_894_120), parseProcStart("Fri Aug 28 05:15:20 2026").?);
}

test "transcript tail treats tool_use as in flight and interruptions as finished" {
    const tail =
        \\{"type":"user","message":{"content":"go"}}
        \\{"type":"assistant","message":{"stop_reason":"tool_use"}}
    ;
    try std.testing.expectEqual(Turn.in_flight, turnInTail(std.testing.allocator, tail).?);
    const done =
        \\{"type":"assistant","message":{"stop_reason":"end_turn"}}
    ;
    try std.testing.expectEqual(Turn.finished, turnInTail(std.testing.allocator, done).?);
    const interrupted =
        \\{"type":"user","message":{"content":"[Request interrupted by user]"}}
    ;
    try std.testing.expectEqual(Turn.finished, turnInTail(std.testing.allocator, interrupted).?);
}

test "waiting tempo maps even when status is unknown" {
    const json = "{\"pid\":9,\"cwd\":\"/tmp/work\",\"tempo\":\"blocked\",\"waitingFor\":\"permission\"}";
    const parsed = (try parseRecord(std.testing.allocator, json)).?;
    defer freeParsed(std.testing.allocator, parsed);
    try std.testing.expectEqual(model.State.waiting, parsed.session.state);
    try std.testing.expectEqualStrings("permission", parsed.session.waiting_for.?);
}
