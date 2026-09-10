const std = @import("std");
const model = @import("model.zig");

pub const busy_after_seconds: i64 = 8;
pub const success_after_seconds: i64 = 17;

pub fn stateForAge(age_seconds: i64) ?model.State {
    if (age_seconds <= busy_after_seconds) return .busy;
    if (age_seconds <= success_after_seconds) return .success;
    return null;
}

pub fn sessionFromMtime(
    allocator: std.mem.Allocator,
    profile_id: []const u8,
    file_name: []const u8,
    mtime_unix: i64,
    now_unix: i64,
) !?model.Session {
    const age = now_unix -| mtime_unix;
    const state = stateForAge(age) orelse return null;
    const id = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ profile_id, file_name });
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, "Codex");
    errdefer allocator.free(name);
    const detail = try allocator.dupe(u8, switch (state) {
        .busy => "Working",
        .success => "Complete",
        .idle => "Idle",
        .waiting => "Waiting",
    });
    return .{
        .id = id,
        .name = name,
        .detail = detail,
        .state = state,
        .since_unix = mtime_unix,
    };
}

pub fn scan(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    profile_id: []const u8,
    now_unix: i64,
) ![]model.Session {
    const roots = [_][]const u8{ "sessions", "archived_sessions" };
    var newest_name: ?[]u8 = null;
    var newest_mtime: i64 = std.math.minInt(i64);
    defer if (newest_name) |name| allocator.free(name);

    for (roots) |relative| {
        const path = try std.fs.path.join(allocator, &.{ home, relative });
        defer allocator.free(path);
        var dir = std.Io.Dir.openDirAbsolute(io, path, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch continue;
        defer dir.close(io);
        var walker = try dir.walk(allocator);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".jsonl")) continue;
            const stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
            const mtime: i64 = @truncate(@divFloor(stat.mtime.nanoseconds, std.time.ns_per_s));
            if (mtime >= newest_mtime) {
                if (newest_name) |name| allocator.free(name);
                newest_name = try allocator.dupe(u8, entry.basename);
                newest_mtime = mtime;
            }
        }
    }

    const file_name = newest_name orelse return &.{};
    if (try sessionFromMtime(allocator, profile_id, file_name, newest_mtime, now_unix)) |session| {
        const one = try allocator.alloc(model.Session, 1);
        one[0] = session;
        return one;
    }
    return &.{};
}

test "codex mtime is busy then success then omitted" {
    try std.testing.expectEqual(model.State.busy, stateForAge(0).?);
    try std.testing.expectEqual(model.State.busy, stateForAge(8).?);
    try std.testing.expectEqual(model.State.success, stateForAge(9).?);
    try std.testing.expectEqual(model.State.success, stateForAge(17).?);
    try std.testing.expect(stateForAge(18) == null);
}

test "codex session copy names the heuristic" {
    const session = (try sessionFromMtime(std.testing.allocator, "default", "rollout.jsonl", 100, 104)).?;
    defer {
        std.testing.allocator.free(session.id);
        std.testing.allocator.free(session.name);
        std.testing.allocator.free(session.detail);
    }
    try std.testing.expectEqual(model.State.busy, session.state);
    try std.testing.expectEqualStrings("Working", session.detail);
    try std.testing.expectEqualStrings("default.rollout.jsonl", session.id);
}
