const std = @import("std");
const local_usage = @import("local_usage.zig");

pub const arguments = [_][]const u8{
    "--print",
    "--no-session-persistence",
    "--strict-mcp-config",
    "/usage",
};

pub fn parseLimits(text: []const u8, now_unix: i64) !local_usage.Limits {
    _ = now_unix;
    var primary: ?local_usage.Window = null;
    var secondary: ?local_usage.Window = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        const parsed = parseLine(line) orelse continue;
        const window = local_usage.Window{
            .used_percent = parsed.percent,
            .resets_at_unix = null,
            .duration_minutes = parsed.duration_minutes,
        };
        if (std.mem.eql(u8, parsed.id, "session")) {
            if (primary == null) primary = window;
        } else if (std.mem.eql(u8, parsed.id, "weekly_all")) {
            if (secondary == null) secondary = window;
        }
    }
    return .{
        .timestamp = 0,
        .primary = primary orelse return error.ClaudeUsageMissingSession,
        .secondary = secondary,
    };
}

const ParsedLine = struct {
    id: []const u8,
    percent: f64,
    duration_minutes: i64,
};

fn parseLine(line: []const u8) ?ParsedLine {
    const session_prefix = "Current session:";
    const week_prefix = "Current week (";
    const id: []const u8, const rest: []const u8, const duration: i64 = if (std.mem.startsWith(u8, line, session_prefix))
        .{ "session", std.mem.trim(u8, line[session_prefix.len..], " "), 300 }
    else if (std.mem.startsWith(u8, line, week_prefix)) blk: {
        const close = std.mem.indexOf(u8, line, "):") orelse return null;
        const kind = std.mem.trim(u8, line[week_prefix.len..close], " ");
        const id = if (std.ascii.eqlIgnoreCase(kind, "all models")) "weekly_all" else "weekly_other";
        break :blk .{ id, std.mem.trim(u8, line[close + 2 ..], " "), 10_080 };
    } else return null;

    const percent_end = std.mem.indexOf(u8, rest, "% used") orelse return null;
    var index = percent_end;
    while (index > 0) : (index -= 1) {
        const character = rest[index - 1];
        if (character < '0' or character > '9') break;
    }
    const percent = std.fmt.parseFloat(f64, rest[index..percent_end]) catch return null;
    if (!std.math.isFinite(percent) or percent < 0 or percent > 100) return null;
    return .{ .id = id, .percent = percent, .duration_minutes = duration };
}

pub fn locate(allocator: std.mem.Allocator, io: std.Io, home: []const u8) ![]u8 {
    const relative = [_][]const u8{
        ".local/bin/claude",
        ".claude/local/claude",
        ".bun/bin/claude",
        ".volta/bin/claude",
        "Library/pnpm/claude",
        ".npm-global/bin/claude",
    };
    const absolute = [_][]const u8{
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
    };
    for (relative) |path| {
        const candidate = try std.fs.path.join(allocator, &.{ home, path });
        if (isExecutable(io, candidate)) return candidate;
        allocator.free(candidate);
    }
    for (absolute) |candidate| {
        if (isExecutable(io, candidate)) return allocator.dupe(u8, candidate);
    }
    return error.ClaudeCLINotInstalled;
}

fn isExecutable(io: std.Io, path: []const u8) bool {
    var file = std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_only }) catch return false;
    file.close(io);
    return true;
}

pub fn fetchLimits(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    now_unix: i64,
) !?local_usage.Limits {
    const binary = locate(allocator, io, home) catch return null;
    defer allocator.free(binary);
    const scratch = scratchDirectory(allocator, home) catch return null;
    defer allocator.free(scratch);
    std.Io.Dir.createDirPath(.cwd(), io, scratch) catch {};
    const result = std.process.run(allocator, io, .{
        .argv = &.{ binary, arguments[0], arguments[1], arguments[2], arguments[3] },
        .cwd = .{ .path = scratch },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(16 * 1024),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = .fromSeconds(20) } },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) return null;
    return parseLimits(result.stdout, now_unix) catch null;
}

fn scratchDirectory(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    const xdg = std.c.getenv("XDG_CACHE_HOME");
    if (xdg) |pointer| {
        const root = std.mem.span(pointer);
        if (root.len > 0) {
            return std.fs.path.join(allocator, &.{ root, "costbar", "usage-scratch" });
        }
    }
    return std.fs.path.join(allocator, &.{
        home,
        "Library/Application Support/Costbar/usage-scratch",
    });
}

test "claude /usage text yields session and weekly windows" {
    const text =
        \\Current session: 38% used · resets Sep 7 at 2:59pm (Asia/Jakarta)
        \\Current week (all models): 4% used · resets Sep 14 at 5:59am (Asia/Jakarta)
        \\
        \\Approximate usage, not a billing statement.
    ;
    const limits = try parseLimits(text, 1);
    try std.testing.expectEqual(@as(f64, 38), limits.primary.?.used_percent);
    try std.testing.expectEqual(@as(i64, 300), limits.primary.?.duration_minutes.?);
    try std.testing.expectEqual(@as(f64, 4), limits.secondary.?.used_percent);
    try std.testing.expectEqual(@as(i64, 10_080), limits.secondary.?.duration_minutes.?);
}

test "claude /usage without a session window is rejected" {
    try std.testing.expectError(
        error.ClaudeUsageMissingSession,
        parseLimits("Current week (all models): 4% used\n", 1),
    );
}

test "hour without minutes still yields a percentage" {
    const text = "Current session: 12% used · resets Sep 7 at 3pm (UTC)\n";
    const limits = try parseLimits(text, 1);
    try std.testing.expectEqual(@as(f64, 12), limits.primary.?.used_percent);
}
